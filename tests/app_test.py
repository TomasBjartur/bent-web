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


def req(method, path, token=None, form=None, site="same-origin", extra=b""):
    body = urllib.parse.urlencode(form).encode() if form is not None else b""
    head = f"{method} {path} HTTP/1.1\r\nHost: localhost\r\n"
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


def main():
    tmp = tempfile.mkdtemp()
    dbpath = os.path.join(tmp, "blog.db")
    env = dict(os.environ, PORT=str(PORT), BLOG_DB=dbpath)
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

    # Security headers everywhere.
    _, _, _, head = req("GET", "/b/alice/first")
    check("CSP present", "Content-Security-Policy: default-src 'none'" in head)
    check("nosniff present", "X-Content-Type-Options: nosniff" in head)


main()
