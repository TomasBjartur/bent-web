#!/usr/bin/env python3
"""End-to-end tests: honest flows and attacks against a running server.

Starts build/server on a fresh database, creates users and sessions
directly in SQLite (login is not implemented yet), then drives the app over
raw HTTP. usage: tests/app_test.py
"""
import hashlib, os, re, secrets, socket, sqlite3, subprocess, sys, tempfile, time, urllib.parse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORT = 8099
fails = 0


def check(name, ok, detail=""):
    global fails
    fails += 0 if ok else 1
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else f"   {detail}"))


def req(method, path, token=None, form=None, site="same-origin", extra=b"", host="localhost"):
    body = urllib.parse.urlencode(form).encode() if form is not None else b""
    head = f"{method} {path} HTTP/1.1\r\nHost: {host}\r\n"
    if token:
        head += f"Cookie: sid={token}\r\n"
    if site:
        head += f"Sec-Fetch-Site: {site}\r\n"
    if form is not None:
        head += f"Content-Type: application/x-www-form-urlencoded\r\nContent-Length: {len(body)}\r\n"
    data = head.encode() + extra + b"\r\n" + body
    s = socket.create_connection(("127.0.0.1", PORT), timeout=10)
    s.sendall(data)
    out = b""
    try:
        while True:
            b = s.recv(65536)
            if not b:
                break
            out += b
    except (ConnectionResetError, socket.timeout):
        pass
    s.close()
    head, _, body = out.partition(b"\r\n\r\n")
    status = int(head.split(b" ")[1]) if head.startswith(b"HTTP/1.1 ") else 0
    loc = re.search(rb"\r\nLocation: ([^\r]*)", head)
    return status, (loc.group(1).decode() if loc else None), body.decode("utf-8", "replace"), head.decode("latin-1")


def raw_post(path, token, data, site="same-origin"):
    head = f"POST {path} HTTP/1.1\r\nHost: localhost\r\nContent-Type: image/png\r\nContent-Length: {len(data)}\r\n"
    if token:
        head += f"Cookie: sid={token}\r\n"
    if site:
        head += f"Sec-Fetch-Site: {site}\r\n"
    s = socket.create_connection(("127.0.0.1", PORT), timeout=10)
    try:
        s.sendall(head.encode() + b"\r\n" + data)
    except (BrokenPipeError, ConnectionResetError):
        pass
    out = b""
    try:
        while True:
            b = s.recv(65536)
            if not b:
                break
            out += b
    except (ConnectionResetError, socket.timeout):
        pass
    s.close()
    h, _, body = out.partition(b"\r\n\r\n")
    return (int(h.split(b" ")[1]) if h.startswith(b"HTTP/1.1 ") else 0), body.decode("latin-1")


def raw_get(path):
    s = socket.create_connection(("127.0.0.1", PORT), timeout=10)
    s.sendall(f"GET {path} HTTP/1.1\r\nHost: localhost\r\n\r\n".encode())
    out = b""
    while True:
        b = s.recv(65536)
        if not b:
            break
        out += b
    s.close()
    return out.partition(b"\r\n\r\n")[2]


def main():
    tmp = tempfile.mkdtemp()
    dbpath = os.path.join(tmp, "blog.db")
    env = dict(os.environ, PORT=str(PORT), BLOG_DB=dbpath, BLOG_TICK_MS="0")
    srv = subprocess.Popen([os.path.join(ROOT, "build/server")], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        for _ in range(50):
            try:
                socket.create_connection(("127.0.0.1", PORT), timeout=0.2).close()
                break
            except OSError:
                time.sleep(0.1)
        run(dbpath)
    finally:
        srv.terminate()
        srv.wait()
        err = srv.stderr.read().decode("utf-8", "replace").strip()
        if err:
            print("server stderr:", err[-2000:])
    print(f"\n{fails} failure(s)")
    sys.exit(1 if fails else 0)


def user(db, email, name):
    cur = db.execute("INSERT INTO user(email, name, created_ms) VALUES (?, ?, 1)", (email, name))
    uid = cur.lastrowid
    raw = secrets.token_bytes(32)
    now = int(time.time() * 1000)
    db.execute("INSERT INTO session VALUES (?, ?, ?, ?)", (hashlib.sha256(raw).digest(), uid, now, now + 3600_000))
    db.commit()
    return uid, raw.hex()


def run(dbpath):
    db = sqlite3.connect(dbpath)
    a_id, a = user(db, "alice@example.com", "Alice")
    b_id, b = user(db, "bob@example.com", "Bob")
    c_id, c = user(db, "mallory@example.com", "Mallory")

    # Honest flow.
    st, _, body, _ = req("GET", "/")
    check("home renders", st == 200 and "Recent posts" in body, st)
    st, loc, _, _ = req("GET", "/dash")
    check("dash redirects anonymous to login", st == 303 and loc == "/login", (st, loc))
    st, _, body, _ = req("GET", "/dash", a)
    check("dash for Alice", st == 200 and "Your blogs" in body, st)
    st, loc, _, _ = req("POST", "/blogs", a, {"slug": "alice", "title": "Alice's <Notes>"})
    check("create blog", st == 303 and loc == "/dash/alice", (st, loc))
    st, _, body, _ = req("GET", "/dash/alice", a)
    check("blog admin", st == 200 and "Alice&#39;s &lt;Notes&gt;" in body, st)
    st, loc, _, _ = req("POST", "/dash/alice/posts", a, {"slug": "first", "title": "First post"})
    check("create post", st == 303 and loc and loc.startswith("/edit/"), (st, loc))
    pid = loc.rsplit("/", 1)[1]
    xss = '<script>alert("x")</script> & "quotes" \'single\''
    st, loc, _, _ = req("POST", f"/edit/{pid}", a, {"title": "First <post>", "body": "Hello " + xss + "\nsecond line"})
    check("save post", st == 303 and loc == f"/edit/{pid}", (st, loc))
    st, _, body, _ = req("GET", f"/edit/{pid}", a)
    check("editor shows escaped markdown", st == 200 and "&lt;script&gt;" in body and "<script>" not in body, st)

    # Drafts are private.
    st, _, body, _ = req("GET", "/b/alice/first")
    check("draft is 404 for anonymous", st == 404, st)
    st, _, body, _ = req("GET", "/b/alice/first", c)
    check("draft is 404 for outsider", st == 404, st)
    st, _, body, _ = req("GET", "/b/alice/first", a)
    check("draft visible to owner, body spliced", st == 200 and "second line" in body and "Draft" in body, (st, body[:200]))
    check("stored body is escaped", "&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt;" in body and "<script>" not in body)
    check("title escaped", "First &lt;post&gt;" in body)

    # Publish: now public.
    st, loc, _, _ = req("POST", f"/edit/{pid}/publish", a)
    check("publish", st == 303, st)
    st, _, body, _ = req("GET", "/b/alice/first")
    check("published post public", st == 200 and "second line" in body and "Draft" not in body, st)
    st, _, body, _ = req("GET", "/")
    check("home lists it", "First &lt;post&gt;" in body)
    st, _, body, _ = req("GET", "/b/alice")
    check("blog page lists it", st == 200 and "/b/alice/first" in body, st)

    # CSRF.
    st, _, _, _ = req("POST", f"/edit/{pid}/unpublish", a, site=None)
    check("CSRF: no Sec-Fetch-Site -> 403", st == 403, st)
    st, _, _, _ = req("POST", f"/edit/{pid}/unpublish", a, site="cross-site")
    check("CSRF: cross-site -> 403", st == 403, st)
    st, _, _, _ = req("POST", f"/edit/{pid}/unpublish", a, site="same-site")
    check("CSRF: same-site (not same-origin) -> 403", st == 403, st)
    st, _, body, _ = req("GET", "/b/alice/first")
    check("post still published after CSRF attempts", st == 200)

    # Outsider attacks.
    st, _, _, _ = req("GET", f"/edit/{pid}", c)
    check("outsider: editor 404", st == 404, st)
    st, _, _, _ = req("POST", f"/edit/{pid}", c, {"title": "pwned", "body": "pwned"})
    check("outsider: save 403", st == 403, st)
    st, _, _, _ = req("POST", f"/edit/{pid}/delete", c)
    check("outsider: delete 403", st == 403, st)
    st, _, _, _ = req("GET", "/dash/alice", c)
    check("outsider: blog admin 404", st == 404, st)
    st, _, _, _ = req("POST", "/dash/alice/posts", c, {"slug": "spam", "title": "spam"})
    check("outsider: create post 403", st == 403, st)
    st, _, _, _ = req("POST", "/dash/alice/authors", c, {"email": "mallory@example.com"})
    check("outsider: add self as author 403", st == 403, st)
    st, _, _, _ = req("POST", f"/edit/{pid}", None, {"title": "anon", "body": "anon"})
    check("anonymous: save 403", st == 403, st)
    forged = secrets.token_hex(32)
    st, _, _, _ = req("POST", f"/edit/{pid}", forged, {"title": "forged", "body": "forged"})
    check("forged cookie: save 403", st == 403, st)
    st, _, _, _ = req("POST", f"/edit/{pid}", a.upper(), {"title": "upper", "body": "upper"})
    check("uppercase variant of a real token: 403", st == 403, st)
    st, _, _, _ = req("POST", f"/edit/{pid}", a, {"title": "x"}, extra=f"Cookie: sid={c}\r\n".encode())
    check("two Cookie headers: rejected", st == 400, st)
    st, _, body, _ = req("GET", "/b/alice/first")
    check("post unchanged after attacks", "second line" in body and "pwned" not in body and "forged" not in body)

    # Authors: add Bob, Bob writes, Bob removed, Bob cannot write.
    st, _, _, _ = req("POST", "/dash/alice/authors", a, {"email": "bob@example.com"})
    check("add author", st == 303, st)
    st, loc, _, _ = req("POST", "/dash/alice/posts", b, {"slug": "bobs", "title": "Bob's draft"})
    check("author creates post", st == 303 and loc.startswith("/edit/"), (st, loc))
    bpid = loc.rsplit("/", 1)[1]
    st, _, _, _ = req("POST", "/dash/alice/authors", b, {"email": "mallory@example.com"})
    check("author cannot add authors", st == 403, st)
    st, _, _, _ = req("POST", f"/dash/alice/authors/{a_id}/remove", b)
    check("author cannot remove the owner", st == 403, st)
    st, _, _, _ = req("POST", f"/dash/alice/authors/{a_id}/remove", a)
    check("owner cannot remove themself", st == 403, st)
    st, _, _, _ = req("POST", f"/dash/alice/authors/{b_id}/remove", a)
    check("owner removes author", st == 303, st)
    st, _, _, _ = req("POST", f"/edit/{bpid}", b, {"title": "late", "body": "late"})
    check("removed author cannot edit", st == 403, st)
    st, _, _, _ = req("GET", f"/edit/{bpid}", b)
    check("removed author cannot open editor", st == 404, st)

    # Input validation.
    st, _, _, _ = req("POST", "/blogs", a, {"slug": "../etc", "title": "x"})
    check("bad slug -> 400", st == 400, st)
    st, _, _, _ = req("POST", "/blogs", a, {"slug": "alice", "title": "dup"})
    check("duplicate slug -> 409", st == 409, st)
    st, _, _, _ = req("POST", "/blogs", a, {"slug": "ctl", "title": "a\x01b"})
    check("control char in title -> 400", st == 400, st)
    check("unicode title ok", req("POST", "/blogs", a, {"slug": "uni", "title": "Café ☕ 日本"})[0] == 303)
    st, _, body, _ = req("GET", "/b/uni")
    check("unicode round-trips", "Café ☕ 日本" in body, body[:300])

    # Logout ends the session server-side.
    st, loc, _, head = req("POST", "/logout", a)
    check("logout clears cookie", st == 303 and "Max-Age=0" in head, (st, head))
    st, loc, _, _ = req("GET", "/dash", a)
    check("old token no longer works", st == 303 and loc == "/login", (st, loc))

    # Usability: addresses made from titles, save-and-publish, Edit links,
    # bylines, cached assets.
    st, loc, _, _ = req("POST", "/blogs", b, {"slug": "", "title": "Bob's Great Blog!"})
    check("blog address from title", st == 303 and loc == "/dash/bob-s-great-blog", (st, loc))
    st, loc, _, _ = req("POST", "/dash/bob-s-great-blog/posts", b, {"title": "Hello, World"})
    check("post address from title", st == 303 and loc and loc.startswith("/edit/"), (st, loc))
    ppid = loc.rsplit("/", 1)[1]
    st, _, body, _ = req("GET", f"/edit/{ppid}", b)
    check("new post: Publish button", st == 200 and 'value="publish"' in body and "Unpublish" not in body, st)
    st, loc, _, _ = req("POST", f"/edit/{ppid}", b, {"title": "Hello, World", "body": "Words here.", "action": "publish"})
    check("save and publish in one step, landing on the post", st == 303 and loc == "/b/bob-s-great-blog/hello-world?published=1", (st, loc))
    st, _, body, _ = req("GET", "/b/bob-s-great-blog/hello-world")
    check("published by the save", st == 200 and "Words here." in body and "Draft" not in body, st)
    check("byline: linked author and reading time", f'<strong><a href="/u/{b_id}">Bob</a></strong>' in body and "1 min read" in body, body[:600])
    check("no Edit link for anonymous", f'href="/edit/{ppid}"' not in body)
    st, _, body, _ = req("GET", "/b/bob-s-great-blog/hello-world", b)
    check("Edit link for the author", f'href="/edit/{ppid}"' in body)
    st, _, body, _ = req("GET", "/b/bob-s-great-blog/hello-world", c)
    check("no Edit link for an outsider", f'href="/edit/{ppid}"' not in body)
    st, _, body, _ = req("GET", f"/edit/{ppid}", b)
    check("published post: Update and Unpublish", 'value="publish"' in body and "Unpublish" in body and ">Update<" in body)
    st, loc, _, _ = req("POST", f"/edit/{ppid}", c, {"title": "x", "body": "pwned", "action": "publish"})
    check("outsider: save-and-publish 403", st == 403, st)
    st, _, body, _ = req("GET", "/")
    check("home: author and publication in the feed", "Bob&#39;s Great Blog!" in body and "Bob" in body and "min read" in body)
    st, _, body, _ = req("GET", "/b/bob-s-great-blog")
    check("blog page: by its owner", "by Bob" in body, body[:600])
    m = re.search(r'href="(/s/app\.css\?v=[0-9a-f]+)"', body)
    check("pages link a versioned stylesheet", m is not None)
    st, _, css, head = req("GET", m.group(1) if m else "/s/app.css")
    check("stylesheet served, cached immutably", st == 200 and "text/css" in head and "immutable" in head and ".article" in css, head)
    _, _, _, head = req("GET", "/")
    check("pages are not cached", "no-store" in head, head)
    st, _, _, _ = req("GET", "/s/nope.js")
    check("unknown asset 404", st == 404, st)

    # Write: a new untitled draft in your only blog, which takes its
    # address from its title when first published (never after).
    req("POST", "/blogs", b, {"title": "Bob Two"})
    st, loc, _, _ = req("POST", "/write", b)
    check("Write with several blogs: to the dashboard", st == 303 and loc == "/dash", (st, loc))
    st, loc, _, _ = req("POST", "/write", c)
    check("Write with no blog: to the dashboard", st == 303 and loc == "/dash", (st, loc))
    _, _, body, _ = req("GET", "/dash", c)
    check("dashboard without a blog: welcome", "Welcome!" in body and "Create my blog" in body)
    req("POST", "/blogs", c, {"title": "Mallory Writes"})
    st, loc, _, _ = req("POST", "/write", c)
    check("Write with one blog: a new draft in the editor", st == 303 and loc and loc.startswith("/edit/"), (st, loc))
    dpid = loc.rsplit("/", 1)[1]
    slug = db.execute("SELECT slug, title FROM post WHERE id = ?", (dpid,)).fetchall()[0]  # (fetchone would keep a read open)
    check("draft: placeholder address, Untitled", slug[0].startswith("draft-") and slug[1] == "Untitled", slug)
    st, loc2, _, _ = req("POST", "/write", c)
    check("a second draft does not collide", st == 303 and loc2 != loc, (st, loc2))
    st, loc, _, _ = req("POST", f"/edit/{dpid}", c, {"title": "Hello, World", "body": "m", "action": "publish"})
    check("first publish: address from title", loc == "/b/mallory-writes/hello-world?published=1", loc)
    _, _, body, _ = req("GET", "/b/mallory-writes/hello-world?published=1", c)
    check("notice for the author", "Your post is live" in body)
    _, _, body, _ = req("GET", "/b/mallory-writes/hello-world?published=1")
    check("no notice for readers", "Your post is live" not in body and "Hello, World" in body)
    req("POST", f"/edit/{dpid}/unpublish", c)
    st, loc, _, _ = req("POST", f"/edit/{dpid}", c, {"title": "Renamed", "body": "m", "action": "publish"})
    check("published address never changes", loc == "/b/mallory-writes/hello-world?published=1", loc)
    st, loc, _, _ = req("POST", "/dash/mallory-writes/posts", c)
    st, loc, _, _ = req("POST", loc, c, {"title": "Hello, World", "body": "again", "action": "publish"})
    check("same title again: deduplicated address", loc == "/b/mallory-writes/hello-world-2?published=1", loc)
    st, loc, _, _ = req("POST", "/write", None)
    check("Write anonymously: no draft, off to log in", st == 303 and loc == "/dash", (st, loc))

    # Author pages: only for people who have published.
    st, _, body, _ = req("GET", f"/u/{c_id}")
    check("author page lists their posts", st == 200 and "Mallory" in body and "hello-world-2" in body, st)
    st, _, _, _ = req("GET", f"/u/{a_id}")
    check("author page for Alice (published)", st == 200, st)
    # (Also a regression test: another process writes after posts were
    # viewed. The server once kept a read snapshot open after serving a
    # post body, and every write after an outside write failed "locked".)
    q = sqlite3.connect(dbpath)
    uid = q.execute("INSERT INTO user(email, name, created_ms) VALUES ('quiet@example.com', 'Quiet', 1)").lastrowid
    q.commit()
    q.close()
    st, _, body, _ = req("GET", f"/u/{uid}")
    check("no author page for someone who never published", st == 404 and "Quiet" not in body, st)
    st, _, _, _ = req("GET", "/u/abc")
    check("author page: bad id 404", st == 404, st)

    # The feed cache: every write is visible at once, and signed-in and
    # anonymous visitors get their own header.
    for _ in range(2):
        req("GET", "/"), req("GET", "/", b), req("GET", "/b/bob-s-great-blog")
    st, loc, _, _ = req("POST", "/dash/bob-s-great-blog/posts", b, {"title": "Cache probe"})
    cpid = loc.rsplit("/", 1)[1]
    req("POST", f"/edit/{cpid}", b, {"title": "Cache probe", "body": "x", "action": "publish"})
    check("cache: published post on home at once", "Cache probe" in req("GET", "/")[2])
    check("cache: and on its blog page", "Cache probe" in req("GET", "/b/bob-s-great-blog")[2])
    req("POST", f"/edit/{cpid}/unpublish", b)
    check("cache: unpublished post gone from home", "Cache probe" not in req("GET", "/")[2])
    check("cache: and from its blog page", "Cache probe" not in req("GET", "/b/bob-s-great-blog")[2])
    req("POST", f"/edit/{cpid}", b, {"title": "Cache probe 2", "body": "x", "action": "publish"})
    req("POST", f"/edit/{cpid}/delete", b)
    check("cache: deleted post gone", "Cache probe" not in req("GET", "/")[2] and "Cache probe" not in req("GET", "/b/bob-s-great-blog")[2])
    anon, signed_in = req("GET", "/")[2], req("GET", "/", b)[2]
    check("cache: anonymous home has no Log out", "Log out" not in anon and "Log in" in anon)
    check("cache: signed-in home has Log out", "Log out" in signed_in and "Log in" not in signed_in)
    check("cache: anonymous again", "Log out" not in req("GET", "/")[2])

    # RSS: well-formed XML, absolute links, escaped text, fresh after writes.
    import xml.etree.ElementTree as ET
    st, _, xml, head = req("GET", "/feed.xml")
    check("site feed served as RSS", st == 200 and "application/rss+xml" in head, head[:200])
    try:
        root = ET.fromstring(xml.encode())
        items = root.findall("./channel/item")
        titles = [i.findtext("title") for i in items]
        links = [i.findtext("link") for i in items]
        check("site feed parses, has items", len(items) >= 2, titles)
        check("feed titles are text, escaped on the wire", "First <post>" in titles and "First &lt;post&gt;" in xml, titles)
        check("feed links are absolute", all(l.startswith("http") and "/b/" in l for l in links), links[:3])
        check("feed dates are RFC 822", all(re.match(r"^[A-Z][a-z]{2}, \d\d [A-Z][a-z]{2} \d{4} \d\d:\d\d:\d\d \+0000$", i.findtext("pubDate") or "") for i in items),
              [i.findtext("pubDate") for i in items][:2])
    except ET.ParseError as ex:
        check("site feed parses", False, str(ex))
    st, _, xml, head = req("GET", "/b/bob-s-great-blog/feed.xml")
    check("blog feed", st == 200 and "Hello, World" in xml and "application/rss+xml" in head, st)
    try:
        ET.fromstring(xml.encode())
        check("blog feed parses", True)
    except ET.ParseError as ex:
        check("blog feed parses", False, str(ex))
    st, _, _, _ = req("GET", "/b/nope/feed.xml")
    check("unknown blog feed 404", st == 404, st)
    st, loc, _, _ = req("POST", "/dash/bob-s-great-blog/posts", b, {"title": "Feed probe"})
    req("POST", loc, b, {"title": "Feed probe", "body": "x", "action": "publish"})
    check("feed fresh after publish", "Feed probe" in req("GET", "/feed.xml")[2] and "Feed probe" in req("GET", "/b/bob-s-great-blog/feed.xml")[2])
    _, _, body, _ = req("GET", "/")
    check("pages advertise the feed", 'type="application/rss+xml"' in body)

    # Search: published posts only, snippets escaped with marked matches,
    # hostile queries are just words.
    st, loc, _, _ = req("POST", "/dash/bob-s-great-blog/posts", b, {"title": "Searchable"})
    req("POST", loc, b, {"title": "Searchable", "body": "The zebracorn <b>galloped</b> & sang.", "action": "publish"})
    st, loc, _, _ = req("POST", "/dash/bob-s-great-blog/posts", b, {"title": "Secret draft"})
    req("POST", loc, b, {"title": "Secret draft", "body": "zebracorn plans nobody may read"})
    st, _, body, _ = req("GET", "/search?q=zebracorn")
    check("search finds the published post", st == 200 and "Searchable" in body, st)
    check("search never shows drafts", "Secret draft" not in body and "nobody may read" not in body)
    check("snippet marks the match", "<mark>zebracorn</mark>" in body, body[body.find("snippet"):][:300])
    check("snippet is escaped", "&lt;b&gt;galloped&lt;/b&gt; &amp; sang" in body and "<b>galloped" not in body)
    check("prefix search", "Searchable" in req("GET", "/search?q=zebrac")[2])
    check("case and accents folded", "Searchable" in req("GET", "/search?q=" + urllib.parse.quote("ZEBRACÓRN"))[2])
    for q in ['"', '""', 'zebracorn"', 'NEAR(', 'a OR', '*', '^', ')(', "'", '%00', 'x' * 600, ' ' * 50, '\x01zebracorn']:
        st, _, body, _ = req("GET", "/search?q=" + urllib.parse.quote(q, safe=''))
        check(f"hostile query {q[:12]!r}: fine", st == 200, st)
    st, _, body, _ = req("GET", "/search?q=" + urllib.parse.quote('zebracorn" OR "secret'))
    check("quote injection is literal", "Secret draft" not in body, body[-300:])
    st, _, body, _ = req("GET", "/search")
    check("empty search: just the box", st == 200 and 'name="q"' in body and "No posts match" not in body)
    st, _, body, _ = req("GET", "/search?q=" + urllib.parse.quote('"><script>alert(1)</script>', safe=''))
    check("query echoed escaped", "<script>alert" not in body and "&lt;script&gt;" in body, (st, body[body.find('name="q"'):][:300]))

    # Likes and comments.
    st, loc, _, _ = req("POST", "/dash/bob-s-great-blog/posts", b, {"title": "Talk"})
    tpid = loc.rsplit("/", 1)[1]
    req("POST", loc, b, {"title": "Talk", "body": "Discuss.", "action": "publish"})
    turl = "/b/bob-s-great-blog/talk"
    _, _, body, _ = req("GET", turl)
    check("post page: like count and comments for readers", "♥ 0" in body and 'id="comments"' in body and "Log in</a> or" in body)
    st, loc, _, _ = req("POST", f"/like/{tpid}", None, {"on": "1"})
    check("anonymous like: to log in", st == 303 and loc == "/login", (st, loc))
    st, loc, _, _ = req("POST", f"/like/{tpid}", c, {"on": "1"})
    check("like: back to the post", st == 303 and loc == turl + "#social", (st, loc))
    req("POST", f"/like/{tpid}", c, {"on": "1"})
    _, _, body, _ = req("GET", turl, c)
    check("liked once, shown as liked", "♥ 1" in body and 'class="like on"' in body, body[body.find('class="social"'):][:300])
    _, _, body, _ = req("GET", turl)
    check("others see the count", "♥ 1" in body and 'class="like on"' not in body)
    req("POST", f"/like/{tpid}", c, {"on": "0"})
    check("unlike", "♥ 0" in req("GET", turl)[2])
    st, loc, _, _ = req("POST", "/dash/bob-s-great-blog/posts", b, {"title": "Quiet draft"})
    qd = loc.rsplit("/", 1)[1]
    st, _, _, _ = req("POST", f"/like/{qd}", c, {"on": "1"})
    check("cannot like a draft", st == 403, st)
    st, _, _, _ = req("POST", f"/comment/{qd}", c, {"body": "hi"})
    check("cannot comment on a draft", st == 403, st)
    st, loc, _, _ = req("POST", f"/comment/{tpid}", None, {"body": "hi"})
    check("anonymous comment: to log in", st == 303 and loc == "/login", (st, loc))
    st, loc, _, _ = req("POST", f"/comment/{tpid}", c, {"body": "First! <script>alert(1)</script> **bold**"})
    check("comment: to its anchor", st == 303 and loc.startswith(turl + "#c"), (st, loc))
    c1 = loc.rsplit("#c", 1)[1]
    _, _, body, _ = req("GET", turl)
    check("comment shown, markdown rendered, script inert", "<strong>bold</strong>" in body and "&lt;script&gt;" in body and "<script>alert" not in body)
    check("comment count", "1 comment" in body)
    st, _, body, _ = req("GET", f"/reply/{c1}", b)
    check("reply page shows the comment and a form", st == 200 and "<strong>bold</strong>" in body and f'name="parent" value="{c1}"' in body, st)
    st, loc, _, _ = req("POST", f"/comment/{tpid}", b, {"body": "A reply", "parent": c1})
    c2 = loc.rsplit("#c", 1)[1]
    _, _, body, _ = req("GET", turl)
    i1, i2 = body.find(f'id="c{c1}"'), body.find(f'id="c{c2}"')
    check("reply nested under its parent", 0 < i1 < i2 and body.find('class="replies"', i1) < i2, (i1, i2))
    st, _, _, _ = req("POST", f"/comment/{tpid}", c, {"body": "   "})
    check("blank comment: 400", st == 400, st)
    st, _, _, _ = req("POST", f"/comment/{tpid}", c, {"body": "x" * 10001})
    check("comment over 10000 characters: 400", st == 400, st)
    st, _, _, _ = req("POST", f"/comment/{tpid}/delete", c)
    check("deleting a comment id that is a post id: not by route confusion", st in (403, 404, 409), st)
    st, _, _, _ = req("POST", f"/comment/{c2}/delete", c)
    check("outsider cannot delete someone else's comment", st == 403, st)
    st, _, _, _ = req("POST", f"/comment/{c1}/delete", c)
    check("author deletes their comment", st == 303, st)
    _, _, body, _ = req("GET", turl)
    check("deleted: text gone, reply kept", "First!" not in body and "[deleted]" in body and "A reply" in body)
    st, _, _, _ = req("POST", f"/comment/{c2}/delete", b)
    check("a member of the blog moderates", st == 303 and "A reply" not in req("GET", turl)[2], st)
    codes = [req("POST", f"/comment/{tpid}", c, {"body": f"spam {i}"})[0] for i in range(6)]
    check("comment rate limit: 429", 429 in codes and codes.count(303) <= 4, codes)

    # Tags: normalized on save, shown on the post, a page per tag.
    st, loc, _, _ = req("POST", "/dash/bob-s-great-blog/posts", b, {"title": "Tagged"})
    tgid = loc.rsplit("/", 1)[1]
    req("POST", loc, b, {"title": "Tagged", "body": "t", "tags": "Machine Learning, rust, Rust, <b>x</b>", "action": "publish"})
    _, _, body, _ = req("GET", "/b/bob-s-great-blog/tagged")
    check("tags on the post", 'href="/t/machine-learning">#machine-learning' in body and 'href="/t/rust"' in body and 'href="/t/b-x-b"' in body, body[body.find('class="tags"'):][:400])
    check("tag page lists the post", "Tagged" in req("GET", "/t/rust")[2])
    check("unknown tag: empty page", "No posts with this tag" in req("GET", "/t/nothing-here")[2])
    _, _, body, _ = req("GET", f"/edit/{tgid}", b)
    check("editor shows the tags", 'value="machine-learning, rust, b-x-b"' in body, body[body.find('name="tags"'):][:200])
    req("POST", f"/edit/{tgid}", b, {"title": "Tagged", "body": "t", "tags": "", "action": "publish"})
    check("tags cleared, tag page fresh", "Tagged" not in req("GET", "/t/rust")[2])
    req("POST", f"/edit/{tgid}", b, {"title": "Tagged", "body": "t2", "action": "publish"})
    check("a save without a tags field keeps tags as they are", "Tagged" not in req("GET", "/t/rust")[2])
    st, loc, _, _ = req("POST", "/dash/bob-s-great-blog/posts", b, {"title": "Draft tagged"})
    req("POST", loc, b, {"title": "Draft tagged", "body": "t", "tags": "rust"})
    check("drafts never on tag pages", "Draft tagged" not in req("GET", "/t/rust")[2])

    # Scheduled posts: set a time, see it on the dashboard, cancel; a due
    # schedule publishes on the next request with its address from its
    # title; times in the past are refused.
    st, loc, _, _ = req("POST", "/dash/bob-s-great-blog/posts", b)
    spid = loc.rsplit("/", 1)[1]
    soon = int(time.time() // 60) + 60
    st, loc, _, _ = req("POST", f"/edit/{spid}", b, {"title": "Tomorrow's news", "body": "Later.", "action": "schedule", "at": str(soon)})
    check("schedule: back to the editor", st == 303 and loc == f"/edit/{spid}", (st, loc))
    _, _, body, _ = req("GET", f"/edit/{spid}", b)
    check("editor shows the schedule and Cancel", "Scheduled for" in body and 'value="unschedule"' in body)
    _, _, body, _ = req("GET", "/dash/bob-s-great-blog", b)
    check("dashboard: Scheduled badge", "badge sched" in body)
    check("not public before its time", "Tomorrow" not in req("GET", "/")[2])
    st, _, _, _ = req("POST", f"/edit/{spid}", b, {"title": "Tomorrow's news", "body": "Later.", "action": "schedule", "at": str(int(time.time() // 60) - 5)})
    check("schedule in the past: 400", st == 400, st)
    req("POST", f"/edit/{spid}", b, {"title": "Tomorrow's news", "body": "Later.", "action": "unschedule"})
    check("cancelled", "Scheduled for" not in req("GET", f"/edit/{spid}", b)[2])
    st, _, _, _ = req("POST", f"/edit/{spid}", b, {"title": "Tomorrow's news", "body": "Later.", "action": "schedule", "at_local": "2099-01-01T10:00"})
    check("schedule without JavaScript (UTC)", "2099-01-01 10:00 UTC" in req("GET", f"/edit/{spid}", b)[2])
    st, _, _, _ = req("POST", f"/edit/{spid}", c, {"title": "x", "body": "x", "action": "schedule", "at": str(soon)})
    check("outsider cannot schedule", st == 403, st)
    q = sqlite3.connect(dbpath)
    q.execute("UPDATE post SET publish_at_ms = ? WHERE id = ?", (int(time.time() * 1000) - 1000, spid))
    q.commit()
    q.close()
    _, _, body, _ = req("GET", "/")
    check("due: published on the next request, home fresh", "Tomorrow&#39;s news" in body, body[:0])
    st, _, body, _ = req("GET", "/b/bob-s-great-blog/tomorrow-s-news")
    check("due: address from its title", st == 200 and "Later." in body, st)

    # Images: members of the post's blog upload; the type is checked by its
    # bytes; images are served inert and cached; Markdown shows only these.
    import struct, zlib
    def png(w, h):
        raw = b"".join(b"\x00" + b"\xff\x00\x00" * w for _ in range(h))
        def chunk(t, d):
            return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
        return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
    def up(pid, tok, data, site="same-origin"):
        return raw_post(f"/upload/{pid}", tok, data, site)
    img = png(4, 3)
    st, path = up(tgid, b, img)
    check("member uploads an image", st == 200 and re.fullmatch(r"/img/[0-9a-f]{32}", path.strip() or ""), (st, path))
    path = path.strip()
    st, _, got, head = req("GET", path)
    check("image served with its type, inert, cached", st == 200 and "Content-Type: image/png" in head and "nosniff" in head and "immutable" in head, head)
    check("image bytes intact", got.encode("latin-1", "replace") != b"" and raw_get(path) == img)
    check("unknown image 404", req("GET", "/img/" + "0" * 32)[0] == 404)
    check("malformed image key 404", req("GET", "/img/../../etc")[0] in (400, 404))
    check("outsider cannot upload", up(tgid, c, img)[0] == 403)
    check("anonymous cannot upload", up(tgid, None, img)[0] == 403)
    check("cross-site upload refused", up(tgid, b, img, "cross-site")[0] == 403)
    check("not an image: 400", up(tgid, b, b"<svg onload=alert(1)>")[0] == 400)
    check("HTML with a text type: 400", up(tgid, b, b"<html><script>x</script>")[0] == 400)
    st, _ = up(tgid, b, b"\x89PNG\r\n\x1a\n" + b"x" * (1024 * 1024))
    check("over 1 MiB refused", st in (400, 413), st)
    req("POST", f"/edit/{tgid}", b, {"title": "Tagged", "body": f"A picture:\n\n![A red square]({path})\n\n![remote](https://evil.example/x.png)", "action": "publish"})
    _, _, body, _ = req("GET", "/b/bob-s-great-blog/tagged")
    check("post shows the stored image, not the remote one", f'<img src="{path}" alt="A red square" loading="lazy">' in body and "evil.example" not in body)

    # Custom domains: the owner sets one, proves it with DNS, and the blog
    # is served there read-only, as a signed-out visitor.
    st, loc, _, _ = req("POST", "/dash/bob-s-great-blog/domain", b, {"action": "set", "domain": "Blog.Example.ORG."})
    check("owner sets a domain", st == 303 and loc == "/dash/bob-s-great-blog#domain", (st, loc))
    _, _, body, _ = req("GET", "/dash/bob-s-great-blog", b)
    tok = re.search(r"slopstack-verify=([0-9a-f]{24})", body)
    check("instructions: TXT record with a token", tok is not None and "_slopstack.blog.example.org" in body, body[body.find('id="domain"'):][:500])
    st, _, _, _ = req("POST", "/dash/bob-s-great-blog/domain", c, {"action": "set", "domain": "evil.example.org"})
    check("others cannot set a blog's domain", st == 403, st)
    for bad in ["localhost", "10.0.0.1", "a..b.com", "https://x.com", "x" * 300 + ".com"]:
        st, _, _, _ = req("POST", "/dash/bob-s-great-blog/domain", b, {"action": "set", "domain": bad})
        check(f"bad domain {bad[:20]!r} refused", st == 400, st)
    st, loc, _, _ = req("POST", "/dash/bob-s-great-blog/domain", b, {"action": "verify"})
    check("verify without the TXT record: not verified", st == 303 and "dns=0" in loc, (st, loc))
    check("says so", "was not found yet" in req("GET", loc.split("#")[0], b)[2])
    check("unverified: no certificate", req("GET", "/_domain?domain=blog.example.org")[0] == 404)
    check("unverified: not served", req("GET", "/", host="blog.example.org")[0] == 404)
    q = sqlite3.connect(dbpath)
    q.execute("UPDATE blog SET domain_ok = 1 WHERE domain = 'blog.example.org'")
    q.commit()
    q.close()
    check("verified: certificate allowed", req("GET", "/_domain?domain=blog.example.org")[0] == 200)
    st, _, body, _ = req("GET", "/", host="blog.example.org")
    check("custom domain: / is the blog", st == 200 and "Bob&#39;s Great Blog!" in body and "Log out" not in body, st)
    st, _, body, _ = req("GET", "/hello-world", host="blog.example.org")
    check("custom domain: /<post>", st == 200 and "Words here." in body, st)
    st, _, body, _ = req("GET", "/b/bob-s-great-blog/hello-world", host="blog.example.org:443")
    check("custom domain: /b/<blog>/<post> links work (port ignored)", st == 200 and "Words here." in body, st)
    st, _, xml, head = req("GET", "/feed.xml", host="blog.example.org")
    check("custom domain: its feed", st == 200 and "application/rss+xml" in head and "Hello, World" in xml, st)
    st, loc, _, _ = req("GET", "/login", host="blog.example.org")
    check("custom domain: logging in happens on the main site", st == 303 and loc.startswith("http") and loc.endswith("/login"), (st, loc))
    st, loc, _, _ = req("GET", "/b/mallory-writes/hello-world", host="blog.example.org")
    check("custom domain: other blogs are on the main site", st == 303 and "/b/mallory-writes/hello-world" in loc, (st, loc))
    st, _, _, _ = req("POST", f"/like/{ppid}", b, {"on": "1"}, host="blog.example.org")
    check("custom domain: no writes, even with a session", st == 403, st)
    st, _, _, _ = req("GET", "/draft-tagged", b, host="blog.example.org")
    check("custom domain: drafts never shown, even with a session", st == 404, st)
    check("unknown host: 404", req("GET", "/", host="nobody.example.net")[0] == 404)
    st, _, _, _ = req("POST", "/dash/bob-s-great-blog/domain", b, {"action": "remove"})
    check("remove", st == 303 and req("GET", "/_domain?domain=blog.example.org")[0] == 404 and req("GET", "/", host="blog.example.org")[0] == 404)

    # Security headers everywhere.
    _, _, _, head = req("GET", "/b/alice/first")
    check("CSP present", "Content-Security-Policy: default-src 'none'" in head)
    check("nosniff present", "X-Content-Type-Options: nosniff" in head)


main()
