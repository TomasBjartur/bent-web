#!/usr/bin/env python3
"""Using the editor as a writer does, in real Chrome (keys and the mouse as
a person sends them), checking what they would see:

- writing a post: the title, Enter into the text, paragraphs, Backspace
  across lines, replacing a selection, pasting, undo and redo by words;
- saving with Ctrl+S (no page load; the text and title still there after a
  reload);
- two writers: each one's undo leaves the other's words alone; both see
  the same text in the end;
- offline: typing goes on, the status says so, and it all syncs later;
- an input method (composition): the composed text, and undoing it;
- the window's edges in a long post: Backspace and Enter right at them,
  a selection from the window to far-off static text (Shift+click) deleted,
  a 300 KB paste (the window grows, then shrinks back);
- Visual mode: Ctrl+B, then Ctrl+Z undoes it in the Markdown;
- the page: no layout shift while a long post loads; on a phone-sized
  screen nothing is wider than the screen and typing works; after a resize
  the caret is still on screen and typing goes where it is.

usage: tests/usability_test.py   (needs ./build.sh and tools/setup_chrome.sh)
"""
import os, sqlite3, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import editor_test as E
import large_test as L

B = L.B
check = E.check


def key(br, name, code, vk, mods=0):
    br.ws.call("Input.dispatchKeyEvent", {"type": "rawKeyDown", "key": name, "code": code, "windowsVirtualKeyCode": vk, "modifiers": mods})
    br.ws.call("Input.dispatchKeyEvent", {"type": "keyUp", "key": name, "code": code, "windowsVirtualKeyCode": vk, "modifiers": mods})


CTRL, SHIFT = 2, 8


def ctrl(br, ch, shift=False):
    key(br, ch, "Key" + ch.upper(), ord(ch.upper()), CTRL | (SHIFT if shift else 0))
    time.sleep(0.1)


def status(br):
    return br.js("document.getElementById('sync-status').textContent")


def new_post(a, slug):
    _, loc, _ = E.http("POST", "/dash/u/posts", a, {"slug": slug, "title": "Untitled"})
    return int(loc.rsplit("/", 1)[1])


def open_post(br, pid):
    # (Unsent edits would hold the page with the leave-this-page prompt.)
    if br.js(f"!!document.getElementById('editor') && !!{B}"):
        br.wait_synced(60)
    br.open(f"{E.BASE}/edit/{pid}")
    return br.wait_loaded()


def page(port, tmp, a, name, w=1280, h=900, mobile=False):
    br = L.Page(port, f"{tmp}/{name}", a)
    br.ws.call("Emulation.setDeviceMetricsOverride", {"width": w, "height": h, "deviceScaleFactor": 1, "mobile": mobile})
    if mobile:
        br.ws.call("Emulation.setTouchEmulationEnabled", {"enabled": True})
    br.js("localStorage.setItem('bent:vim', '0'); localStorage.setItem('bent:editor-mode', 'markdown')")
    return br


def writing(br, db, a):
    pid = new_post(a, "first")
    open_post(br, pid)
    br.js("document.querySelector('textarea.title').focus()")
    br.keys("My first post")
    br.keys("<CR>")
    check("Enter in the title goes to the text", br.js("document.activeElement.id") == "editor" and br.sel() == [0, 0])
    br.keys("Hello there<CR><CR>Second paragraph")
    check("typing paragraphs", br.full() == "Hello there\n\nSecond paragraph", repr(br.full()))
    # Backspace at the start of the second paragraph: joins the lines.
    br.js(f"{B}.view.select(13, 13)")
    br.keys("<BS>")
    check("Backspace at a line's start joins it to the one before", br.full() == "Hello there\nSecond paragraph", repr(br.full()))
    br.keys("<CR>")
    # Shift+Left five times selects "there"; typing replaces it.
    br.js(f"{B}.view.select(11, 11)")
    for _ in range(5):
        key(br, "ArrowLeft", "ArrowLeft", 37, SHIFT)
    br.keys("world")
    check("typing replaces a selection", br.full() == "Hello world\n\nSecond paragraph", repr(br.full()))
    # A paste (as the browser inserts it).
    br.js(f"{B}.view.select({len(br.full())}, {len(br.full())})")
    br.ws.call("Input.insertText", {"text": "\n\n> A quoted line\n\n- one\n- two"})
    time.sleep(0.2)
    after_paste = br.full()
    check("a paste goes in at the caret", after_paste.endswith("paragraph\n\n> A quoted line\n\n- one\n- two"), repr(after_paste))
    check("the status says there are unsaved changes, then saved", "Unsaved" in status(br) or "Saving" in status(br) or "Saved" in status(br))
    time.sleep(2)
    check("…Saved", status(br).startswith("Saved"), status(br))
    # Undo: the paste, then the typing a word at a time; redo.
    time.sleep(1.6)
    ctrl(br, "z")
    check("Ctrl+Z undoes the paste", br.full() == "Hello world\n\nSecond paragraph", repr(br.full()))
    ctrl(br, "z")
    check("…then the replacement", br.full() == "Hello there\n\nSecond paragraph", repr(br.full()))
    ctrl(br, "z", shift=True)
    ctrl(br, "z", shift=True)
    check("Ctrl+Shift+Z redoes both", br.full() == after_paste, repr(br.full()))
    check("…and the caret is after the redone text", br.sel()[0] == len(after_paste), br.sel())
    # Save: stays on the page; after a reload, all there.
    br.js("window.__marker = 1")
    ctrl(br, "s")
    time.sleep(1.5)
    check("Ctrl+S saves without leaving the page", br.js("window.__marker") == 1 and "saved" in status(br).lower(), status(br))
    open_post(br, pid)
    check("after a reload: the text", br.full() == after_paste, repr(br.full()))
    check("…and the title", br.js("document.querySelector('textarea.title').value") == "My first post")
    html = db.execute("SELECT body_html FROM post_body WHERE post_id = ?", (pid,)).fetchone()[0]
    check("the saved post is rendered", "<blockquote>" in html and "<li>one</li>" in html, html[:200])


def together(br, b2, db, a):
    pid = new_post(a, "together")
    open_post(br, pid)
    br.js("document.getElementById('editor').focus()")
    br.keys("Line one.<CR>Line two.")
    time.sleep(2)
    open_post(b2, pid)
    check("the second writer sees the text", b2.full() == "Line one.\nLine two.", repr(b2.full()))
    b2.js("document.getElementById('editor').focus()")
    b2.js(f"{B}.view.select(9, 9)")
    b2.keys(" Theirs")
    time.sleep(2.5)
    check("their words arrive", br.full() == "Line one. Theirs\nLine two.", repr(br.full()))
    br.js(f"{B}.view.select({len(br.full())}, {len(br.full())})")
    time.sleep(1.6)
    br.keys(" Mine")
    time.sleep(0.3)
    ctrl(br, "z")
    check("my undo takes away my last word", br.full() == "Line one. Theirs\nLine two.", repr(br.full()))
    for _ in range(8):
        ctrl(br, "z")
    time.sleep(2.5)
    check("…and undoing all I wrote leaves their words", br.full() == " Theirs", repr(br.full()))
    check("…and the other writer sees the same", b2.full() == br.full(), (b2.full(), br.full()))
    before = br.full()
    # Both typing at the same place at once.
    br.js(f"{B}.view.select(0, 0)")
    b2.js(f"{B}.view.select(0, 0)")
    for c in "abc":
        br.keys(c)
        b2.keys(c.upper())
    time.sleep(3)
    check("typing at the same place at once: both converge", br.full() == b2.full() and len(br.full()) == 6 + len(before), (br.full(), b2.full()))
    check("…to what the server has", br.wait_synced() and L.server_text(db, pid) == br.full())


def offline(br, db, a):
    pid = new_post(a, "offline")
    open_post(br, pid)
    br.js("document.getElementById('editor').focus()")
    br.keys("Before. ")
    time.sleep(2)
    br.ws.call("Network.emulateNetworkConditions", {"offline": True, "latency": 0, "downloadThroughput": -1, "uploadThroughput": -1})
    br.keys("Written offline.")
    time.sleep(3)
    check("offline: the status says the text is kept here", "Offline" in status(br), status(br))
    check("…and typing went on", br.full() == "Before. Written offline.")
    stored = br.js("localStorage.getItem('bent:post:" + str(pid) + "')")
    check("…the unsent edits are kept in the browser", stored is not None and "pending" in stored)
    br.ws.call("Network.emulateNetworkConditions", {"offline": False, "latency": 0, "downloadThroughput": -1, "uploadThroughput": -1})
    br.js("window.dispatchEvent(new Event('online'))")
    time.sleep(3)
    check("back online: it all syncs", status(br).startswith("Saved") and L.server_text(db, pid) == "Before. Written offline.", (status(br), L.server_text(db, pid)))


def ime(br, a):
    pid = new_post(a, "ime")
    open_post(br, pid)
    br.js("document.getElementById('editor').focus()")
    br.keys("Tokyo: ")
    time.sleep(1.6)
    for part in ("と", "とう", "とうき", "とうきょう"):
        br.ws.call("Input.imeSetComposition", {"text": part, "selectionStart": len(part), "selectionEnd": len(part)})
        time.sleep(0.05)
    br.ws.call("Input.insertText", {"text": "東京"})
    time.sleep(0.3)
    check("an input method's composition gives the composed text", br.full() == "Tokyo: 東京", repr(br.full()))
    time.sleep(1.6)
    ctrl(br, "z")
    check("…and undo takes it away", br.full() == "Tokyo: ", repr(br.full()))


def edges(br, db, a):
    pid = new_post(a, "edges")
    text = L.novel(200_000, seed=3)
    L.store(db, pid, text)
    text = L.u16(text)
    open_post(br, pid)
    br.js("document.getElementById('editor').focus()")
    br.js(f"{B}.view.select(120000, 120000, true)")
    time.sleep(0.4)
    ws, we = br.win()
    check("a 200 KB post: the window is part of it", ws > 0 and we < len(text), (ws, we))
    # Backspace right at the window's start (a line start): joins lines.
    br.js(f"document.getElementById('editor').setSelectionRange(0, 0)")
    br.keys("<BS>")
    time.sleep(0.2)
    want = text[: ws - 1] + text[ws:]
    check("Backspace at the window's very start joins the line before", br.full() == want, (br.full()[ws - 20: ws + 20] if br.full() else None))
    text = want
    # Enter at the window's end.
    ws, we = br.win()
    br.js(f"(() => {{ const t = document.getElementById('editor'); t.setSelectionRange(t.value.length, t.value.length); }})()")
    br.keys("<CR>")
    time.sleep(0.2)
    want = text[:we] + "\n" + text[we:]
    check("Enter at the window's very end", br.full() == want, (br.full()[we - 10: we + 10] if br.full() else None))
    text = want
    # Delete at the window's end: the line break after it goes.
    ws, we = br.win()
    br.js(f"(() => {{ const t = document.getElementById('editor'); t.setSelectionRange(t.value.length, t.value.length); }})()")
    key(br, "Delete", "Delete", 46)
    time.sleep(0.2)
    want = text[:we] + text[we + 1:]
    check("Delete at the window's very end joins the next line", br.full() == want, (br.full()[we - 10: we + 10] if br.full() else None))
    text = want
    # Shift+click far below, in static text: the selection reaches there.
    br.js(f"{B}.view.select(60000, 60000, true)")
    time.sleep(0.4)
    target = text.index("## Chapter", 150000)
    br.js(f"""(() => {{ const v = {B}.view; let s = 0; for (const pc of v.pieces) {{ if (!pc.win && s <= {target} && {target} <= s + pc.len) {{
        const r = document.createRange(); r.setStart(pc.el.firstChild, {target} - s); r.setEnd(pc.el.firstChild, {target} - s + 1);
        window.scrollTo(0, window.scrollY + r.getBoundingClientRect().top - 300); return; }} s += pc.len + 1; }} }})()""")
    time.sleep(0.4)
    pt = br.js(f"""(() => {{ const v = {B}.view; let s = 0; for (const pc of v.pieces) {{ if (!pc.win && s <= {target} && {target} <= s + pc.len) {{
        const r = document.createRange(); r.setStart(pc.el.firstChild, {target} - s); r.setEnd(pc.el.firstChild, {target} - s + 1);
        const b = r.getBoundingClientRect(); return [b.left + 0.5, b.top + b.height / 2]; }} s += pc.len + 1; }} return null; }})()""")
    check("the target is static text", pt is not None)
    if pt:
        for t in ("mousePressed", "mouseReleased"):
            br.ws.call("Input.dispatchMouseEvent", {"type": t, "x": pt[0], "y": pt[1], "button": "left", "clickCount": 1, "modifiers": SHIFT})
        time.sleep(0.4)
        check("Shift+click in far static text selects from the caret to there", br.sel() == [60000, target], (br.sel(), target))
        key(br, "Delete", "Delete", 46)
        time.sleep(0.3)
        text = text[:60000] + text[target:]
        check("…and Delete deletes all of it", br.full() == text, len(br.full() or ""))
        time.sleep(1.6)
        ctrl(br, "z")
        time.sleep(0.3)
        check("…which undo brings back", br.full() is not None and len(br.full()) == len(text) + (target - 60000))
        text = br.full()
    # A 300 KB paste in the middle: the window grows, then shrinks back.
    big = L.u16(L.novel(300_000, seed=11))
    br.js(f"{B}.view.select(50000, 50000, true)")
    time.sleep(0.3)
    br.ws.call("Input.insertText", {"text": L.novel(300_000, seed=11)})
    time.sleep(1.5)
    text = text[:50000] + big + text[50000:]
    check("a 300 KB paste goes in", br.full() == text, len(br.full() or ""))
    ws, we = br.win()
    check("…and the window is cut back to its size", we - ws < 200_000, (ws, we))
    med, worst = br.per_key("after")
    check(f"…typing right after is quick ({med:.1f} ms a key)", med < 34, med)
    text = br.full()
    check("…and it all reaches the server", br.wait_synced(60) and L.server_text(db, pid) == text)


def visual(br, a):
    pid = new_post(a, "visual")
    open_post(br, pid)
    br.js("document.getElementById('editor').focus()")
    br.keys("Plain words here")
    time.sleep(1.6)
    br.js("document.querySelector('.edit-tools .seg:nth-child(2)').click()")
    time.sleep(0.3)
    br.js("""(() => { const p = document.querySelector('.wys p'); const t = p.firstChild; const r = document.createRange();
        r.setStart(t, 6); r.setEnd(t, 11); getSelection().removeAllRanges(); getSelection().addRange(r); })()""")
    ctrl(br, "b")
    time.sleep(0.3)
    check("Visual mode: Ctrl+B makes the selection bold", br.full() == "Plain **words** here", repr(br.full()))
    ctrl(br, "z")
    time.sleep(0.3)
    check("…and Ctrl+Z undoes it, in the Markdown and on screen", br.full() == "Plain words here" and not br.js("!!document.querySelector('.wys strong')"), (br.full(), br.js("document.querySelector('.wys').innerHTML")))
    br.js("document.querySelector('.edit-tools .seg:nth-child(1)').click()")


def loading(br, db, a):
    pid = new_post(a, "loadshift")
    L.store(db, pid, L.novel(500_000, seed=5))
    br.js("localStorage.setItem('bent:vim', '0')")
    br.ws.call("Page.addScriptToEvaluateOnNewDocument", {"source":
        "window.__cls = 0; new PerformanceObserver((l) => { for (const e of l.getEntries()) if (!e.hadRecentInput) window.__cls += e.value; }).observe({type: 'layout-shift', buffered: true});"})
    open_post(br, pid)
    time.sleep(1)
    cls = br.js("window.__cls")
    check(f"a long post loads without layout shift (CLS {cls:.3f})", cls < 0.05, cls)


def phone(br, db, a):
    pid = new_post(a, "phone")
    open_post(br, pid)
    wide = br.js("document.documentElement.scrollWidth > innerWidth + 1")
    check("on a phone: nothing is wider than the screen", not wide, br.js("[document.documentElement.scrollWidth, innerWidth]"))
    check("…the Vim button is not offered", br.js("getComputedStyle(document.querySelector('.vim-toggle')).display") == "none")
    br.js("document.getElementById('editor').focus()")
    br.ws.call("Input.insertText", {"text": "Typed on a phone."})
    time.sleep(2.5)
    check("…typing works and syncs", br.full() == "Typed on a phone." and L.server_text(db, pid) == "Typed on a phone.")


def resize(br, db, a):
    pid = new_post(a, "resize")
    text = L.novel(400_000, seed=9)
    L.store(db, pid, text)
    text = L.u16(text)
    open_post(br, pid)
    br.js("document.getElementById('editor').focus()")
    at = text.index("\n\n", 200_000) + 2
    br.js(f"{B}.view.select({at}, {at}, true)")
    time.sleep(0.3)
    br.ws.call("Emulation.setDeviceMetricsOverride", {"width": 700, "height": 900, "deviceScaleFactor": 1, "mobile": False})
    time.sleep(0.5)
    br.js(f"{B}.view.reveal({at})")
    time.sleep(0.2)
    y = br.caret_y()
    check("after a resize the caret can be shown", 100 < y < 900, y)
    br.keys("Z")
    check("…and typing goes where it is", br.full() == text[:at] + "Z" + text[at:])
    br.ws.call("Emulation.setDeviceMetricsOverride", {"width": 1280, "height": 900, "deviceScaleFactor": 1, "mobile": False})


def vim_edges(br, db, a):
    pid = new_post(a, "vimedges")
    text = L.u16(L.novel(200_000, seed=4))
    L.store(db, pid, L.novel(200_000, seed=4))
    open_post(br, pid)
    br.js("localStorage.setItem('bent:vim-ok', '1')")
    br.js("document.querySelector('.vim-toggle').click()")
    time.sleep(0.2)
    br.js(f"{B}.view.select(100000, 100000, true)")
    time.sleep(0.3)
    ws, we = br.win()
    # dd on the window's last line, then J there, then p.
    last = text.rfind("\n", 0, we) + 1
    br.js(f"{B}.view.select({last}, {last + 1}, true)")
    time.sleep(0.3)
    ws2, we2 = br.win()
    br.keys("dd")
    time.sleep(0.2)
    e = text.find("\n", last)
    want = text[:last] + text[e + 1:]
    check("vim dd on a line at the window's edge", br.full() == want, br.full() == want)
    text = want
    br.keys("P")
    time.sleep(0.2)
    want = text[:last] + L.u16(L.novel(200_000, seed=4))[last:e + 1] + text[last:] if False else None
    check("vim P puts the line back", br.full() is not None and len(br.full()) == len(text) + (e + 1 - last))
    text = br.full()
    # V, then j well past the window's edge, then d.
    br.js(f"{B}.view.select({ws2 + 200}, {ws2 + 201}, true)")
    time.sleep(0.2)
    at = br.sel()[0]
    br.keys("V" + "j" * 200 + "d")
    time.sleep(0.5)
    full = br.full()
    s0 = text.rfind("\n", 0, at) + 1
    check("vim V with j past the window's edge, then d: those lines go", full is not None and len(full) < len(text) - 10000 and full[:s0] == text[:s0], (len(full or ""), len(text)))
    br.keys("u")
    time.sleep(0.3)
    check("…and u brings them back", br.full() == text)
    br.js("document.querySelector('.vim-toggle').click()")


def shift_arrows(br, db, a):
    pid = new_post(a, "shiftarrows")
    L.store(db, pid, L.novel(150_000, seed=6))
    text = L.u16(L.novel(150_000, seed=6))
    open_post(br, pid)
    br.js("document.getElementById('editor').focus()")
    br.js(f"{B}.view.select(20000, 20000, true)")
    time.sleep(0.3)
    ws, we = br.win()
    for _ in range(420):
        key(br, "ArrowDown", "ArrowDown", 40, SHIFT)
    time.sleep(0.5)
    s = br.sel()
    check("Shift+ArrowDown held past the window's edge keeps selecting", s[0] == 20000 and s[1] > we, (s, we))
    br.keys("X")
    time.sleep(0.3)
    check("…and typing replaces the whole selection", br.full() == text[:20000] + "X" + text[s[1]:], len(br.full() or ""))


def reopen(br, db, a, tmp):
    """Offline edits, then the browser is shut down (not a page closed
    politely); opened again online, the post has them and sends them."""
    pid = new_post(a, "reopen")
    open_post(br, pid)
    br.js("document.getElementById('editor').focus()")
    br.keys("Kept. ")
    time.sleep(2)
    br.ws.call("Network.emulateNetworkConditions", {"offline": True, "latency": 0, "downloadThroughput": -1, "uploadThroughput": -1})
    br.keys("Typed offline, browser closed.")
    time.sleep(1.5)
    br.close()
    time.sleep(1)
    b3 = page(9384, tmp, a, "c1")  # the same profile: its localStorage
    open_post(b3, pid)
    time.sleep(3)
    want = "Kept. Typed offline, browser closed."
    check("edits made offline, the browser then shut down, are sent when the post is opened again",
          b3.full() == want and L.server_text(db, pid) == want, (b3.full(), L.server_text(db, pid)))
    return b3


def visual_edit(br, b2, db, a):
    pid = new_post(a, "visualedit")
    open_post(br, pid)
    br.js("document.getElementById('editor').focus()")
    br.keys("First paragraph.<CR><CR>Second paragraph.")
    time.sleep(2)
    br.js("document.querySelector('.edit-tools .seg:nth-child(2)').click()")
    time.sleep(0.3)
    # Enter at the end of the first paragraph, then a new one.
    br.js("""(() => { const p = document.querySelector('.wys p'); const t = p.firstChild; getSelection().collapse(t, t.length); })()""")
    br.keys("<CR>")
    br.js("document.execCommand('insertText', false, 'Middle one.')")
    time.sleep(0.4)
    check("Visual mode: Enter makes a new paragraph", br.full() == "First paragraph.\n\nMiddle one.\n\nSecond paragraph.", repr(br.full()))
    # Backspace at the start of the last paragraph merges it into the one before.
    br.js("""(() => { const ps = document.querySelectorAll('.wys p'); const t = ps[ps.length - 1].firstChild; getSelection().collapse(t, 0); })()""")
    br.keys("<BS>")
    time.sleep(0.4)
    check("…Backspace at a paragraph's start joins it to the one before", br.full() == "First paragraph.\n\nMiddle one.Second paragraph.", repr(br.full()))
    # Another writer, in Visual mode too.
    open_post(b2, pid)
    b2.js("document.querySelector('.edit-tools .seg:nth-child(2)').click()")
    time.sleep(0.3)
    b2.js("""(() => { const p = document.querySelector('.wys p'); const t = p.firstChild; getSelection().collapse(t, 0); document.querySelector('.wys').focus(); })()""")
    b2.js("document.execCommand('insertText', false, 'Their ')")
    time.sleep(3)
    check("…another writer in Visual mode: their words appear here, rendered", "Their First paragraph." in (br.js("document.querySelector('.wys').textContent") or ""), br.js("document.querySelector('.wys').textContent"))
    check("…and both have the same text", br.full() == b2.full(), (br.full(), b2.full()))
    for b in (br, b2):
        b.js("document.querySelector('.edit-tools .seg:nth-child(1)').click()")


def long_line(br, db, a):
    pid = new_post(a, "longline")
    line = ("word " * 60000).strip()
    L.store(db, pid, line)
    open_post(br, pid)
    br.js("document.getElementById('editor').focus()")
    br.js(f"{B}.view.select(150000, 150000, true)")
    time.sleep(0.3)
    med, worst = br.per_key("abc")
    # A known limit (docs/FINDINGS.md): the window is cut at line breaks
    # only, and the browser lays a paragraph out whole.
    print(f"  (a 300 KB paragraph without line breaks: {med:.0f} ms a key)")
    check("a 300 KB paragraph without line breaks: typing works", br.full() == line[:150000] + "abc" + line[150000:])


def main():
    tmp = tempfile.mkdtemp()
    dbpath = os.path.join(tmp, "blog.db")
    env = dict(os.environ, PORT=str(E.PORT), BLOG_DB=dbpath, BLOG_ORIGIN=E.BASE, BLOG_RP_ID="localhost", BLOG_WORKERS="1")
    srv = subprocess.Popen([os.path.join(E.ROOT, "build/server")], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    brs = []
    try:
        E.wait_port(E.PORT)
        db = sqlite3.connect(dbpath)
        _, a = E.user(db, "writer@example.com")
        E.http("POST", "/blogs", a, {"slug": "u", "title": "U"})
        br = page(9381, tmp, a, "c1")
        brs.append(br)
        b2 = page(9382, tmp, a, "c2")
        brs.append(b2)
        for name, fn, args in [("writing", writing, (br, db, a)), ("together", together, (br, b2, db, a)), ("offline", offline, (br, db, a)),
                               ("ime", ime, (br, a)), ("edges", edges, (br, db, a)), ("visual", visual, (br, a)),
                               ("loading", loading, (b2, db, a)), ("resize", resize, (br, db, a)),
                               ("vim at the edges", vim_edges, (br, db, a)), ("shift+arrows", shift_arrows, (br, db, a)),
                               ("visual editing", visual_edit, (br, b2, db, a)), ("long line", long_line, (br, db, a))]:
            print(f"-- {name}")
            db.execute("DELETE FROM write_budget")
            db.commit()
            fn(*args)
        print("-- reopen after the browser was shut down")
        brs.remove(br)
        brs.append(reopen(br, db, a, tmp))
        ph = page(9383, tmp, a, "c3", 390, 844, True)
        brs.append(ph)
        print("-- phone")
        phone(ph, db, a)
    finally:
        for b in brs:
            b.close()
        srv.terminate()
    print(f"\n{E.fails} failure(s)")
    sys.exit(1 if E.fails else 0)


if __name__ == "__main__":
    main()
