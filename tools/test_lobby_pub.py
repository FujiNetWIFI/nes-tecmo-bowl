#!/usr/bin/env python3
"""LobbyPublisher contract test against a mock Lobby.

Starts a stdlib HTTP server standing in for lobby.fujinet.online, points a
LobbyPublisher at it (keepalive shortened), and asserts the wire contract
the real Lobby and the NES Lobby client depend on:

  1. registration POST on startup, platform "nes", nonzero appkey,
     game/serverurl as configured;
  2. an unprompted keepalive re-POST within the keepalive interval
     (the Lobby drops stale entries by lastping);
  3. a final status:"offline" POST on shutdown.

Run from the repo root: python3 tools/test_lobby_pub.py
"""
import importlib.util
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

SERVER_PY = next(Path(__file__).resolve().parent.parent.glob("server/*_server.py"))
spec = importlib.util.spec_from_file_location("relay", SERVER_PY)
relay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(relay)

posts = []
posts_lock = threading.Lock()


class MockLobby(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        with posts_lock:
            posts.append(json.loads(body))
        self.send_response(201)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"success": true}')

    def log_message(self, *a):
        pass


def wait_for(cond, timeout, what):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        with posts_lock:
            if cond():
                return
        time.sleep(0.05)
    with posts_lock:
        snapshot = list(posts)
    sys.exit(f"FAIL: timed out waiting for {what}; posts so far: {snapshot}")


def main():
    httpd = HTTPServer(("127.0.0.1", 0), MockLobby)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{httpd.server_address[1]}"

    relay.LobbyPublisher.KEEPALIVE_SECS = 1.0     # shrink for the test
    pub = relay.LobbyPublisher(base, "TCP://example:9999/",
                               "TNFS://example/game.rom", appkey=99)
    pub.update(0)

    wait_for(lambda: len(posts) >= 1, 5, "the registration POST")
    reg = posts[0]
    assert reg["status"] == "online", reg
    assert reg["appkey"] == 99, reg
    assert reg["serverurl"] == "TCP://example:9999/", reg
    assert reg["maxplayers"] == 2, reg
    assert reg["clients"] == [{"platform": "nes",
                               "url": "TNFS://example/game.rom"}], \
        f"platform must be 'nes' (the NES Lobby client's filter): {reg}"
    assert 2 <= len(reg["game"]) <= 16, reg
    print(f"ok: registration ({reg['game']!r}, appkey {reg['appkey']})")

    n = len(posts)
    wait_for(lambda: len(posts) > n, 5, "a keepalive re-POST")
    assert posts[-1]["status"] == "online"
    print("ok: keepalive re-POST within the interval")

    pub.shutdown()
    wait_for(lambda: posts and posts[-1]["status"] == "offline", 5,
             "the offline POST on shutdown")
    print("ok: offline POST on shutdown")
    httpd.shutdown()
    print("LOBBY PUBLISHER PASS")


if __name__ == "__main__":
    main()
