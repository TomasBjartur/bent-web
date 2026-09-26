#!/usr/bin/env python3
"""Fuzz a running server with mutated and random requests.
Checks: the server never dies, and every answer is a well-formed status
line with a known code. usage: tests/fuzz_server.py [port] [n] [seed]
"""
import random, socket, sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8090
N = int(sys.argv[2]) if len(sys.argv) > 2 else 5000
rng = random.Random(int(sys.argv[3]) if len(sys.argv) > 3 else 1)
KNOWN = {200, 303, 400, 403, 404, 405, 408, 409, 413, 431, 500, 501, 503, 505}

SEEDS = [
    b"GET / HTTP/1.1\r\nHost: x\r\n\r\n",
    b"GET /healthz?a=1&b=2 HTTP/1.1\r\nHost: x\r\nCookie: s=abc\r\n\r\n",
    b"POST /p HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nContent-Type: text/plain\r\n\r\nhello",
    b"DELETE /a/b HTTP/1.1\r\nOrigin: https://x\r\nSec-Fetch-Site: same-origin\r\n\r\n",
    b"POST /blogs HTTP/1.1\r\nSec-Fetch-Site: same-origin\r\nCookie: sid=00\r\nContent-Length: 20\r\n\r\nslug=a-b&title=Hello",
    b"GET /b/x/y HTTP/1.1\r\nCookie: sid=0000000000000000000000000000000000000000000000000000000000000000\r\n\r\n",
    b"POST /edit/1 HTTP/1.1\r\nSec-Fetch-Site: same-origin\r\nContent-Length: 18\r\n\r\ntitle=a&body=%E2%82",
]
TOKENS = [b"\r\n", b"\n", b"\r", b"\x00", b" ", b":", b"/", b"..", b"%2e", b"?", b"&", b"=",
          b"Content-Length: 3", b"Transfer-Encoding: chunked", b"Host: y", b"\xff", b"\t",
          b"HTTP/1.1", b"GET", b"99999999999", b"-1", b"\r\n\r\n"]

def mutate(b):
    b = bytearray(b)
    for _ in range(rng.randint(1, 6)):
        op = rng.randrange(6)
        i = rng.randrange(len(b) + 1)
        if op == 0 and b:
            b[rng.randrange(len(b))] = rng.randrange(256)
        elif op == 1:
            b[i:i] = rng.choice(TOKENS)
        elif op == 2 and b:
            j = rng.randrange(len(b)); del b[j:j + rng.randint(1, 8)]
        elif op == 3 and b:
            j = rng.randrange(len(b)); b[i:i] = b[j:j + rng.randint(1, 40)]
        elif op == 4:
            b = b[:i]
        else:
            b[i:i] = bytes(rng.randrange(256) for _ in range(rng.randint(1, 20)))
    return bytes(b)

def send(data):
    s = socket.create_connection(("127.0.0.1", PORT), timeout=15)
    try:
        s.sendall(data)
        s.shutdown(socket.SHUT_WR)
        out = b""
        while True:
            x = s.recv(65536)
            if not x:
                break
            out += x
        return out
    except (ConnectionResetError, BrokenPipeError):
        return b"<reset>"
    finally:
        s.close()

bad, counts = 0, {}
for k in range(N):
    data = mutate(rng.choice(SEEDS)) if rng.random() < 0.9 else bytes(rng.randrange(256) for _ in range(rng.randint(0, 300)))
    out = send(data)
    if out in (b"", b"<reset>"):
        counts["closed"] = counts.get("closed", 0) + 1
        continue
    try:
        code = int(out.split(b" ", 2)[1]) if out.startswith(b"HTTP/1.1 ") else None
    except ValueError:
        code = None
    if code not in KNOWN or b"\r\n\r\n" not in out:
        bad += 1
        print("BAD RESPONSE for", data[:120], "->", out[:120])
    counts[code] = counts.get(code, 0) + 1
print("responses:", dict(sorted(counts.items(), key=lambda kv: str(kv[0]))))
print("malformed:", bad)
sys.exit(1 if bad else 0)
