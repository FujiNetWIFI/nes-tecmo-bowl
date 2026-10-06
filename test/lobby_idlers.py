#!/usr/bin/env python3
"""Park idle clients in the lobby so a console under test sees a multi-entry
list.  They HELLO and then only drain their sockets.

With --pair, the first two also JOIN each other, so they show up in the list
with status = 1 (in a match) while the rest stay selectable -- that is the
case where pressing A used to do nothing at all.
"""
import argparse
import socket
import time

ap = argparse.ArgumentParser()
ap.add_argument("names", nargs="*", default=["ALPHA", "BRAVO"])
ap.add_argument("--pair", action="store_true",
                help="match the first two players against each other")
ap.add_argument("--join-guest", metavar="NAME",
                help="last player waits for a lobby entry starting with NAME "
                     "and JOINs it, so the console under test gets role 0")
ap.add_argument("--port", type=int, default=9799)
args = ap.parse_args()

socks = {}
for n in args.names:
    s = socket.create_connection(("127.0.0.1", args.port))
    body = bytes([0x01, 1]) + n.encode()
    s.sendall(bytes([len(body)]) + body)
    socks[n] = s

if args.pair and len(args.names) >= 2:
    time.sleep(0.3)
    joiner, target = args.names[0], args.names[1]
    body = bytes([0x04]) + target.encode("ascii").ljust(8, b"\0")
    socks[joiner].sendall(bytes([len(body)]) + body)
    print(f"paired: {joiner} -> {target}", flush=True)

for s in socks.values():
    s.setblocking(False)
print("idlers:", ", ".join(args.names), flush=True)

hunter = socks[args.names[-1]] if args.join_guest else None
buf = bytearray()
joined = False
while True:
    for name, s in socks.items():
        try:
            data = s.recv(4096)
        except (BlockingIOError, OSError):
            continue
        if s is hunter:
            buf += data
    # LOBBY = $03 count(1) then count x (name(8) status(1))
    while hunter is not None and not joined and len(buf) >= 2:
        need = buf[0] + 1
        if len(buf) < need:
            break
        body, buf = bytes(buf[1:need]), buf[need:]
        if body[0] != 0x03:
            continue
        for i in range(body[1]):
            entry = body[2 + 9 * i:2 + 9 * i + 9]
            nm = entry[:8].rstrip(b"\0").decode("ascii", "replace")
            if nm.startswith(args.join_guest) and entry[8] == 0:
                payload = bytes([0x04]) + entry[:8]
                hunter.sendall(bytes([len(payload)]) + payload)
                print(f"joined: {args.names[-1]} -> {nm}", flush=True)
                joined = True
                break
    if hunter is not None and not joined:
        payload = bytes([0x02])          # LIST
        try:
            hunter.sendall(bytes([len(payload)]) + payload)
        except OSError:
            pass
    time.sleep(0.2)
