#!/usr/bin/env python3
"""NES Tecmo Bowl netplay matchmaking + relay server.

A copy of the Intellivision Baseball relay (intv-baseball-experiment,
server/bbnet_server.py) with the same wire protocol; only the defaults and
the Lobby platform string differ. The server never looks inside INPUT,
STATE or RESYNC payloads, so nothing in it is game-specific.

Single-file, stdlib-only, selectors-based non-blocking TCP (the FujiRealm
hybrid_server.py pattern).  Clients are NES consoles on the FujiNet
cartridge connecting outbound through N:TCP -- the server is a mandatory
relay (FujiNet has no listener/NAT story).

Wire format, both directions: length-prefixed frames over TCP.
    frame := len(1) type(1) payload(len-1 bytes)
`len` counts type+payload.  TCP provides ordering/integrity; frames are
validated structurally and a malformed stream drops the connection.

Types:
    C->S  $01 HELLO      ver(1) name(ASCII, 2-8 chars A-Z0-9)
    C->S  $02 LIST
    S->C  $03 LOBBY      count(1) then per entry: name(8, NUL-padded) status(1)
    C->S  $04 JOIN       name(ASCII)
    S->C  $05 START      role(1: 0=host = 1UP, 1=guest = 2UP) seed_lo
                         seed_hi delay(1) opponent(8, NUL-padded)
    C<->C $06 INPUT      tick_lo tick_hi pad(1) spare(1)   (relayed verbatim)
    C<->C $07 CRC        tick_lo tick_hi crc_lo crc_hi     (relayed + logged)
    C<->C $08 STATE      chunk data                        (relayed)
    C<->C $09 RESYNC     tick_lo tick_hi                   (relayed)
    C->S  $0A BYE
    S->C  $0B PEER_LEFT
    C->S  $0C PING   ->  S->C $0D PONG
"""
import argparse
import json
import logging
import random
import selectors
import socket
import threading
import time
import urllib.request

log = logging.getLogger("tbnet")

T_HELLO, T_LIST, T_LOBBY, T_JOIN, T_START = 0x01, 0x02, 0x03, 0x04, 0x05
T_INPUT, T_CRC, T_STATE, T_RESYNC = 0x06, 0x07, 0x08, 0x09
T_BYE, T_PEER_LEFT, T_PING, T_PONG = 0x0A, 0x0B, 0x0C, 0x0D

RELAY_TYPES = {T_INPUT, T_CRC, T_STATE, T_RESYNC}
NAME_CHARS = set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
DEFAULT_DELAY = 3

MAX_TX_BACKLOG = 64 * 1024      # bytes queued per client before drop
MAX_CLIENTS = 64                # global established-connection cap
MAX_CONNECTIONS_PER_IP = 8      # generous: FujiNets can share a NAT address
HELLO_TIMEOUT = 60              # seconds to identify before drop (pre-HELLO only)
STATS_INTERVAL = 60             # seconds between abuse-counter summaries


def frame(ftype, payload=b""):
    body = bytes([ftype]) + payload
    assert len(body) <= 255
    return bytes([len(body)]) + body


def pad_name(name):
    return name.encode("ascii")[:8].ljust(8, b"\0")


class Client:
    def __init__(self, sock, addr):
        self.sock = sock
        self.addr = addr
        self.rx = bytearray()
        self.tx = bytearray()
        self.name = None
        self.partner = None          # Client when in a match
        self.crc_log = {}            # tick -> crc (during a match)
        self.crc_ok = 0              # matched CRC pairs this match
        self.connected_at = time.time()
        self.dead = False            # set by drop(); guards late events

    @property
    def idle(self):
        return self.name is not None and self.partner is None

    def __repr__(self):
        return f"<{self.name or self.addr}>"


class Server:
    def __init__(self, port, delay=DEFAULT_DELAY, lobby=None):
        self.sel = selectors.DefaultSelector()
        self.port = port
        self.delay = delay
        self.by_name = {}
        self.lobby = lobby
        self.clients = set()
        self.stats = {
            "tx_backlog_drops": 0,
            "hello_timeouts": 0,
            "connection_limit_rejections": 0,
        }
        self._last_stats = {**self.stats, "lobby_publish_failures": 0}

    def lobby_update(self):
        if self.lobby:
            self.lobby.update(len(self.by_name))

    # ---- plumbing ---------------------------------------------------------
    def run(self):
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("0.0.0.0", self.port))
        srv.listen(8)
        srv.setblocking(False)
        self.sel.register(srv, selectors.EVENT_READ, None)
        log.info("listening on :%d", self.port)
        last_sweep = last_stats = time.time()
        while True:
            for key, mask in self.sel.select(timeout=1.0):
                if key.data is None:
                    self.accept(srv)
                    continue
                client = key.data
                try:
                    if mask & selectors.EVENT_WRITE and not client.dead:
                        self.flush(client)
                    if mask & selectors.EVENT_READ and not client.dead:
                        self.service(client)
                except Exception:
                    log.exception("unexpected error serving %r", client)
                    self.drop(client, "internal protocol error")
            now = time.time()
            if now - last_sweep >= 1.0:
                last_sweep = now
                self.sweep(now)
            if now - last_stats >= STATS_INTERVAL:
                last_stats = now
                self.log_stats()

    def accept(self, srv):
        sock, addr = srv.accept()
        if len(self.clients) >= MAX_CLIENTS:
            self.stats["connection_limit_rejections"] += 1
            log.warning("reject %s: server full (%d clients)",
                        addr, len(self.clients))
            sock.close()
            return
        per_ip = sum(1 for c in self.clients if c.addr[0] == addr[0])
        if per_ip >= MAX_CONNECTIONS_PER_IP:
            self.stats["connection_limit_rejections"] += 1
            log.warning("reject %s: per-IP limit (%d)", addr, per_ip)
            sock.close()
            return
        sock.setblocking(False)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        client = Client(sock, addr)
        self.clients.add(client)
        self.sel.register(sock, selectors.EVENT_READ, client)
        log.info("connect from %s", addr)

    def send(self, client, data):
        if client.dead:
            return
        if len(client.tx) + len(data) > MAX_TX_BACKLOG:
            self.stats["tx_backlog_drops"] += 1
            self.drop(client, "transmit backlog exceeded")
            return
        client.tx += data
        self.flush(client)

    def flush(self, client):
        while client.tx:
            try:
                n = client.sock.send(client.tx)
            except BlockingIOError:
                break
            except OSError:
                self.drop(client, "send error")
                return
            if n == 0:
                self.drop(client, "send returned 0")
                return
            del client.tx[:n]
        self._update_events(client)

    def _update_events(self, client):
        events = selectors.EVENT_READ
        if client.tx:
            events |= selectors.EVENT_WRITE
        try:
            self.sel.modify(client.sock, events, client)
        except (KeyError, ValueError):
            pass                # already unregistered by drop()

    def sweep(self, now):
        for client in list(self.clients):
            if client.name is None and now - client.connected_at > HELLO_TIMEOUT:
                self.stats["hello_timeouts"] += 1
                self.drop(client, f"no hello within {HELLO_TIMEOUT}s")

    def log_stats(self):
        counts = dict(self.stats)
        counts["lobby_publish_failures"] = self.lobby.failures if self.lobby else 0
        if counts == self._last_stats:
            return
        self._last_stats = counts
        unidentified = sum(1 for c in self.clients if c.name is None)
        log.info("stats: active_clients=%d unidentified_clients=%d %s",
                 len(self.clients), unidentified,
                 " ".join(f"{k}={v}" for k, v in sorted(counts.items())))

    def drop(self, client, why):
        if client.dead:
            return
        client.dead = True
        log.info("drop %r: %s", client, why)
        try:
            self.sel.unregister(client.sock)
        except (KeyError, ValueError):
            pass
        try:
            client.sock.close()
        except OSError:
            pass
        self.clients.discard(client)
        # remove every alias, not just the current name: repeated HELLOs may
        # have left more than one entry pointing here
        stale = [n for n, c in self.by_name.items() if c is client]
        for n in stale:
            del self.by_name[n]
        if stale:
            self.lobby_update()
        partner = client.partner
        if partner is not None:
            log.info("match ended: %d CRC pairs verified", partner.crc_ok)
            partner.partner = None
            client.partner = None
            self.send(partner, frame(T_PEER_LEFT))
            log.info("%r back to lobby (peer left)", partner)

    def service(self, client):
        try:
            data = client.sock.recv(4096)
        except BlockingIOError:
            return
        except OSError:
            self.drop(client, "recv error")
            return
        if not data:
            self.drop(client, "closed")
            return
        client.rx += data
        while True:
            if not client.rx:
                return
            need = client.rx[0] + 1
            if need < 2 or client.rx[0] > 200:
                self.drop(client, f"bad frame length {client.rx[0]}")
                return
            if len(client.rx) < need:
                return
            body = bytes(client.rx[1:need])
            del client.rx[:need]
            try:
                self.handle(client, body[0], body[1:])
            except ProtocolError as e:
                self.drop(client, str(e))
                return
            if client.dead:
                return          # relay side effects can drop us mid-batch

    # ---- protocol ---------------------------------------------------------
    def handle(self, client, ftype, payload):
        if ftype in RELAY_TYPES:
            if client.partner is None:
                return          # peer just left; console hasn't noticed yet
            if ftype == T_CRC and len(payload) == 4:
                self.log_crc(client, payload)
            self.send(client.partner, frame(ftype, payload))
            return
        if ftype == T_HELLO:
            self.on_hello(client, payload)
        elif ftype == T_LIST:
            self.on_list(client)
        elif ftype == T_JOIN:
            self.on_join(client, payload)
        elif ftype == T_BYE:
            self.drop(client, "bye")
        elif ftype == T_PING:
            self.send(client, frame(T_PONG))
        else:
            raise ProtocolError(f"unknown type ${ftype:02X}")

    def on_hello(self, client, payload):
        if len(payload) < 3:
            raise ProtocolError("short hello")
        name = payload[1:].decode("ascii", "replace").rstrip("\0 ")
        if not (2 <= len(name) <= 8) or not set(name) <= NAME_CHARS:
            raise ProtocolError(f"bad name {name!r}")
        old = self.by_name.get(name)
        if old is not None and old is not client:
            self.drop(old, "replaced by new connection")
        if client.name is not None and client.name != name:
            # repeated HELLO with a new name: clean up the old alias
            if self.by_name.get(client.name) is client:
                del self.by_name[client.name]
            log.info("rename %r -> %s", client, name)
        client.name = name
        self.by_name[name] = client
        log.info("hello %r", client)
        self.lobby_update()
        self.on_list(client)

    def on_list(self, client):
        others = [c for c in self.by_name.values()
                  if c is not client and c.name]
        others = others[:8]     # the console's LOBBY_CACHE holds 8
        payload = bytes([len(others)])
        for c in others:
            payload += pad_name(c.name) + bytes([0 if c.idle else 1])
        self.send(client, frame(T_LOBBY, payload))

    def on_join(self, client, payload):
        if client.name is None:
            raise ProtocolError("join before hello")
        if client.partner is not None:
            return              # duplicate/crossed join; already matched
        name = payload.decode("ascii", "replace").rstrip("\0 ")
        target = self.by_name.get(name)
        if target is None or not target.idle or target is client:
            self.on_list(client)      # refresh; target gone or busy
            return
        seed = random.randrange(1, 0x10000)
        client.partner = target
        target.partner = client
        client.crc_log.clear()
        target.crc_log.clear()
        client.crc_ok = 0
        target.crc_ok = 0
        common = bytes([seed & 0xFF, seed >> 8, self.delay])
        # the waiting player is host (role 0, left controller)
        self.send(target, frame(T_START, bytes([0]) + common + pad_name(client.name)))
        self.send(client, frame(T_START, bytes([1]) + common + pad_name(target.name)))
        log.info("match: host %r vs guest %r (seed $%04X)", target, client, seed)

    def log_crc(self, client, payload):
        tick = payload[0] | (payload[1] << 8)
        crc = payload[2] | (payload[3] << 8)
        partner = client.partner
        other = partner.crc_log.pop(tick, None)
        if other is None:
            client.crc_log[tick] = crc
            if len(client.crc_log) > 64:
                client.crc_log.pop(min(client.crc_log))
        elif other != crc:
            log.warning("CRC MISMATCH tick %d: %r=$%04X %r=$%04X",
                        tick, client, crc, partner, other)
        else:
            client.crc_ok += 1
            partner.crc_ok += 1
            if client.crc_ok % 4 == 0:
                log.info("crc ok through tick %d (%d pairs)",
                         tick, client.crc_ok)


class ProtocolError(Exception):
    pass


class LobbyPublisher:
    """Registers this server as a room on the FujiNet Lobby
    (https://lobby.fujinet.online): POST /server on state changes AND on a
    periodic keepalive, status:"offline" POST on shutdown.

    The Lobby tracks a lastping per entry, so a quiet server that never
    re-POSTs goes stale in every client's list -- the keepalive re-POST
    (KEEPALIVE_SECS) is what keeps the room visible between matches.

    The platform string must be "nes": that is what the NES Lobby client
    queries (`/view?bin=1&platform=nes`, fujinet-lobby nes/Makefile). That
    client hands the booted game this room's serverurl through appkey
    creator 1 / app 1 / key = appkey, which the console reads first.

    One worker thread owns all HTTP traffic: updates are coalesced under a
    condition variable and only the newest player count is published, at most
    once per second, so connection churn can never fan out into unbounded
    threads or overlapping requests."""

    KEEPALIVE_SECS = 300.0

    def __init__(self, base_url, serverurl, client_url, appkey, region="us",
                 game_name="Tecmo Bowl",
                 server_name="Tecmo Bowl Netplay", platform="nes"):
        self.base_url = base_url.rstrip("/")
        self.payload = {
            "game": game_name,
            "appkey": appkey,
            "server": server_name,
            "region": region,
            "serverurl": serverurl,
            "status": "online",
            "maxplayers": 2,
            "curplayers": 0,
            "clients": [{"platform": platform, "url": client_url}],
        }
        self.failures = 0
        self._cond = threading.Condition()
        self._dirty = False
        self._stopping = False
        self._stop_evt = threading.Event()
        self._worker = threading.Thread(target=self._run, daemon=True)
        self._worker.start()

    def update(self, curplayers):
        with self._cond:
            if self._stopping:
                return
            self.payload["curplayers"] = curplayers
            self._dirty = True
            self._cond.notify()

    def shutdown(self):
        with self._cond:
            self._stopping = True
            self.payload["status"] = "offline"
            snapshot = dict(self.payload)
            self._cond.notify()
        self._stop_evt.set()
        self._worker.join(timeout=12)   # let an in-flight POST finish first
        self._post(snapshot)

    def _run(self):
        while True:
            with self._cond:
                deadline = time.monotonic() + self.KEEPALIVE_SECS
                while not self._dirty and not self._stopping:
                    if not self._cond.wait(deadline - time.monotonic()):
                        self._dirty = True      # keepalive: re-POST as-is
                self._dirty = False
                if self._stopping:
                    return
                snapshot = dict(self.payload)
            self._post(snapshot)
            self._stop_evt.wait(1.0)    # debounce; returns early on shutdown

    def _post(self, payload):
        try:
            req = urllib.request.Request(
                self.base_url + "/server",
                data=json.dumps(payload).encode(),
                headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=10) as resp:
                log.debug("lobby POST -> %d", resp.status)
        except OSError as e:
            self.failures += 1
            log.warning("lobby POST failed: %s", e)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=9701)
    ap.add_argument("--game-name", default="Tecmo Bowl",
                    help="game name for the FujiNet Lobby registration")
    ap.add_argument("--server-name", default="Tecmo Bowl Netplay",
                    help="server name for the FujiNet Lobby registration")
    ap.add_argument("--delay", type=int, default=DEFAULT_DELAY,
                    help="lockstep input delay in game ticks")
    ap.add_argument("--debug", action="store_true")
    ap.add_argument("--lobby-enabled", action="store_true",
                    help="register with the FujiNet Lobby (production runs: "
                         "server/run_production.sh passes this)")
    ap.add_argument("--lobby-url", default="https://lobby.fujinet.online")
    ap.add_argument("--lobby-serverurl",
                    default="TCP://fujinet.online:9701/",
                    help="public endpoint clients should use")
    ap.add_argument("--lobby-client-url",
                    default="TNFS://apps.irata.online/NES/Games/"
                            "TecmoBowl.nes",
                    help="TNFS path of the client ROM for Lobby boot")
    ap.add_argument("--lobby-appkey", type=int, default=41,
                    help="FujiNet-registry appkey id for this game (a "
                         "placeholder until one is assigned; the Lobby "
                         "rejects 0). Must match the ROM's GAME_APPKEY")
    ap.add_argument("--platform", default="nes",
                    help="Lobby client platform string")
    args = ap.parse_args()
    logging.basicConfig(
        level=logging.DEBUG if args.debug else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s")
    lobby = None
    if args.lobby_enabled:
        lobby = LobbyPublisher(args.lobby_url, args.lobby_serverurl,
                               args.lobby_client_url, args.lobby_appkey,
                               game_name=args.game_name,
                               server_name=args.server_name,
                               platform=args.platform)
        lobby.update(0)
    try:
        Server(args.port, args.delay, lobby).run()
    finally:
        if lobby:
            lobby.shutdown()


if __name__ == "__main__":
    main()
