#!/usr/bin/env python3
"""The editor's modes in real Chrome (keys sent as a keyboard does, through
the DevTools protocol):

- Vim: off by default; the first time, a dialog; "No" leaves it off, "Yes"
  turns it on (and it stays on after a reload, with no dialog); commands
  edit the text and the edit syncs like typing; :w saves.
- Visual (WYSIWYG): the post rendered by the proved renderer; typing and
  the toolbar change the Markdown; the edit syncs; switching back shows
  the Markdown.
- Round trip: random Markdown shown in Visual mode, every block turned back
  into Markdown and shown again, renders to the same HTML.

usage: tests/editor_test.py   (needs ./build.sh and tools/setup_chrome.sh)
"""
import hashlib, os, random, re, secrets, socket, sqlite3, subprocess, sys, tempfile, time, urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cdp import start_chrome, page_ws, wait_port

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORT = 8189
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


KEYS = {"Escape": 27, "Enter": 13, "Backspace": 8, "Tab": 9}


class Browser:
    def __init__(self, port, profile, sid):
        self.proc = start_chrome(port, profile)
        self.ws = page_ws(port)
        for d in ("Page", "Runtime", "Network"):
            self.ws.call(d + ".enable")
        self.ws.call("Network.setCookie", {"name": "sid", "value": sid, "url": BASE, "httpOnly": True, "sameSite": "Strict"})

    def js(self, expr):
        r = self.ws.call("Runtime.evaluate", {"expression": expr, "awaitPromise": True, "returnByValue": True})
        return r.get("result", {}).get("value")

    def open(self, url):
        self.ws.call("Page.navigate", {"url": url})
        for _ in range(60):
            time.sleep(0.1)
            if self.js("document.readyState") == "complete" and self.js("!!document.querySelector('.edit-tools')"):
                break
        time.sleep(0.4)

    def key(self, k, ctrl=False):
        """One key as a keyboard sends it (a named key, or a character)."""
        mods = 2 if ctrl else 0
        if k in KEYS:
            base = {"key": k, "code": k, "windowsVirtualKeyCode": KEYS[k], "modifiers": mods}
            text = {"Enter": "\r"}.get(k)
            self.ws.call("Input.dispatchKeyEvent", dict(base, type="keyDown" if text else "rawKeyDown", **({"text": text} if text else {})))
            self.ws.call("Input.dispatchKeyEvent", dict(base, type="keyUp"))
        else:
            code = ord(k.upper()) if k.isalpha() else 0
            ev = {"key": k, "modifiers": mods, "windowsVirtualKeyCode": code}
            if ctrl:
                self.ws.call("Input.dispatchKeyEvent", dict(ev, type="rawKeyDown"))
            else:
                self.ws.call("Input.dispatchKeyEvent", dict(ev, type="keyDown", text=k))
            self.ws.call("Input.dispatchKeyEvent", dict(ev, type="keyUp"))

    def keys(self, s):
        for tok in re.findall(r"<[A-Za-z-]+>|.", s):
            if tok.startswith("<") and len(tok) > 1:
                name = tok[1:-1]
                if name.startswith("C-"):
                    self.key(name[2:], ctrl=True)
                else:
                    self.key({"Esc": "Escape", "CR": "Enter", "BS": "Backspace"}.get(name, name))
            else:
                self.key(tok)
        time.sleep(0.15)

    def text(self):
        return self.js("document.getElementById('editor').value")

    def wait_saved(self, secs=10):
        for _ in range(secs * 5):
            time.sleep(0.2)
            if self.js("document.getElementById('sync-status').textContent").startswith("Saved"):
                return True
        return False

    def close(self):
        self.proc.terminate()
        self.proc.wait()


# Random Markdown in the renderer's subset.
rng = random.Random(int(os.environ.get("SEED", "5")))
WORDS = "river quiet boats walls books music weather bread craft writing light water morning letter lamp".split()


def words(n):
    return " ".join(rng.choice(WORDS) for _ in range(n))


def inline():
    parts = []
    for _ in range(rng.randint(1, 5)):
        k = rng.randint(0, 9)
        w = words(rng.randint(1, 3))
        parts.append([w, "**" + w + "**", "*" + w + "*", "`" + w + "`", "[" + w + "](https://example.com/" + w.split()[0] + ")",
                      w + " \\*star\\*", w, w, "_" + w + "_", w + " 3.5"][k])
    return " ".join(parts)


def block():
    k = rng.randint(0, 7)
    if k == 0:
        return "## " + words(rng.randint(1, 4))
    if k == 1:
        return "### " + words(rng.randint(1, 4))
    if k == 2:
        return "\n".join("- " + inline() for _ in range(rng.randint(1, 4)))
    if k == 3:
        return "\n".join(f"{i + 1}. " + inline() for i in range(rng.randint(1, 4)))
    if k == 4:
        return "> " + inline()
    if k == 5:
        return "```\n" + words(3) + "\n" + words(2) + " <x> & y\n```"
    return inline() + ("\n" + inline() if rng.random() < 0.3 else "")


def doc():
    return "\n\n".join(block() for _ in range(rng.randint(1, 7))) + ("\n" if rng.random() < 0.5 else "")


def main():
    tmp = tempfile.mkdtemp()
    dbpath = os.path.join(tmp, "blog.db")
    env = dict(os.environ, PORT=str(PORT), BLOG_DB=dbpath, BLOG_ORIGIN=BASE, BLOG_RP_ID="localhost", BLOG_WORKERS="1")
    srv = subprocess.Popen([os.path.join(ROOT, "build/server")], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    br = None
    try:
        wait_port(PORT)
        db = sqlite3.connect(dbpath)
        _, a = user(db, "ed@example.com")
        http("POST", "/blogs", a, {"slug": "ed", "title": "Ed"})
        _, loc, _ = http("POST", "/dash/ed/posts", a, {"slug": "p", "title": "P"})
        pid = loc.rsplit("/", 1)[1]
        edit = f"{BASE}/edit/{pid}"
        body = lambda: db.execute("SELECT group_concat(1) FROM op WHERE post_id = ?", (pid,)).fetchone()
        br = Browser(9361, f"{tmp}/c", a)
        br.open(edit)

        # VIM
        check("vim is off by default", br.js("document.querySelector('.vim-toggle').getAttribute('aria-pressed')") == "false")
        br.js("document.getElementById('editor').focus()")
        br.keys("hi")
        check("typing is normal typing when vim is off", br.text() == "hi", br.text())
        br.js("document.querySelector('.vim-toggle').click()")
        time.sleep(0.3)
        check("first time: a dialog", br.js("document.querySelector('dialog.modal').open") is True)
        check("the dialog warns: only if you know vim", "Only click Yes if you already know Vim" in (br.js("document.querySelector('dialog.modal').textContent") or ""))
        br.js("document.querySelector('dialog.modal button[value=no]').click()")
        time.sleep(0.3)
        check("No: vim stays off", br.js("document.querySelector('.vim-toggle').getAttribute('aria-pressed')") == "false"
              and br.js("document.querySelector('dialog.modal').open") is False)
        br.js("document.querySelector('.vim-toggle').click()")
        time.sleep(0.3)
        br.js("document.querySelector('dialog.modal button[value=yes]').click()")
        time.sleep(0.3)
        check("Yes: vim on, normal mode shown", br.js("document.querySelector('.vim-toggle').getAttribute('aria-pressed')") == "true"
              and "NORMAL" in (br.js("document.querySelector('.vim-line').textContent") or ""))
        br.keys("ddiHello world<Esc>0x")
        check("vim commands edit the text", br.text() == "ello world", repr(br.text()))
        br.keys("A!<CR>second line<Esc>kdd")
        check("insert, Enter, dd", br.text() == "second line", repr(br.text()))
        br.keys("u")
        check("undo", br.text() == "ello world!\nsecond line", repr(br.text()))
        br.keys("u")
        check("undo: an insert is one change", br.text() == "ello world", repr(br.text()))
        br.keys("<C-r>")
        check("redo", br.text() == "ello world!\nsecond line", repr(br.text()))
        check("vim edits sync like typing", br.wait_saved(), br.js("document.getElementById('sync-status').textContent"))
        br.js("window.__marker = 5")
        br.keys(":w<CR>")
        time.sleep(1.5)
        check(":w saves without leaving the page", br.js("window.__marker") == 5 and br.js("document.getElementById('sync-status').textContent") == "Draft saved",
              br.js("document.getElementById('sync-status').textContent"))
        check(":w saves (the post is rendered)", "second line" in db.execute("SELECT body_html FROM post_body WHERE post_id = ?", (pid,)).fetchone()[0])
        br.open(edit)
        check("vim stays on after a reload, no dialog", br.js("document.querySelector('.vim-toggle').getAttribute('aria-pressed')") == "true"
              and br.js("document.querySelector('dialog.modal').open") is False)
        br.js("document.querySelector('.vim-toggle').click()")
        time.sleep(0.2)
        br.js("document.getElementById('editor').focus()")
        br.keys("x")
        check("vim off: x is typed again", br.text().count("x") == 1, repr(br.text()))

        # VISUAL
        br.js("(() => { const t = document.getElementById('editor'); t.value = '## Title\\n\\nFirst **bold** para.\\n\\n- one\\n- two\\n'; t.dispatchEvent(new Event('input', {bubbles: true})); })()")
        br.wait_saved()
        br.js("document.querySelector('.edit-tools .seg:nth-child(2)').click()")
        time.sleep(0.4)
        html = br.js("document.querySelector('.wys').innerHTML") or ""
        check("visual mode shows the rendered post", "<h2>Title</h2>" in html and "<strong>bold</strong>" in html and "<li>one</li>" in html, html[:200])
        # Type at the end of the paragraph.
        br.js("(() => { const p = document.querySelector('.wys p'); const r = document.createRange(); r.selectNodeContents(p); r.collapse(false);"
              " const s = getSelection(); s.removeAllRanges(); s.addRange(r); })()")
        for c in " More":
            br.key(c)
        time.sleep(0.3)
        check("typing in visual mode edits the Markdown", br.text() == "## Title\n\nFirst **bold** para. More\n\n- one\n- two\n", repr(br.text()))
        # Select "More" and make it italic with the toolbar.
        br.js("(() => { const p = document.querySelector('.wys p'); const t = p.lastChild; const r = document.createRange();"
              " r.setStart(t, t.length - 4); r.setEnd(t, t.length); const s = getSelection(); s.removeAllRanges(); s.addRange(r); })()")
        br.js("document.querySelector('.fmt[data-cmd=italic]').click()")
        time.sleep(0.3)
        check("toolbar: italic", "para. *More*" in br.text(), repr(br.text()))
        br.js("(() => { const h = document.querySelector('.wys h2'); const r = document.createRange(); r.selectNodeContents(h); r.collapse(false);"
              " const s = getSelection(); s.removeAllRanges(); s.addRange(r); })()")
        br.js("document.querySelector('.fmt[data-cmd=h3]').click()")
        time.sleep(0.3)
        check("toolbar: heading level", br.text().startswith("### Title\n\n"), repr(br.text()))
        check("only the edited blocks change", br.text().endswith("\n\n- one\n- two\n"), repr(br.text()))
        check("visual edits sync", br.wait_saved(), br.js("document.getElementById('sync-status').textContent"))
        # Markdown shortcuts: a new paragraph at the end, "## " makes it a heading.
        br.js("(() => { const l = document.querySelector('.wys').lastElementChild.lastElementChild; const r = document.createRange();"
              " r.selectNodeContents(l); r.collapse(false); const s = getSelection(); s.removeAllRanges(); s.addRange(r); })()")
        br.key("Enter")
        br.key("Enter")  # an empty list item: Enter leaves the list
        for c in "## Next":
            br.key(c)
        time.sleep(0.3)
        check("shortcut: ## makes a heading", br.js("!!document.querySelector('.wys h2')") and br.text().rstrip().endswith("## Next"), repr(br.text()))
        br.key("Enter")
        for c in "- item":
            br.key(c)
        time.sleep(0.3)
        check("shortcut: - makes a list", br.text().rstrip().endswith("## Next\n\n- item"), repr(br.text()))
        br.js("document.querySelector('.edit-tools .seg:nth-child(1)').click()")
        time.sleep(0.3)
        check("back to Markdown", br.js("document.getElementById('editor').hidden") is False and br.js("document.querySelector('.wys').hidden") is True)

        # ROUND TRIP: render -> Markdown -> render gives the same HTML.
        bad = []
        for i in range(int(os.environ.get("ROUNDS", "40"))):
            md = doc()
            br.js(f"(() => {{ const t = document.getElementById('editor'); t.value = {md!r}; t.dispatchEvent(new Event('input', {{bubbles: true}})); }})()")
            br.js("document.querySelector('.edit-tools .seg:nth-child(2)').click()")
            h1 = br.js("document.querySelector('.wys').innerHTML")
            # Touch every block, so each is turned back into Markdown.
            br.js("(() => { const v = document.querySelector('.wys'); for (const b of v.children) { const x = document.createTextNode(''); b.appendChild(x); x.remove(); }"
                  " v.dispatchEvent(new Event('input')); })()")
            md2 = br.text()
            br.js("document.querySelector('.edit-tools .seg:nth-child(1)').click()")
            br.js("document.querySelector('.edit-tools .seg:nth-child(2)').click()")
            h2 = br.js("document.querySelector('.wys').innerHTML")
            br.js("document.querySelector('.edit-tools .seg:nth-child(1)').click()")
            if h1 != h2:
                bad.append((md, md2, h1, h2))
        check("round trip: Markdown -> Visual -> Markdown renders the same", not bad, bad[:1])
    finally:
        if br:
            br.close()
        srv.terminate()
    print(f"\n{fails} failure(s)")
    sys.exit(1 if fails else 0)


main()
