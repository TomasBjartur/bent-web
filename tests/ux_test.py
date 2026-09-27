#!/usr/bin/env python3
"""How the site feels, in real Chrome:

- Every page loads with no console errors and no CSP violations.
- No layout shift (CLS) on any page, desktop or phone.
- Links are fetched ahead on hover (speculation rules): the next page is
  served from the prefetch.
- Confirmations are the site's dialog: Cancel keeps things as they were;
  OK goes ahead (an ordinary form, and a Datastar form).
- An ordinary form cannot be sent twice.

usage: tests/ux_test.py   (needs ./build.sh and tools/setup_chrome.sh)
"""
import hashlib, os, re, secrets, socket, sqlite3, subprocess, sys, tempfile, time, urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cdp import start_chrome, page_ws, wait_port

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORT = 8188
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


def user(db, email, name, handle):
    uid = db.execute("INSERT INTO user(email, name, handle, created_ms) VALUES (?, ?, ?, 1)", (email, name, handle)).lastrowid
    raw = secrets.token_bytes(32)
    now = int(time.time() * 1000)
    db.execute("INSERT INTO session VALUES (?, ?, ?, ?)", (hashlib.sha256(raw).digest(), uid, now, now + 3600_000))
    db.commit()
    return uid, raw.hex()


# Collected by the page: errors, CSP violations, layout shifts.
WATCH = """(() => { if (window.__ux) return; window.__ux = {errors: [], csp: [], cls: 0};
  addEventListener('error', (e) => __ux.errors.push(String(e.message)));
  addEventListener('unhandledrejection', (e) => __ux.errors.push(String(e.reason)));
  document.addEventListener('securitypolicyviolation', (e) => __ux.csp.push(e.violatedDirective + ' ' + e.blockedURI));
  new PerformanceObserver((l) => { for (const x of l.getEntries()) if (!x.hadRecentInput) __ux.cls += x.value; }).observe({type: 'layout-shift', buffered: true});
})()"""


class Browser:
    def __init__(self, port, profile):
        self.proc = start_chrome(port, profile)
        self.ws = page_ws(port)
        for d in ("Page", "Runtime", "Network", "Log"):
            self.ws.call(d + ".enable")
        # Before any page script: watch from the start.
        self.ws.call("Page.addScriptToEvaluateOnNewDocument", {"source": WATCH})
        self.logs = []

    def js(self, expr):
        r = self.ws.call("Runtime.evaluate", {"expression": expr, "awaitPromise": True, "returnByValue": True})
        return r.get("result", {}).get("value")

    def cookie(self, sid):
        self.ws.call("Network.clearBrowserCookies")
        if sid:
            self.ws.call("Network.setCookie", {"name": "sid", "value": sid, "url": BASE, "httpOnly": True, "sameSite": "Strict"})

    def open(self, url, settle=1.0):
        self.ws.call("Page.navigate", {"url": url})
        for _ in range(60):
            time.sleep(0.1)
            if self.js("document.readyState") == "complete":
                break
        time.sleep(settle)

    def size(self, w, h):
        self.ws.call("Emulation.setDeviceMetricsOverride", {"width": w, "height": h, "deviceScaleFactor": 1, "mobile": w < 600})

    def hover(self, selector):
        box = self.js(f"(() => {{ const r = document.querySelector({selector!r}).getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; }})()")
        self.ws.call("Input.dispatchMouseEvent", {"type": "mouseMoved", "x": box[0], "y": box[1]})
        return box

    def click_at(self, box):
        for t in ("mousePressed", "mouseReleased"):
            self.ws.call("Input.dispatchMouseEvent", {"type": t, "x": box[0], "y": box[1], "button": "left", "clickCount": 1})

    def close(self):
        self.proc.terminate()
        self.proc.wait()


def main():
    tmp = tempfile.mkdtemp()
    dbpath = os.path.join(tmp, "blog.db")
    env = dict(os.environ, PORT=str(PORT), BLOG_DB=dbpath, BLOG_ORIGIN=BASE, BLOG_RP_ID="localhost", BLOG_WORKERS="1")
    srv = subprocess.Popen([os.path.join(ROOT, "build/server")], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    br = None
    try:
        wait_port(PORT)
        db = sqlite3.connect(dbpath)
        a_id, a = user(db, "ada@example.com", "Ada Lovelace", "ada")
        b_id, b = user(db, "ben@example.com", "Ben Okri", "ben")
        http("POST", "/blogs", a, {"slug": "river", "title": "Notes from the River"})
        http("POST", "/dash/river/authors", a, {"email": "ben@example.com"})
        pids = []
        for i in range(3):
            _, loc, _ = http("POST", "/dash/river/posts", a, {"slug": f"p{i}", "title": f"Post {i}"})
            pid = loc.rsplit("/", 1)[1]
            pids.append(pid)
            http("POST", f"/edit/{pid}", a, {"title": f"Post number {i}", "body": "Some **words** here.\n\n## A heading\n\nMore words.", "tags": "river", "action": "publish"})
        http("POST", f"/comment/{pids[0]}", b, {"body": "A comment"})
        pages = [("/", None), ("/", a), ("/b/river", None), ("/b/river/p0", None), ("/b/river/p0", a), ("/t/river", None), (f"/u/{a_id}", None),
                 ("/search?q=words", None), ("/dash", a), ("/dash/river", a), (f"/edit/{pids[1]}", a), ("/signup", None), ("/login", None), ("/b/nope", None)]
        br = Browser(9381, f"{tmp}/c")
        for w, h in ((1280, 900), (390, 844)):
            br.size(w, h)
            for path, sid in pages:
                br.cookie(sid)
                br.open(BASE + path)
                ux = br.js("window.__ux") or {}
                tag = f"{path} {'signed in' if sid else 'signed out'} {w}px"
                check(f"no errors: {tag}", not ux.get("errors") and not ux.get("csp"), ux)
                check(f"no layout shift: {tag}", (ux.get("cls") or 0) < 0.01, ux.get("cls"))
        br.size(1280, 900)

        # Prefetch on hover: the next page comes from the prefetch.
        br.cookie(None)
        br.open(BASE + "/b/river")
        box = br.hover("#feed a[href='/b/river/p1']")
        time.sleep(1.2)
        br.click_at(box)
        time.sleep(1.5)
        kind = br.js("performance.getEntriesByType('navigation')[0].deliveryType")
        check("a hovered link's page comes from the prefetch", kind == "navigational-prefetch" and br.js("location.pathname") == "/b/river/p1", (kind, br.js("location.pathname")))

        # A like shows at once, before the server answers (600 ms away here),
        # and the server's answer agrees.
        br.cookie(b)
        br.open(BASE + "/b/river/p1")
        br.ws.call("Network.emulateNetworkConditions", {"offline": False, "latency": 600, "downloadThroughput": -1, "uploadThroughput": -1})
        br.js("document.querySelector('#social button').click()")
        time.sleep(0.15)
        now = br.js("[document.querySelector('#social button').classList.contains('on'), document.querySelector('#social button').textContent.trim()]")
        check("a like shows at once", now == [True, "♥ 1"], now)
        time.sleep(2.5)
        br.ws.call("Network.emulateNetworkConditions", {"offline": False, "latency": 0, "downloadThroughput": -1, "uploadThroughput": -1})
        after = br.js("[document.querySelector('#social button').classList.contains('on'), document.querySelector('#social button').textContent.trim()]")
        stored = db.execute("SELECT count(*) FROM post_like WHERE post_id = ?", (pids[1],)).fetchone()[0]
        check("and the server agrees", after == [True, "♥ 1"] and stored == 1, (after, stored))
        br.js("document.querySelector('#social button').click()")
        time.sleep(1.2)
        check("unlike", db.execute("SELECT count(*) FROM post_like WHERE post_id = ?", (pids[1],)).fetchone()[0] == 0
              and br.js("document.querySelector('#social button').textContent.trim()") == "♥ 0")

        # The site's confirmation dialog: an ordinary form (unpublish, editor).
        br.cookie(a)
        br.open(BASE + f"/edit/{pids[2]}")
        br.js("document.querySelector('form[data-confirm] button').click()")
        time.sleep(0.4)
        check("unpublish asks in the site's dialog", br.js("!!document.querySelector('dialog.modal[open]')") and "Unpublish" in (br.js("document.querySelector('dialog.modal[open]').textContent") or ""))
        br.js("document.querySelector('dialog.modal[open] button[value=no]').click()")
        time.sleep(0.8)
        check("Cancel: nothing happens", br.js("location.pathname") == f"/edit/{pids[2]}" and http("GET", "/b/river/p2")[0] == 200)
        br.js("document.querySelector('form[data-confirm] button').click()")
        time.sleep(0.3)
        br.js("document.querySelector('dialog.modal[open] button[value=yes]').click()")
        time.sleep(1.5)
        check("OK: unpublished", http("GET", "/b/river/p2")[0] == 404)

        # A Datastar form (remove a co-author).
        br.open(BASE + "/dash/river")
        br.js("document.querySelector('#people form[data-confirm] button').click()")
        time.sleep(0.4)
        check("remove asks first", "Remove Ben Okri" in (br.js("(document.querySelector('dialog.modal[open]') || {}).textContent") or ""))
        br.js("document.querySelector('dialog.modal[open] button[value=no]').click()")
        time.sleep(0.8)
        check("Cancel: still an author", "Ben Okri" in (br.js("document.getElementById('people').textContent") or ""))
        br.js("document.querySelector('#people form[data-confirm] button').click()")
        time.sleep(0.3)
        br.js("document.querySelector('dialog.modal[open] button[value=yes]').click()")
        time.sleep(1.2)
        check("OK: removed in place (no reload)", "Ben Okri" not in (br.js("document.getElementById('people').textContent") or "")
              and br.js("performance.getEntriesByType('navigation')[0].name").endswith("/dash/river"))

        # An ordinary form is sent once, however often it is clicked.
        br.open(BASE + "/dash")
        n0 = db.execute("SELECT count(*) FROM blog").fetchone()[0]
        br.js("(() => { const d = document.querySelector('details.new-blog, details'); if (d) d.open = true; })()")
        br.js("(() => { const f = document.querySelector('form[action=\"/blogs\"]'); f.querySelector('input[name=title]').value = 'Twice?';"
              " const b = f.querySelector('button'); b.click(); b.click(); f.requestSubmit(b); })()")
        time.sleep(1.5)
        n1 = db.execute("SELECT count(*) FROM blog").fetchone()[0]
        check("a form clicked three times is sent once", n1 == n0 + 1, (n0, n1))
    finally:
        if br:
            br.close()
        srv.terminate()
    print(f"\n{fails} failure(s)")
    sys.exit(1 if fails else 0)


main()
