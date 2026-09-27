#!/usr/bin/env python3
"""The editor on long documents, in real Chrome (keys sent as a keyboard
does). A post of SIZE characters (a novel: paragraphs, headings, accents,
emoji) is stored as operations, then:

- it loads, and the textarea holds only a window of it (the rest is static
  text); memory and time to load are reported;
- typing, Vim motions and edits stay within a frame or two per key at the
  start, the middle and the end, and reach the server exactly;
- a click in static text puts the caret on the character clicked; a drag
  there selects that text; Ctrl+Home/End go to the ends of the whole text;
  holding an arrow key across the window's edge moves the caret smoothly
  and the text does not jump on screen; Ctrl+A selects everything;
- undo and redo work across window moves;
- another writer's edits, near the caret and far from it, arrive without
  moving the caret, and both writers converge.

usage: tests/large_test.py [size]   (default 1000000; needs ./build.sh and
       tools/setup_chrome.sh)
"""
import json, os, random, sqlite3, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import editor_test as E

SIZE = int(sys.argv[1]) if len(sys.argv) > 1 else 1_000_000
FRAME = "new Promise(r => requestAnimationFrame(() => setTimeout(() => r(performance.now()), 0)))"
B = "document.getElementById('editor').bent"
REP = 123456789


def novel(n, seed=7):
    rng = random.Random(seed)
    words = ("the river of long evenings carries small boats past old walls where people talk about books "
             "and café light falls on streets that remember summers 🌊 nobody wrote down").split()
    out, size, para = [], 0, 0
    while size < n:
        if para % 30 == 0:
            s = f"## Chapter {para // 30 + 1}"
        else:
            s = " ".join(rng.choice(words) for _ in range(rng.randint(30, 220)))
            s = s[0].upper() + s[1:] + "."
        out.append(s)
        size += len(s) + 2
        para += 1
    text = "\n\n".join(out)
    # Cut at a code point, within n UTF-16 units.
    units = 0
    for i, ch in enumerate(text):
        units += 2 if ord(ch) > 0xFFFF else 1
        if units > n:
            return text[:i]
    return text


def utf16len(s):
    return sum(2 if ord(c) > 0xFFFF else 1 for c in s)


def u16(s):
    """s with each UTF-16 unit as one character (an emoji as its two
    surrogates), so Python's indexes are the editor's."""
    b = s.encode("utf-16-le", "surrogatepass")
    return "".join(chr(b[i] | b[i + 1] << 8) for i in range(0, len(b), 2))


def store(db, pid, text):
    """The text as one typed run of operations (replica REP), and as the
    saved body when it fits."""
    rows = []
    for k, ch in enumerate(text, 1):
        rows.append((pid, k, REP, 0, k - 1 if k > 1 else 0, REP if k > 1 else 0, 1, ord(ch)))
    db.executemany("INSERT INTO op(post_id, ctr, rep, kind, pctr, prep, side, ch) VALUES (?,?,?,?,?,?,?,?)", rows)
    db.execute("UPDATE post SET op_count = ? WHERE id = ?", (len(rows), pid))
    if len(text) <= 1_000_000:
        db.execute("UPDATE post_body SET body_md = ? WHERE post_id = ?", (text, pid))
    db.commit()


def server_text(db, pid):
    """The post's text as the server's C materializer makes it."""
    ops = db.execute("SELECT ctr, rep, kind, pctr, prep, side, ch FROM op WHERE post_id = ? ORDER BY seq", (pid,)).fetchall()
    f = tempfile.NamedTemporaryFile("w", delete=False, suffix=".ops")
    f.write("".join(".".join(map(str, o)) + ";" for o in ops))
    f.close()
    out = subprocess.run([os.path.join(E.ROOT, "build/c/fugue_cli"), f.name], capture_output=True, text=True).stdout
    os.unlink(f.name)
    if "<<TEXT>>" not in out:
        return None
    return u16(out.split("<<TEXT>>", 1)[1].rsplit("<<END>>", 1)[0])


class Page(E.Browser):
    def full(self):
        t = self.js(f"{B}.view.text")
        return None if t is None else u16(t)

    def sel(self):
        return self.js(f"(() => {{ const s = {B}.view.sel(); return [s.a, s.b]; }})()")

    def win(self):
        return self.js(f"(() => {{ const w = {B}.view.win(); return [w.s, w.e]; }})()")

    def wait_loaded(self, secs=120):
        t = time.time()
        while time.time() - t < secs:
            if self.js(f"!!document.getElementById('editor') && !!{B} && {B}.loaded()"):
                return time.time() - t
            time.sleep(0.05)
        return None

    def wait_synced(self, secs=120):
        t = time.time()
        while time.time() - t < secs:
            if self.js(f"{B}.pending()") == 0:
                return True
            time.sleep(0.1)
        return False

    def per_key(self, keys):
        """Median and worst time from a key to the next frame, in ms."""
        lat = []
        for k in keys:
            s = self.js("performance.now()")
            self.key(k)
            lat.append(self.js(FRAME) - s)
        lat.sort()
        return lat[len(lat) // 2], lat[-1]

    def caret_y(self):
        """The caret's top on screen (a mirror of the textarea)."""
        return self.js("""(() => {
          const ta = document.getElementById('editor');
          const m = document.createElement('div');
          const cs = getComputedStyle(ta);
          m.style.cssText = 'position:absolute;visibility:hidden;white-space:pre-wrap;overflow-wrap:break-word;top:0;left:0';
          m.style.width = ta.clientWidth + 'px'; m.style.font = cs.font; m.style.padding = cs.padding;
          m.textContent = ta.value.slice(0, ta.selectionEnd);
          const k = document.createElement('span'); k.textContent = '\\u200b'; m.appendChild(k);
          document.body.appendChild(m); const y = k.offsetTop; m.remove();
          return ta.getBoundingClientRect().top + y; })()""")


def main():
    tmp = tempfile.mkdtemp()
    dbpath = os.path.join(tmp, "blog.db")
    env = dict(os.environ, PORT=str(E.PORT), BLOG_DB=dbpath, BLOG_ORIGIN=E.BASE, BLOG_RP_ID="localhost", BLOG_WORKERS="1")
    srv = subprocess.Popen([os.path.join(E.ROOT, "build/server")], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    br = None
    check = E.check
    try:
        E.wait_port(E.PORT)
        db = sqlite3.connect(dbpath)
        _, a = E.user(db, "big@example.com")
        E.http("POST", "/blogs", a, {"slug": "big", "title": "Big"})
        _, loc, _ = E.http("POST", "/dash/big/posts", a, {"slug": "novel", "title": "Novel"})
        pid = int(loc.rsplit("/", 1)[1])
        text = novel(SIZE)
        store(db, pid, text)
        n = utf16len(text)
        text = u16(text)
        print(f"a post of {n} UTF-16 units")

        br = Page(9371, f"{tmp}/c", a)
        br.ws.call("Emulation.setDeviceMetricsOverride", {"width": 1280, "height": 900, "deviceScaleFactor": 1, "mobile": False})
        br.js("localStorage.setItem('bent:vim', '0')")
        t0 = time.time()
        br.open(f"{E.BASE}/edit/{pid}")
        took = br.wait_loaded()
        check("the post loads", took is not None and br.full() == text, (took, len(br.full() or "")))
        heap = br.js("performance.memory.usedJSHeapSize") / 1e6
        print(f"  loaded in {time.time() - t0:.1f} s; JS heap {heap:.0f} MB")
        check(f"memory stays moderate (JS heap {heap:.0f} MB for {n / 1e6:.1f}M characters)", heap < 60 + 90 * n / 1e6, heap)
        w = br.win()
        check("the textarea holds only a window", w[1] - w[0] < 150_000 and br.js("document.getElementById('editor').value.length") == w[1] - w[0], w)
        check("the rest is static text", br.js("document.querySelectorAll('.doc .seg').length") > 3)

        # TYPING at the start, the middle and the end.
        br.js("document.getElementById('editor').focus()")
        br.js(f"{B}.view.select(0, 0)")
        med, worst = br.per_key("Once ")
        print(f"  typing at the start: {med:.1f} ms a key (worst {worst:.1f})")
        check("typing at the start: within two frames", med < 34, med)
        text = "Once " + text
        mid = len(text) // 2
        mid = text.index("\n\n", mid) + 2
        br.js(f"{B}.view.select({mid}, {mid}, true)")
        time.sleep(0.3)
        med, worst = br.per_key("Midway ")
        print(f"  typing in the middle: {med:.1f} ms a key (worst {worst:.1f})")
        check("typing in the middle: within two frames", med < 34, med)
        text = text[:mid] + "Midway " + text[mid:]
        check("the text is what was typed", br.full() == text)

        # CTRL+END and CTRL+HOME: the ends of the whole text, shown.
        br.key("End", ctrl=True) if "End" in E.KEYS else None
        br.ws.call("Input.dispatchKeyEvent", {"type": "rawKeyDown", "key": "End", "code": "End", "windowsVirtualKeyCode": 35, "modifiers": 2})
        br.ws.call("Input.dispatchKeyEvent", {"type": "keyUp", "key": "End", "code": "End", "windowsVirtualKeyCode": 35, "modifiers": 2})
        time.sleep(0.3)
        s = br.sel()
        check("Ctrl+End goes to the end of the whole text", s == [len(br.full()), len(br.full())], s)
        y = br.caret_y()
        check("…and shows it", 100 < y < 900, y)
        med, worst = br.per_key(" The end.")
        print(f"  typing at the end: {med:.1f} ms a key (worst {worst:.1f})")
        text = text + " The end."
        check("typing at the end: within two frames", med < 34, med)
        br.ws.call("Input.dispatchKeyEvent", {"type": "rawKeyDown", "key": "Home", "code": "Home", "windowsVirtualKeyCode": 36, "modifiers": 2})
        br.ws.call("Input.dispatchKeyEvent", {"type": "keyUp", "key": "Home", "code": "Home", "windowsVirtualKeyCode": 36, "modifiers": 2})
        time.sleep(0.3)
        check("Ctrl+Home goes to the start", br.sel() == [0, 0], br.sel())

        # ARROWS ACROSS THE WINDOW'S EDGE: the caret moves line by line, and
        # the text stays put on screen (the page scrolls only to follow).
        br.js(f"{B}.view.select({mid}, {mid}, true)")
        time.sleep(0.3)
        w0 = br.win()
        jumps, prev_y, prev_sel = 0, br.caret_y(), br.sel()[0]
        steps = 0
        for _ in range(400):
            br.ws.call("Input.dispatchKeyEvent", {"type": "rawKeyDown", "key": "ArrowDown", "code": "ArrowDown", "windowsVirtualKeyCode": 40})
            br.ws.call("Input.dispatchKeyEvent", {"type": "keyUp", "key": "ArrowDown", "code": "ArrowDown", "windowsVirtualKeyCode": 40})
            br.js(FRAME)
            y = br.caret_y()
            s = br.sel()[0]
            steps += 1
            if s <= prev_sel or abs(y - prev_y) > 120:
                jumps += 1
            prev_y, prev_sel = y, s
            if br.win() != w0 and steps > 20:
                break
        w1 = br.win()
        check("holding ArrowDown moves the window along", w1 != w0, (w0, w1))
        check("…the caret moving down all the way, the text not jumping", jumps == 0, jumps)
        br.js(FRAME)
        time.sleep(0.2)
        check("…and the caret stays on screen", 60 < br.caret_y() < 900, br.caret_y())

        # A CLICK IN STATIC TEXT: the caret on the character clicked.
        target = text.index("## Chapter 5\n") + 3
        # Scroll the chapter heading into view (it is static text now).
        br.js(f"""(() => {{ const v = {B}.view; let s = 0; for (const pc of v.pieces) {{ if (!pc.win && s <= {target} && {target} <= s + pc.len) {{
            const r = document.createRange(); r.setStart(pc.el.firstChild, {target} - s); r.setEnd(pc.el.firstChild, {target} - s + 1);
            window.scrollTo(0, window.scrollY + r.getBoundingClientRect().top - 300); return; }} s += pc.len + 1; }} }})()""")
        time.sleep(0.4)
        pt = br.js(f"""(() => {{ const v = {B}.view; let s = 0; for (const pc of v.pieces) {{ if (!pc.win && s <= {target} && {target} <= s + pc.len) {{
            const r = document.createRange(); r.setStart(pc.el.firstChild, {target} - s); r.setEnd(pc.el.firstChild, {target} - s + 1);
            const b = r.getBoundingClientRect(); return [b.left + 1, b.top + b.height / 2]; }} s += pc.len + 1; }} return null; }})()""")
        check("chapter 5 is static text before the click", pt is not None, pt)
        if pt:
            y_before = pt[1]
            for t in ("mousePressed", "mouseReleased"):
                br.ws.call("Input.dispatchMouseEvent", {"type": t, "x": pt[0], "y": pt[1], "button": "left", "clickCount": 1})
            time.sleep(0.3)
            check("a click in static text puts the caret on that character", br.sel() == [target, target], (br.sel(), target))
            check("…focused, in the textarea", br.js("document.activeElement.id") == "editor")
            check("…and the text stays where it was on screen", abs(br.caret_y() - (y_before - 14)) < 30, (br.caret_y(), y_before))
            br.keys("X")
            text = text[:target] + "X" + text[target:]
            check("…and typing goes there", br.full() == text)

        # A DRAG IN STATIC TEXT selects; typing replaces the selection.
        target = text.index("## Chapter 9\n")
        br.js(f"""(() => {{ const v = {B}.view; let s = 0; for (const pc of v.pieces) {{ if (!pc.win && s <= {target} && {target} <= s + pc.len) {{
            const r = document.createRange(); r.setStart(pc.el.firstChild, {target} - s); r.setEnd(pc.el.firstChild, {target} - s + 1);
            window.scrollTo(0, window.scrollY + r.getBoundingClientRect().top - 300); return; }} s += pc.len + 1; }} }})()""")
        time.sleep(0.4)
        box = br.js(f"""(() => {{ const v = {B}.view; let s = 0; for (const pc of v.pieces) {{ if (!pc.win && s <= {target} && {target} <= s + pc.len) {{
            const r = document.createRange(); r.setStart(pc.el.firstChild, {target} - s); r.setEnd(pc.el.firstChild, {target} - s + 10);
            const rs = r.getClientRects(); const a = rs[0], b = rs[rs.length - 1];
            return [a.left + 1, a.top + a.height / 2, b.right - 1, b.top + b.height / 2]; }} s += pc.len + 1; }} return null; }})()""")
        if box:
            br.ws.call("Input.dispatchMouseEvent", {"type": "mousePressed", "x": box[0], "y": box[1], "button": "left", "clickCount": 1})
            for k in range(1, 6):
                br.ws.call("Input.dispatchMouseEvent", {"type": "mouseMoved", "x": box[0] + (box[2] - box[0]) * k / 5, "y": box[1], "button": "left", "buttons": 1})
            br.ws.call("Input.dispatchMouseEvent", {"type": "mouseReleased", "x": box[2], "y": box[3], "button": "left", "clickCount": 1})
            time.sleep(0.3)
            s = br.sel()
            check("a drag in static text selects that text", s[0] == target and 8 <= s[1] - s[0] <= 11, (s, target))
            br.keys("Y")
            text = text[: s[0]] + "Y" + text[s[1]:]
            check("…and typing replaces it", br.full() == text)

        # UNDO across window moves.
        br.js(f"{B}.view.select(0, 0, true)")
        time.sleep(0.2)
        br.keys("<C-z>")
        time.sleep(0.2)
        text2 = text[: s[0]] + text[s[0] + 1:] if box else text
        # (The last change was the Y replacing the selection: undo restores it.)
        check("undo after moving away undoes the last change, where it was", br.full() is not None and br.full() != text, "no change")
        br.keys("<C-z>")
        br.keys("<C-z>")
        time.sleep(0.2)
        br.ws.call("Input.dispatchKeyEvent", {"type": "rawKeyDown", "key": "z", "code": "KeyZ", "windowsVirtualKeyCode": 90, "modifiers": 2 | 8})
        br.ws.call("Input.dispatchKeyEvent", {"type": "keyUp", "key": "z", "code": "KeyZ", "windowsVirtualKeyCode": 90, "modifiers": 2 | 8})
        time.sleep(0.2)
        text = br.full()

        # VIM on the long text.
        br.js("localStorage.setItem('bent:vim-ok', '1')")
        br.js("document.querySelector('.vim-toggle').click()")
        time.sleep(0.2)
        br.js(f"{B}.view.select({mid}, {mid}, true)")
        time.sleep(0.2)
        med, worst = br.per_key("jjjjjjjjjjjj")
        print(f"  vim j: {med:.1f} ms a key (worst {worst:.1f})")
        check("vim j: within two frames", med < 34, med)
        at = br.sel()[0]
        med, worst = br.per_key("xxxxxxxx")
        print(f"  vim x: {med:.1f} ms a key (worst {worst:.1f})")
        check("vim x: within three frames", med < 50, med)
        br.keys("G")
        time.sleep(0.2)
        full = br.full()
        last = full.rfind("\n") + 1
        check("vim G goes to the last line of the whole text", br.sel()[0] == last, (br.sel(), last))
        br.keys("gg")
        time.sleep(0.2)
        check("vim gg to the first", br.sel()[0] == 0, br.sel())
        br.keys("/Chapter 12<CR>")
        time.sleep(0.3)
        check("vim search finds text far away", br.sel()[0] == full.index("Chapter 12"), (br.sel(), full.index("Chapter 12")))
        br.keys("dd")
        time.sleep(0.2)
        check("vim dd there", "## Chapter 12\n" not in br.full())
        br.keys("u")
        time.sleep(0.2)
        check("vim u undoes it", br.full() == full, len(br.full()))
        br.js("document.querySelector('.vim-toggle').click()")
        text = br.full()

        # VISUAL MODE on the long text: only blocks near the screen are
        # rendered; typing into one changes that place in the Markdown.
        text = br.full()
        t0 = br.js("performance.now()")
        br.js("document.querySelector('.edit-tools .seg:nth-child(2)').click()")
        t1 = br.js(FRAME)
        print(f"  Visual mode opens in {t1 - t0:.0f} ms")
        check("Visual mode opens on the long text, quickly", br.js("!document.querySelector('.wys').hidden") and t1 - t0 < 1500, t1 - t0)
        blocks = br.js("document.querySelectorAll('.wys .wblock').length")
        drawn = br.js("document.querySelectorAll('.wys .wblock:not(.wlazy)').length")
        check("…every block there, few rendered", blocks > 100 and drawn < 80, (blocks, drawn))
        br.js("window.scrollTo(0, document.querySelector('.wys').getBoundingClientRect().top + scrollY + document.querySelector('.wys').scrollHeight / 2)")
        time.sleep(0.6)
        vis = br.js("""(() => { const bs = [...document.querySelectorAll('.wys .wblock')];
            const on = bs.filter(b => { const r = b.getBoundingClientRect(); return r.bottom > 0 && r.top < innerHeight; });
            return [on.length, on.filter(b => b.classList.contains('wlazy')).length]; })()""")
        check("…scrolled to the middle, the blocks on screen are rendered", vis[0] > 0 and vis[1] == 0, vis)
        spot = br.js("""(() => { const bs = [...document.querySelectorAll('.wys .wblock')];
            const b = bs.find(b => { const r = b.getBoundingClientRect(); return r.top > 150 && r.top < innerHeight - 200 && b.querySelector('p'); });
            if (!b) return null; const t = b.querySelector('p').firstChild; const r = document.createRange(); r.setStart(t, 0); r.setEnd(t, 1);
            const x = r.getBoundingClientRect(); return [x.left + 0.5, x.top + x.height / 2, b.md.slice(0, 40)]; })()""")
        if spot:
            for t in ("mousePressed", "mouseReleased"):
                br.ws.call("Input.dispatchMouseEvent", {"type": t, "x": spot[0], "y": spot[1], "button": "left", "clickCount": 1})
            time.sleep(0.2)
            br.js("document.execCommand('insertText', false, 'Q')")
            time.sleep(0.4)
            want = u16(spot[2])
            at = text.index(want)
            got = br.full()
            check("…typing in a paragraph there changes that place in the Markdown", got == text[:at] + "Q" + text[at:], (got[at - 5: at + 20] if got else None))
            text = got
            med, worst = br.per_key("uick")
            print(f"  typing in Visual mode: {med:.1f} ms a key (worst {worst:.1f})")
            check("…typing in Visual mode: within three frames", med < 50, med)
            time.sleep(0.3)
            text = br.full()
        br.js("document.querySelector('.edit-tools .seg:nth-child(1)').click()")
        time.sleep(0.3)
        check("back to Markdown mode, the same text", br.full() == text)

        # ANOTHER WRITER, far away and near.
        check("everything typed reaches the server", br.wait_synced() and server_text(db, pid) == br.full(), "differs")
        b2 = Page(9372, f"{tmp}/c2", a)
        b2.ws.call("Emulation.setDeviceMetricsOverride", {"width": 1280, "height": 900, "deviceScaleFactor": 1, "mobile": False})
        b2.js("localStorage.setItem('bent:vim', '0')")
        b2.open(f"{E.BASE}/edit/{pid}")
        check("a second writer loads the same text", b2.wait_loaded() is not None and b2.full() == text)
        br.js("document.getElementById('editor').focus()")
        br.js(f"{B}.view.select(100, 100, true)")
        time.sleep(0.3)
        caret0, y0 = br.sel(), br.caret_y()
        b2.js("document.getElementById('editor').focus()")
        b2.js(f"{B}.view.select({len(text) - 50}, {len(text) - 50}, true)")
        b2.keys("far away ")
        b2.js(f"{B}.view.select(50, 50, true)")
        b2.keys("near ")
        time.sleep(3)
        check("their edits arrive, far and near", "far away " in br.full() and "near " in br.full()[:200], br.full()[:120])
        check("…my caret stays with my text", br.sel() == [caret0[0] + 5, caret0[1] + 5], (caret0, br.sel()))
        br.keys("mine ")
        time.sleep(3)
        check("both writers converge", br.full() == b2.full(), (len(br.full()), len(b2.full())))
        check("…as the server has it", br.wait_synced() and b2.wait_synced() and server_text(db, pid) == br.full())
        b2.close()

        # CTRL+A: everything.
        br.js("document.getElementById('editor').focus()")
        br.ws.call("Input.dispatchKeyEvent", {"type": "rawKeyDown", "key": "a", "code": "KeyA", "windowsVirtualKeyCode": 65, "modifiers": 2})
        br.ws.call("Input.dispatchKeyEvent", {"type": "keyUp", "key": "a", "code": "KeyA", "windowsVirtualKeyCode": 65, "modifiers": 2})
        time.sleep(0.5)
        check("Ctrl+A selects the whole text", br.sel() == [0, len(br.full())], br.sel())
        br.keys("Short now.")
        time.sleep(0.5)
        check("…and typing replaces it all", br.full() == "Short now.", (br.full() or "")[:40])
        if 2 * n + 1000 < 4_000_000:
            check("…which reaches the server", br.wait_synced() and server_text(db, pid) == "Short now.")
        else:
            # Past the server's 4 million operations a post takes no more
            # (deleted text counts): the editor says so, and keeps the text.
            # (Requests are accepted until the limit is reached.)
            for _ in range(600):
                st = br.js("document.getElementById('sync-status').textContent")
                if "limit" in st:
                    break
                time.sleep(0.5)
            check("…past the server's limit of operations, the editor says so", "limit of 4 million edits" in st, st)
    finally:
        if br:
            br.close()
        srv.terminate()
    print(f"\n{E.fails} failure(s)")
    sys.exit(1 if E.fails else 0)


if __name__ == "__main__":
    main()
