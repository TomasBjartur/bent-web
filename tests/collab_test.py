#!/usr/bin/env python3
"""Collaborative editing in two real browsers (headless Chrome), as two
users: concurrent edits, same-position typing, offline editing, reload,
render and publish, and an outsider trying to read or write.

usage: tests/collab_test.py   (needs tools/setup_chrome.sh once)
"""
import hashlib, os, re, secrets, socket, sqlite3, subprocess, sys, tempfile, time, urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cdp import start_chrome, page_ws, wait_port

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORT = 8096
BASE = f"http://localhost:{PORT}"
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


def user(db, email):
    uid = db.execute("INSERT INTO user(email, name, created_ms) VALUES (?, ?, 1)", (email, email.split("@")[0])).lastrowid
    raw = secrets.token_bytes(32)
    now = int(time.time() * 1000)
    db.execute("INSERT INTO session VALUES (?, ?, ?, ?)", (hashlib.sha256(raw).digest(), uid, now, now + 3600_000))
    db.commit()
    return uid, raw.hex()


class Editor:
    def __init__(self, port, profile, sid):
        self.proc = start_chrome(port, profile)
        self.ws = page_ws(port)
        self.ws.call("Page.enable")
        self.ws.call("Runtime.enable")
        self.ws.call("Network.enable")
        self.ws.call("Network.setCookie", {"name": "sid", "value": sid, "url": BASE, "httpOnly": True, "secure": True, "sameSite": "Strict"})

    def js(self, expr):
        r = self.ws.call("Runtime.evaluate", {"expression": expr, "awaitPromise": True, "returnByValue": True})
        return r.get("result", {}).get("value")

    def open(self, url):
        self.ws.call("Page.navigate", {"url": url})
        for _ in range(50):
            time.sleep(0.1)
            if self.js("document.readyState") == "complete" and self.js("!!document.getElementById('editor')"):
                break
        time.sleep(0.5)

    def text(self):
        return self.js("document.getElementById('editor').value")

    def status(self):
        return self.js("(document.getElementById('sync-status') || {}).textContent")

    # Type as a user does: change the value at a position, fire input.
    def type_at(self, pos, s):
        self.js(f"(() => {{ const t = document.getElementById('editor'); const a = Array.from(t.value);"
                f" a.splice({pos}, 0, ...Array.from({s!r})); t.value = a.join('');"
                f" t.dispatchEvent(new Event('input', {{bubbles: true}})); }})()")

    def type_end(self, s):
        self.js(f"(() => {{ const t = document.getElementById('editor'); t.value += {s!r};"
                f" t.dispatchEvent(new Event('input', {{bubbles: true}})); }})()")

    def offline(self, on):
        self.ws.call("Network.emulateNetworkConditions", {"offline": on, "latency": 0, "downloadThroughput": -1, "uploadThroughput": -1})
        if not on:
            self.js("window.dispatchEvent(new Event('online'))")

    def close(self):
        self.proc.terminate()
        self.proc.wait()


def settle(eds, want=None, secs=12):
    for _ in range(secs * 5):
        time.sleep(0.2)
        texts = [e.text() for e in eds]
        if len(set(texts)) == 1 and (want is None or texts[0] == want) and all(e.status() == "Saved" for e in eds):
            return texts[0]
    return [e.text() for e in eds]


def main():
    tmp = tempfile.mkdtemp()
    dbpath = os.path.join(tmp, "blog.db")
    env = dict(os.environ, PORT=str(PORT), BLOG_DB=dbpath, BLOG_ORIGIN=BASE, BLOG_RP_ID="localhost")
    srv = subprocess.Popen([os.path.join(ROOT, "build/server")], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    eds = []
    try:
        wait_port(PORT)
        db = sqlite3.connect(dbpath)
        a_id, a = user(db, "alice@example.com")
        b_id, b = user(db, "bob@example.com")
        c_id, c = user(db, "carol@example.com")
        http("POST", "/blogs", a, {"slug": "team", "title": "Team"})
        http("POST", "/dash/team/authors", a, {"email": "bob@example.com"})
        _, loc, _ = http("POST", "/dash/team/posts", a, {"slug": "doc", "title": "Doc"})
        pid = loc.rsplit("/", 1)[1]
        edit = f"{BASE}/edit/{pid}"

        ea = Editor(9341, f"{tmp}/ca", a)
        eb = Editor(9342, f"{tmp}/cb", b)
        eds = [ea, eb]
        ea.open(edit)
        eb.open(edit)
        check("both editors load", ea.text() == "" and eb.text() == "", (ea.text(), eb.text()))

        ea.type_end("Hello")
        got = settle(eds, "Hello")
        check("A types, B sees it", got == "Hello", got)

        ea.type_at(0, ">> ")
        eb.type_end(" world")
        got = settle(eds)
        check("concurrent edits at both ends converge", got == ">> Hello world", got)

        ea.type_at(3, "AAA")
        eb.type_at(3, "BBB")
        got = settle(eds)
        check("same position: converge, runs not interleaved",
              got in (">> AAABBBHello world", ">> BBBAAAHello world"), got)

        eb.offline(True)
        time.sleep(0.3)
        eb.type_end(" (offline)")
        ea.type_at(0, "# ")
        time.sleep(2.5)
        check("offline editor keeps its edit locally", "(offline)" in eb.text() and not eb.text().startswith("# "), eb.text())
        check("offline editor says so", "Offline" in (eb.status() or ""), eb.status())
        eb.offline(False)
        got = settle(eds)
        check("back online: both converge with both edits",
              isinstance(got, str) and got.startswith("# >> ") and got.endswith(" world (offline)"), got)

        eb.open(edit)
        check("reload shows the same text", eb.text() == ea.text(), (eb.text(), ea.text()))

        # Save renders from the server's operations; publish; public page.
        ea.js("document.querySelector('form.editor').requestSubmit()")
        time.sleep(1.5)
        http("POST", f"/edit/{pid}/publish", a)
        st, _, body = http("GET", "/b/team/doc")
        check("rendered from operations and published", st == 200 and "(offline)" in body and "world" in body, (st, body[:300]))
        check("markdown heading rendered", "<h2>" in body, body[:300])

        # A post written without the editor (no operations yet) keeps its
        # lines, tabs and a leading blank line when the editor opens it and
        # seeds operations from it, and when it is saved again.
        text = "\nFirst paragraph.\n\n## Heading\n\n\tindented & <tagged>\nlast"
        _, loc, _ = http("POST", "/dash/team/posts", a, {"slug": "old", "title": "Old"})
        opid = loc.rsplit("/", 1)[1]
        http("POST", f"/edit/{opid}", a, {"title": "Old", "body": text})
        ea.open(f"{BASE}/edit/{opid}")
        check("editor shows a form-written post exactly", ea.text() == text, repr(ea.text()))
        settle([ea])
        ea.js("document.querySelector('form.editor').requestSubmit()")
        time.sleep(1.5)
        md = sqlite3.connect(dbpath).execute("SELECT body_md FROM post_body WHERE post_id = ?", (opid,)).fetchone()[0]
        check("saved again from the editor: unchanged", md == text, repr(md))

        # The post page, live: B watches the published post; A's comment
        # appears without a reload; B's like does not reload either.
        eb.ws.call("Page.navigate", {"url": f"{BASE}/b/team/doc"})
        time.sleep(1.5)
        eb.js("window.__marker = 42")
        http("POST", f"/comment/{pid}", a, {"body": "Hello from A, live"})
        seen = False
        for _ in range(40):
            time.sleep(0.2)
            if "Hello from A, live" in (eb.js("document.getElementById('thread').innerText") or ""):
                seen = True
                break
        check("comment appears live, without a reload", seen and eb.js("window.__marker") == 42)
        eb.js("document.querySelector('#social button').click()")
        time.sleep(1.0)
        check("like without a reload", eb.js("window.__marker") == 42 and "♥ 1" in (eb.js("document.getElementById('social').innerText") or ""),
              eb.js("document.getElementById('social').outerHTML"))
        eb.js("const t = document.querySelector('#comments textarea'); t.value = 'Typed by B'; document.querySelector('#comments form.cform button').click()")
        seen = False
        for _ in range(40):
            time.sleep(0.2)
            if "Typed by B" in (eb.js("document.getElementById('thread').innerText") or ""):
                seen = True
                break
        check("own comment sent without a reload and shown", seen and eb.js("window.__marker") == 42 and eb.js("document.querySelector('#comments textarea').value") == "")

        # More than 20 threads: "More comments" loads the rest in place, and
        # a comment arriving live afterwards still lands after them.
        q = sqlite3.connect(dbpath)
        au = q.execute("SELECT id FROM user ORDER BY id LIMIT 1").fetchone()[0]
        for i in range(25):
            q.execute("INSERT INTO comment(post_id, parent_id, author_id, body_md, body_html, created_ms) VALUES (?, NULL, ?, ?, ?, 1)",
                      (pid, au, f"bulk {i}", f"<p>bulk {i}</p>"))
        q.commit()
        q.close()
        eb.ws.call("Page.navigate", {"url": f"{BASE}/b/team/doc"})
        time.sleep(1.5)
        eb.js("window.__marker = 43")
        count = "document.querySelectorAll('#thread .comment[data-parent=\"0\"]').length"
        before = eb.js(count)
        eb.js("document.querySelector('#more-comments a').click()")
        after = before
        for _ in range(30):
            time.sleep(0.2)
            after = eb.js(count)
            if after and after > before:
                break
        check("more comments load in place", before == 20 and after == 27 and eb.js("window.__marker") == 43
              and eb.js("document.getElementById('more-comments')") is None, (before, after))
        http("POST", f"/comment/{pid}", a, {"body": "Live after paging"})
        seen = False
        for _ in range(40):
            time.sleep(0.2)
            if (eb.js("document.getElementById('thread').innerText") or "").rstrip().endswith("Live after paging") or \
               "Live after paging" in (eb.js("[...document.querySelectorAll('#thread > .comment')].pop().innerText") or ""):
                seen = True
                break
        check("a live comment after paging comes last", seen and eb.js("window.__marker") == 43)

        # Search as you type, and "Older posts" in place (Datastar), in Chrome.
        for i in range(32):
            _, loc2, _ = http("POST", "/dash/team/posts", a, {"title": f"Batch {i:02d} zebra"})
            http("POST", loc2, a, {"title": f"Batch {i:02d} zebra", "body": "zebra words", "action": "publish"})
        eb.ws.call("Page.navigate", {"url": f"{BASE}/search"})
        time.sleep(1.2)
        eb.js("window.__marker = 7")
        eb.js("const q = document.querySelector('input[name=q]'); q.focus(); q.value = 'zebr'; q.dispatchEvent(new Event('input', {bubbles: true}))")
        found = 0
        for _ in range(30):
            time.sleep(0.2)
            found = eb.js("document.querySelectorAll('#results .feed li').length") or 0
            if found:
                break
        check("search results appear as you type, no reload", found > 0 and eb.js("window.__marker") == 7 and "q=zebr" in (eb.js("location.search") or ""),
              (found, eb.js("location.href")))
        eb.ws.call("Page.navigate", {"url": f"{BASE}/b/team"})
        time.sleep(1.2)
        eb.js("window.__marker = 8")
        before = eb.js("document.querySelectorAll('#feed > li').length")
        eb.js("document.querySelector('#pager a[href*=\"page=2\"]').click()")
        after = before
        for _ in range(30):
            time.sleep(0.2)
            after = eb.js("document.querySelectorAll('#feed > li').length")
            if after and after > before:
                break
        check("older posts load in place", before == 30 and after > 30 and eb.js("window.__marker") == 8, (before, after))
        eb.ws.call("Page.navigate", {"url": f"{BASE}/signup"})
        time.sleep(1.2)
        eb.js("const h = document.querySelector('input[name=handle]'); h.value = 'zed_new'; h.dispatchEvent(new Event('input', {bubbles: true}))")
        note = ""
        for _ in range(30):
            time.sleep(0.2)
            note = eb.js("document.getElementById('handle-note').innerText") or ""
            if note:
                break
        check("username check as you type", "zed_new is free" in note, note)

        # An outsider can neither read nor write the document.
        st, _, _ = http("GET", f"/edit/{pid}", c)
        check("outsider: editor 404", st == 404, st)
        st, _, _ = http("POST", f"/edit/{pid}/sync", c, {"since": "0", "ops": ""})
        check("outsider: sync 403", st == 403, st)
        st, _, _ = http("POST", f"/edit/{pid}/sync", None, {"since": "0", "ops": ""})
        check("anonymous: sync 403", st == 403, st)
        st, _, _ = http("POST", f"/edit/{pid}/sync", a, {"since": "0", "ops": "1.2.0.0.0.1.7;"})
        check("member: control character rejected", st == 400, st)
        st, _, reply = http("POST", f"/edit/{pid}/sync", a, {"since": "0", "ops": ""})
        check("member: full sync returns everything", st == 200 and reply.count(";") >= 20, (st, reply[:80]))
    finally:
        for e in eds:
            e.close()
        srv.terminate()
        srv.wait()
    print(f"\n{fails} failure(s)")
    sys.exit(1 if fails else 0)


main()
