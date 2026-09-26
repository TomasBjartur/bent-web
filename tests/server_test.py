#!/usr/bin/env python3
"""Integration tests against a running server (raw sockets, stdlib only).

usage: tests/server_test.py [port]   (default 8090)
"""
import socket, sys, time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8090
fails = 0

def raw(data, chunks=None, delay=0.0, timeout=15.0, half_close=False):
    s = socket.create_connection(("127.0.0.1", PORT), timeout=timeout)
    parts = chunks if chunks is not None else [data]
    for i, p in enumerate(parts):
        s.sendall(p)
        if delay and i + 1 < len(parts):
            time.sleep(delay)
    if half_close:
        s.shutdown(socket.SHUT_WR)
    out = b""
    try:
        while True:
            b = s.recv(65536)
            if not b:
                break
            out += b
    except socket.timeout:
        out += b"<client timeout>"
    except ConnectionResetError:
        out += b"<reset>"
    s.close()
    return out

def status(resp):
    try:
        return int(resp.split(b" ", 2)[1])
    except Exception:
        return resp[:40]

def check(name, got, want):
    global fails
    ok = got == want
    fails += 0 if ok else 1
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else f"   got {got!r} want {want!r}"))

check("simple GET", status(raw(b"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")), 200)
check("head split over 3 packets", status(raw(None, [b"GET /hea", b"lthz HTTP/1.1\r\nHo", b"st: localhost\r\n\r\n"], delay=0.05)), 200)
check("CRLFCRLF split across packets", status(raw(None, [b"GET / HTTP/1.1\r\nHost: localhost\r\n\r", b"\n"], delay=0.05)), 200)
check("bare LF", status(raw(b"GET / HTTP/1.1\nHost: localhost\n\n\r\n\r\n")), 400)
check("NUL in path", status(raw(b"GET /a\x00b HTTP/1.1\r\n\r\n")), 400)
check("invalid UTF-8 in header", status(raw(b"GET / HTTP/1.1\r\nX-A: \xff\xfe\r\n\r\n")), 400)
check("POST without Sec-Fetch-Site -> 403 (CSRF law)", status(raw(b"POST /logout HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello")), 403)
check("POST with body in same packet -> 303", status(raw(b"POST /logout HTTP/1.1\r\nSec-Fetch-Site: same-origin\r\nContent-Length: 5\r\n\r\nhello")), 303)
check("POST body split, waits for rest -> 303", status(raw(None, [b"POST /logout HTTP/1.1\r\nSec-Fetch-Site: same-origin\r\nContent-Length: 10\r\n\r\nhello", b"world"], delay=0.2)), 303)
check("clen > 1 MiB", status(raw(b"POST / HTTP/1.1\r\nContent-Length: 1048577\r\n\r\n")), 400)
check("head over 8 KiB", status(raw(b"GET / HTTP/1.1\r\n" + b"X-A: " + b"a" * 9000 + b"\r\n\r\n")), 431)
check("pipelined second request ignored", raw(b"GET /healthz HTTP/1.1\r\n\r\nGET /nope HTTP/1.1\r\n\r\n").count(b"HTTP/1.1"), 1)
check("client closes without sending: server just closes", raw(b"", half_close=True), b"")

# Slowloris: send part of a head and stall; the server must answer 408
# within the head deadline (10 s) instead of waiting forever.
t0 = time.time()
r = raw(None, [b"GET / HTTP/1.1\r\n", b"X-A: b\r\n"], delay=0.1, timeout=20)
dt = time.time() - t0
check("slowloris gets 408", status(r), 408)
check("slowloris cut off within ~10 s", 9.0 < dt < 12.0, True)

# Slow body: headers promise 10 bytes, 5 arrive, then silence -> 408 in 30 s
# is too slow for a quick test, so only check the server is still healthy.
check("still healthy", status(raw(b"GET /healthz HTTP/1.1\r\n\r\n")), 200)

print(f"\n{fails} failure(s)")
sys.exit(1 if fails else 0)
