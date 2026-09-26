#!/usr/bin/env python3
"""Tests the server with several worker processes (BLOG_WORKERS=4): what
each process keeps must agree with the others.

- Supervision: 4 workers under one supervisor; a worker that dies stops
  them all (systemd then restarts the service).
- Page cache: a post page cached in every worker is fresh everywhere
  right after an edit, a like, or an unpublish made through any worker.
- Live comments: readers streaming from any worker get a new comment
  (written through any worker) within LIVE_LOOK_MS (0.5 s) or so.
- Search runs off the event loop in every worker.

Requests are spread over the workers by sending them concurrently (all
workers accept from one socket; which one takes a connection is up to the
kernel), so each check repeats enough to reach every worker.

usage: tests/workers_test.py   (needs ./build.sh)
"""
import concurrent.futures, hashlib, os, re, secrets, socket, sqlite3, subprocess, sys, tempfile, time, urllib.parse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORT = 8197
WORKERS = 4
fails = 0


def check(name, ok, detail=""):
    global fails
    fails += 0 if ok else 1
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else f"   {detail}"))


def http(method, path, sid=None, form=None):
    body = urllib.parse.urlencode(form).encode() if form is not None else b""
    h = f"{method} {path} HTTP/1.1\r\nHost: localhost\r\nSec-Fetch-Site: same-origin\r\n"
    if sid:
        h += f"Cookie: sid={sid}\r\n"
    if method == "POST":
        h += f"Content-Type: application/x-www-form-urlencoded\r\nContent-Length: {len(body)}\r\n"
    s = socket.create_connection(("127.0.0.1", PORT), timeout=10)
    s.sendall(h.encode() + b"\r\n" + body)
    out = b""
    while True:
        b = s.recv(65536)
        if not b:
            break
        out += b
    s.close()
    head, _, rb = out.partition(b"\r\n\r\n")
    loc = re.search(rb"\r\nLocation: ([^\r]*)", head)
    return int(head.split(b" ")[1]), (loc.group(1).decode() if loc else None), rb.decode("utf-8", "replace")


def many(path, n=40):
    """n concurrent GETs of path (so they land on different workers)."""
    with concurrent.futures.ThreadPoolExecutor(16) as ex:
        return list(ex.map(lambda _: http("GET", path), range(n)))


def user(db, email):
    uid = db.execute("INSERT INTO user(email, name, created_ms) VALUES (?, ?, 1)", (email, email.split("@")[0])).lastrowid
    raw = secrets.token_bytes(32)
    now = int(time.time() * 1000)
    db.execute("INSERT INTO session VALUES (?, ?, ?, ?)", (hashlib.sha256(raw).digest(), uid, now, now + 3600_000))
    db.commit()
    return uid, raw.hex()


def stream(path, want, secs):
    """Reads an event stream until want appears or secs pass."""
    s = socket.create_connection(("127.0.0.1", PORT), timeout=secs)
    s.sendall(f"GET {path} HTTP/1.1\r\nHost: localhost\r\n\r\n".encode())
    out, end = b"", time.time() + secs
    try:
        while time.time() < end and want.encode() not in out:
            s.settimeout(max(0.05, end - time.time()))
            b = s.recv(65536)
            if not b:
                break
            out += b
    except socket.timeout:
        pass
    s.close()
    return want.encode() in out


def wait_port():
    for _ in range(100):
        try:
            socket.create_connection(("127.0.0.1", PORT), timeout=0.2).close()
            return
        except OSError:
            time.sleep(0.1)
    sys.exit("server did not start")


def main():
    tmp = tempfile.mkdtemp()
    dbpath = os.path.join(tmp, "blog.db")
    env = dict(os.environ, PORT=str(PORT), BLOG_DB=dbpath, BLOG_WORKERS=str(WORKERS))
    srv = subprocess.Popen([os.path.join(ROOT, "build/server")], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        wait_port()
        kids = subprocess.run(["ps", "--ppid", str(srv.pid), "-o", "pid="], capture_output=True, text=True).stdout.split()
        check("4 workers under one supervisor", len(kids) == WORKERS, kids)
        db = sqlite3.connect(dbpath)
        _, a = user(db, "alice@example.com")
        _, b = user(db, "bob@example.com")
        http("POST", "/blogs", a, {"slug": "w", "title": "W"})
        _, loc, _ = http("POST", "/dash/w/posts", a, {"slug": "p", "title": "P"})
        pid = loc.rsplit("/", 1)[1]
        http("POST", f"/edit/{pid}", a, {"title": "Version one", "body": "first words", "action": "publish"})
        purl = "/b/w/p"
        check("the published post is served", http("GET", purl)[0] == 200, purl)

        # Cached everywhere, then written through one worker: fresh in all.
        many(purl)
        many("/")
        http("POST", f"/edit/{pid}", a, {"title": "Version one", "body": "second words"})
        pages = many(purl)
        check("an edit is visible in every worker at once", all("second words" in p[2] for p in pages),
              sum("first words" in p[2] for p in pages))
        st, _, _ = http("POST", f"/like/{pid}", b, {"on": "1"})
        check("like accepted", st == 303, st)
        pages = many(purl)
        check("a like is visible in every worker at once", all("♥ 1" in p[2] for p in pages), sum("♥ 0" in p[2] for p in pages))
        st, _, _ = http("POST", f"/edit/{pid}/unpublish", a)
        check("unpublish accepted", st == 303, st)
        pages = many(purl) + many("/")
        check("an unpublish is visible in every worker at once",
              all(p[0] == 404 for p in pages[:40]) and not any("Version one" in p[2] for p in pages[40:]),
              [p[0] for p in pages[:40]].count(200))
        http("POST", f"/edit/{pid}", a, {"title": "Version one", "body": "third words", "action": "publish"})

        # Live comments: 8 readers (on whichever workers took them).
        last = 0
        with concurrent.futures.ThreadPoolExecutor(8) as ex:
            got = [ex.submit(stream, f"/live/{pid}?after={last}&n=0", "Across workers", 4.0) for _ in range(8)]
            time.sleep(0.5)
            http("POST", f"/comment/{pid}", b, {"body": "Across workers"})
            seen = [g.result() for g in got]
        check("live comments reach readers on every worker", all(seen), seen)

        # Search, off the event loop, in every worker.
        res = many("/search?q=third", 20)
        check("search in every worker", all(r[0] == 200 and "Version one" in r[2] for r in res), [r[0] for r in res])

        # A worker that dies stops them all (systemd restarts the service).
        os.kill(int(kids[0]), 9)
        try:
            srv.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        def running(k):
            try:
                return open(f"/proc/{k}/stat").read().split()[2] != "Z"
            except OSError:
                return False
        for _ in range(20):
            alive = [k for k in kids[1:] if running(k)]
            if not alive:
                break
            time.sleep(0.1)
        check("a dead worker stops the supervisor and the others", srv.poll() is not None and not alive, (srv.poll(), alive))
    finally:
        if srv.poll() is None:
            srv.terminate()
        err = srv.communicate(timeout=10)[1].decode("utf-8", "replace")
        if "memory fault" in err or "ASSERT" in err:
            check("no worker crashed", False, err[-500:])
    print(f"\n{fails} failure(s)")
    sys.exit(1 if fails else 0)


main()
