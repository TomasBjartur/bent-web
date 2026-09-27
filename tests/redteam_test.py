#!/usr/bin/env python3
"""Attacks on the running server, each of which must fail and leave the
data as it was. Actors: an owner (blog "o"), a co-author of "o", an
outsider (with a blog of their own), and anonymous visitors.

- Every write route, by someone not allowed to use it.
- Drafts through every read path (post page, editor, comment pages, live
  stream, search, tags, author page, RSS).
- Cross-site requests, malformed sessions, odd ids, path tricks.
- Abuse of volume: likes, search, comment pages.

usage: tests/redteam_test.py   (needs ./build.sh)
"""
import concurrent.futures, hashlib, os, re, secrets, socket, sqlite3, subprocess, sys, tempfile, time, urllib.parse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORT = 8184
fails = 0


def check(name, ok, detail=""):
    global fails
    fails += 0 if ok else 1
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else f"   {detail}"))


def raw(data, timeout=10):
    s = socket.create_connection(("127.0.0.1", PORT), timeout=timeout)
    s.sendall(data)
    out = b""
    try:
        while True:
            b = s.recv(65536)
            if not b:
                break
            out += b
    except socket.timeout:
        pass
    s.close()
    return out


def http(method, path, sid=None, form=None, site="same-origin", extra=""):
    body = urllib.parse.urlencode(form).encode() if form is not None else b""
    h = f"{method} {path} HTTP/1.1\r\nHost: localhost\r\n"
    if site:
        h += f"Sec-Fetch-Site: {site}\r\n"
    if sid:
        h += f"Cookie: sid={sid}\r\n"
    if method == "POST":
        h += f"Content-Type: application/x-www-form-urlencoded\r\nContent-Length: {len(body)}\r\n"
    out = raw(h.encode() + extra.encode() + b"\r\n" + body)
    head, _, rb = out.partition(b"\r\n\r\n")
    try:
        st = int(head.split(b" ")[1])
    except (IndexError, ValueError):
        st = 0
    loc = re.search(rb"\r\nLocation: ([^\r]*)", head)
    return st, (loc.group(1).decode() if loc else None), rb.decode("utf-8", "replace")


def user(db, email, name, handle):
    uid = db.execute("INSERT INTO user(email, name, handle, created_ms) VALUES (?, ?, ?, 1)", (email, name, handle)).lastrowid
    raw_t = secrets.token_bytes(32)
    now = int(time.time() * 1000)
    db.execute("INSERT INTO session VALUES (?, ?, ?, ?)", (hashlib.sha256(raw_t).digest(), uid, now, now + 3600_000))
    db.commit()
    return uid, raw_t.hex()


def refused(st, loc=None):
    # Refused: an error status, or (for a signed-out writer) off to log in.
    return st in (400, 403, 404, 405, 409, 413, 429) or (st == 303 and loc == "/login")


def main():
    tmp = tempfile.mkdtemp()
    dbpath = os.path.join(tmp, "blog.db")
    env = dict(os.environ, PORT=str(PORT), BLOG_DB=dbpath, BLOG_WORKERS="1", BLOG_TICK_MS="500")
    srv = subprocess.Popen([os.path.join(ROOT, "build/server")], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        for _ in range(100):
            try:
                socket.create_connection(("127.0.0.1", PORT), timeout=0.2).close()
                break
            except OSError:
                time.sleep(0.1)
        db = sqlite3.connect(dbpath)
        o_id, o = user(db, "owner@example.com", "Owner", "owner")
        a_id, a = user(db, "coauthor@example.com", "Coauthor", "coauthor")
        x_id, x = user(db, "outsider@example.com", "Outsider", "outsider")
        http("POST", "/blogs", o, {"slug": "o", "title": "O"})
        http("POST", "/blogs", x, {"slug": "x", "title": "X"})
        http("POST", "/dash/o/authors", o, {"email": "coauthor@example.com"})
        _, loc, _ = http("POST", "/dash/o/posts", o, {"slug": "pub", "title": "Pub"})
        pub = loc.rsplit("/", 1)[1]
        http("POST", f"/edit/{pub}", o, {"title": "Pub", "body": "public words", "tags": "open", "action": "publish"})
        _, loc, _ = http("POST", "/dash/o/posts", o, {"slug": "secret", "title": "Secret"})
        draft = loc.rsplit("/", 1)[1]
        http("POST", f"/edit/{draft}", o, {"title": "Secretdraft title", "body": "zyzzyva draftonly words", "tags": "hiddentag"})
        http("POST", f"/comment/{pub}", o, {"body": "owner comment"})
        ocomment = db.execute("SELECT id FROM comment WHERE post_id = ?", (pub,)).fetchone()[0]

        def snapshot():
            q = lambda s: db.execute(s).fetchall()
            return (q("SELECT id, blog_id, slug, title, published, published_ms FROM post ORDER BY id"),
                    q("SELECT post_id, body_md FROM post_body ORDER BY post_id"), q("SELECT * FROM member ORDER BY blog_id, user_id"),
                    q("SELECT id, deleted, body_md FROM comment ORDER BY id"), q("SELECT * FROM post_like"), q("SELECT count(*) FROM op"),
                    q("SELECT id, slug, title, coalesce(domain, '') FROM blog ORDER BY id"), q("SELECT count(*) FROM image"), q("SELECT * FROM post_tag ORDER BY post_id, tag"))

        # WRITES BY THE WRONG PEOPLE
        before = snapshot()
        attempts = [
            ("save someone else's post", "POST", f"/edit/{pub}", {"title": "pwned", "body": "pwned"}),
            ("publish someone else's draft", "POST", f"/edit/{draft}", {"title": "pwned", "body": "pwned", "action": "publish"}),
            ("schedule someone else's draft", "POST", f"/edit/{draft}", {"title": "pwned", "body": "x", "action": "schedule", "at": str(int(time.time() // 60) + 60)}),
            ("unpublish someone else's post", "POST", f"/edit/{pub}/unpublish", {}),
            ("delete someone else's post", "POST", f"/edit/{pub}/delete", {}),
            ("sync into someone else's post", "POST", f"/edit/{pub}/sync", {"since": "0", "ops": "9.1.0.0.0.1.97;"}),
            ("create a post in someone else's blog", "POST", "/dash/o/posts", {"title": "pwned"}),
            ("add an author to someone else's blog", "POST", "/dash/o/authors", {"email": "outsider@example.com"}),
            ("remove an author from someone else's blog", "POST", f"/dash/o/authors/{a_id}/remove", {}),
            ("set a domain on someone else's blog", "POST", "/dash/o/domain", {"action": "set", "domain": "evil.example.com"}),
            ("delete someone else's comment", "POST", f"/comment/{ocomment}/delete", {}),
            ("like a draft", "POST", f"/like/{draft}", {"on": "1"}),
            ("comment on a draft", "POST", f"/comment/{draft}", {"body": "x"}),
            ("reply to a comment on another post", "POST", f"/comment/{draft}", {"body": "x", "parent": str(ocomment)}),
        ]
        for who, sid in (("outsider", x), ("anonymous", None)):
            for name, m, path, form in attempts:
                st, loc, _ = http(m, path, sid, form)
                check(f"{who}: {name} refused", refused(st, loc), (st, loc))
        st, _, _ = raw_upload(pub, x)
        check("outsider: upload into someone else's post refused", refused(st), st)
        # A co-author writes, but does not manage the blog.
        for name, m, path, form in [("add an author", "POST", "/dash/o/authors", {"email": "outsider@example.com"}),
                                    ("remove the owner", "POST", f"/dash/o/authors/{o_id}/remove", {}),
                                    ("set a domain", "POST", "/dash/o/domain", {"action": "set", "domain": "evil.example.com"})]:
            st, loc, _ = http(m, path, a, form)
            check(f"co-author: {name} refused", refused(st, loc), (st, loc))
        check("nothing changed", snapshot() == before, [x for x, y in zip(before, snapshot()) if x != y][:2])

        # CROSS-SITE REQUESTS
        for site in ("cross-site", "same-site"):
            st, _, _ = http("POST", f"/like/{pub}", x, {"on": "1"}, site=site)
            check(f"a {site} POST refused (CSRF)", st == 403, st)
        st, _, _ = http("POST", f"/like/{pub}", x, {"on": "1"}, site=None, extra="Origin: https://evil.example\r\n")
        check("a POST from another origin without Sec-Fetch-Site refused", st == 403, st)

        # DRAFTS THROUGH EVERY READ PATH
        dslug = "secret"
        for who, sid in (("outsider", x), ("anonymous", None)):
            for path in [f"/b/o/{dslug}", f"/edit/{draft}", f"/comments/{draft}?after=0", f"/comments/{draft}?after=0&frag=1", f"/live/{draft}?after=0&n=0",
                         f"/reply/{ocomment}"]:
                st, _, body = http("GET", path, sid)
                leak = "zyzzyva" in body or "Secretdraft" in body
                check(f"{who}: draft not readable at {path.split('?')[0]}", (st in (404, 403) or path.startswith("/reply")) and not leak, (st, leak))
            # (A search page shows its own query: look for the draft's other
            # words and its address, not the words searched for.)
            for path, words in [("/search?q=zyzzyva", ["draftonly", "Secretdraft", "/b/o/secret"]), ("/search?q=zyzz&frag=1", ["draftonly", "Secretdraft", "/b/o/secret"]),
                                ("/search?q=Secretdraft", ["zyzzyva", "/b/o/secret"]), ("/t/hiddentag", ["zyzzyva", "Secretdraft"]), (f"/u/{o_id}", ["zyzzyva", "Secretdraft"]),
                                ("/", ["zyzzyva", "Secretdraft"]), ("/b/o", ["zyzzyva", "Secretdraft"]), ("/feed.xml", ["zyzzyva", "Secretdraft"]), ("/b/o/feed.xml", ["zyzzyva", "Secretdraft"])]:
                st, _, body = http("GET", path, sid)
                check(f"{who}: no draft in {path}", not any(w in body for w in words), (st, [w for w in words if w in body]))
        # Even the co-author's own views must not be cached for others.
        http("GET", "/b/o", a)
        st, _, body = http("GET", "/b/o", x)
        check("a member's view of a blog is not served to an outsider", "Secretdraft" not in body)

        # SESSIONS AND ODD INPUT
        for bad in ["", "x", "0" * 64, "g" * 64, a.upper(), a + "00", a[:-2], "../" * 10, "%00" + a, a + ";sid=" + o]:
            st, loc, body = http("GET", "/dash", bad or None)
            check(f"malformed session {bad[:12]!r}: not signed in", st == 303 and loc == "/login", (st, loc))
        for path in ["/edit/0", "/edit/4294967296", "/edit/99999999999999999999", "/edit/-1", "/edit/1e3", "/like/%31", "/comments/1?after=-5",
                     "/comments/1?after=4294967295&upto=abc", "/b/o/..%2f..%2fetc", "/s/..%2f..%2fetc%2fpasswd", "/img/../../etc/passwd",
                     "/img/" + "0" * 31, "/s/app.css%00.js", "/%2e%2e/", "/b/o/pub%0d%0aSet-Cookie:%20x=1"]:
            out = raw(f"GET {path} HTTP/1.1\r\nHost: localhost\r\nCookie: sid={x}\r\n\r\n".encode())
            head = out.split(b"\r\n\r\n")[0]
            st = int(head.split(b" ")[1]) if head.startswith(b"HTTP/1.1 ") else 0
            check(f"odd path {path[:40]}: handled", st in (200, 303, 400, 403, 404) and b"Set-Cookie: x" not in head and b"root:" not in out, (st, head[:80]))

        # FIXED AFTER THE AUDIT
        # A search cannot put its words in front of other people's searches
        # (the cached page is keyed by the query it shows).
        http("GET", "/search?q=public%20words%20CALL%20555%20FOR%20SUPPORT")
        st, _, body = http("GET", "/search?q=public%20words")
        check("a search's page shows only its own query", "555" not in body and "SUPPORT" not in body, st)
        # Adding an author says nothing about emails unless you own the blog.
        r1 = http("POST", "/dash/o/authors?frag=1", x, {"email": "owner@example.com"})
        r2 = http("POST", "/dash/o/authors?frag=1", x, {"email": "nobody-at-all@example.com"})
        check("add-author reveals no account to a non-owner", r1[0] == r2[0] and r1[2] == r2[2] and "Only the blog's owner" in r1[2], (r1[0], r2[0], r1[2][:120]))
        # Expired challenges are swept (the tick: BLOG_TICK_MS).
        for i in range(50):
            db.execute("INSERT INTO challenge(hash, purpose, expires_ms) VALUES (?, 2, 2)", (hashlib.sha256(bytes([i])).digest(),))
        db.commit()
        time.sleep(1.5)
        http("GET", "/")
        time.sleep(0.5)
        left = db.execute("SELECT count(*) FROM challenge WHERE expires_ms < 1000").fetchone()[0]
        check("expired challenges are swept", left == 0, left)

        # VOLUME
        with concurrent.futures.ThreadPoolExecutor(16) as ex:
            codes = list(ex.map(lambda i: http("GET", f"/search?q=w{i}ord&frag=1")[0], range(300)))
        check("300 searches at once: answered, none failed", all(c in (200, 503) for c in codes) and srv.poll() is None, sorted(set(codes)))
        with concurrent.futures.ThreadPoolExecutor(8) as ex:
            codes = list(ex.map(lambda i: http("POST", f"/like/{pub}", x, {"on": str(i % 2)})[0], range(200)))
        limited = codes.count(429)
        check("likes by one account are rate limited", limited > 0, sorted(set(codes)))
        check("the server is still up", srv.poll() is None and http("GET", "/healthz")[0] == 200)
    finally:
        srv.terminate()
        err = srv.communicate(timeout=10)[1].decode("utf-8", "replace")
        if "ASSERT" in err or "memory fault" in err:
            check("no crash", False, err[-400:])
    print(f"\n{fails} failure(s)")
    sys.exit(1 if fails else 0)


def raw_upload(pid, sid):
    png = b"\x89PNG\r\n\x1a\n" + b"\x00" * 64
    out = raw(f"POST /upload/{pid} HTTP/1.1\r\nHost: localhost\r\nSec-Fetch-Site: same-origin\r\nCookie: sid={sid}\r\n"
              f"Content-Type: image/png\r\nContent-Length: {len(png)}\r\n\r\n".encode() + png)
    head = out.split(b"\r\n\r\n")[0]
    return int(head.split(b" ")[1]), None, out


main()
