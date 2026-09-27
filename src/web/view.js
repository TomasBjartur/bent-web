// The Markdown view of a document of any length (vanilla JS: purely the
// browser's work).
//
// A textarea holding a whole novel costs ~28 ms of the browser's own work
// per keystroke per megabyte, and ~130 ms per megabyte to change from
// script (measured in Chrome; docs/FINDINGS.md). So the textarea holds only
// a window of the text around the selection (~64 KB), and the rest is
// static text in plain blocks laid out exactly as the textarea lays out
// text. Far-off blocks are skipped by the browser (content-visibility), yet
// keep their height, are found by the browser's find, and can be selected.
//
//   .doc
//     div.seg (static)   lines [s0, e0)
//     div.seg (static)   lines [s1, e1)        each piece: whole lines; one
//     textarea (window)  lines [s2, e2)        "\n" between pieces, implied
//     div.seg (static)   ...                    by the block boundary
//
// The window moves with the selection: before it gets within EDGE of the
// window's edge (and at once for keys at the very edge), and when a click
// or a drag in static text selects there. Moving re-cuts only the pieces
// next to the window, and text keeps its place on screen: the same text is
// laid out the same way whether static or in the textarea, and the pieces
// next to the window are never skipped (so their heights are real).
//
// Positions are UTF-16 units in the whole text, as the CRDT counts them.

const SEG = 8192;       // static pieces are cut at line ends near this size
const MARGIN = 32768;   // the window reaches this far past the selection
const EDGE = 12288;     // recentred when the selection comes this close to an edge
const WIDE = 4 * MARGIN; // a window grown past this (a paste) is cut back
const NEAR = 2;         // pieces on each side of the window always laid out

export class View {
  // hooks.edit(p, del, ins, delText): the textarea changed the text (typing,
  // paste, drop, IME): [p, p + del) became ins.
  constructor(ta, hooks) {
    this.ta = ta;
    this.hooks = hooks;
    this.text = ta.value;
    this.box = document.createElement("div");
    this.box.className = "doc";
    ta.parentNode.insertBefore(this.box, ta);
    this.box.appendChild(ta);
    ta.classList.add("window");
    // Pieces in order: {el, len, win}. Exactly one is the window.
    this.pieces = [];
    this.winText = "";
    this.checking = 0;
    this.grows = !(window.CSS && CSS.supports && CSS.supports("field-sizing", "content"));
    this.build(0, 0);
    ta.addEventListener("input", () => this.onInput());
    // While an input method composes (Japanese, Chinese, a phone's
    // keyboard), setting the textarea's value ends the composition: the
    // window does not move until it is over. (Another writer's change near
    // the caret still goes in at once: the text here must stay the CRDT's.)
    this.composing = false;
    ta.addEventListener("compositionstart", () => (this.composing = true));
    ta.addEventListener("compositionend", () => {
      this.composing = false;
      this.check();
    });
    ta.addEventListener("keydown", (ev) => this.onKey(ev));
    // Selection changes: after the browser has moved it.
    const later = () => this.check();
    ta.addEventListener("keyup", later);
    ta.addEventListener("mouseup", later);
    ta.addEventListener("focus", later);
    ta.addEventListener("select", later);
    document.addEventListener("selectionchange", later);
    // A selection made in static text becomes the editing selection.
    document.addEventListener("mouseup", (ev) => this.adopt(ev));
    this.box.addEventListener("mousedown", (ev) => this.shiftClick(ev));
    window.addEventListener("resize", () => this.grow());
  }

  get length() {
    return this.text.length;
  }

  // WHERE THINGS ARE
  // Start of the window, and its piece index.
  win() {
    let s = 0;
    for (let i = 0; i < this.pieces.length; i++) {
      const pc = this.pieces[i];
      if (pc.win) return { i, s, e: s + pc.len };
      s += pc.len + 1;
    }
    throw new Error("view: no window");
  }

  lineStart(p) {
    return p <= 0 ? 0 : this.text.lastIndexOf("\n", p - 1) + 1;
  }

  lineEnd(p) {
    const n = this.text.indexOf("\n", p);
    return n < 0 ? this.text.length : n;
  }

  // The selection in the whole text: {a, b, back} (back: the caret at a).
  sel() {
    const w = this.win();
    const ta = this.ta;
    return { a: w.s + ta.selectionStart, b: w.s + ta.selectionEnd, back: ta.selectionDirection === "backward" };
  }

  // BUILDING
  // Static pieces for the lines [s, e) (s a line start, e a line end).
  cut(s, e) {
    const out = [];
    if (s > e) return out;
    let p = s;
    for (;;) {
      let q = e;
      if (e - p > SEG) {
        // The last line end before p + SEG, or else the first after it.
        const back = this.text.lastIndexOf("\n", p + SEG);
        q = back >= p && back < e ? back : this.text.indexOf("\n", p + SEG);
        if (q < 0 || q > e) q = e;
      }
      out.push(this.piece(this.text.slice(p, q)));
      if (q >= e) break;
      p = q + 1;
    }
    return out;
  }

  piece(t) {
    const el = document.createElement("div");
    el.className = "seg";
    el.textContent = t;
    return { el, len: t.length, win: false };
  }

  // Everything again, the window around [a, b].
  build(a, b) {
    const n = this.text.length;
    const ws = this.lineStart(Math.max(0, Math.min(a, b) - MARGIN));
    const we = this.lineEnd(Math.min(n, Math.max(a, b) + MARGIN));
    const before = ws > 0 ? this.cut(0, ws - 1) : [];
    const after = we < n ? this.cut(we + 1, n) : [];
    for (const pc of this.pieces) if (!pc.win) pc.el.remove();
    this.place(before, after);
    this.pieces = [...before, { el: this.ta, len: we - ws, win: true }, ...after];
    this.setWindow(this.text.slice(ws, we));
    this.near(false);
  }

  // Static pieces in just before and after the textarea, which never moves
  // (moving a focused element takes the focus and the selection away).
  place(pre, post) {
    const frag = document.createDocumentFragment();
    for (const pc of pre) frag.appendChild(pc.el);
    this.box.insertBefore(frag, this.ta);
    const after = document.createDocumentFragment();
    for (const pc of post) after.appendChild(pc.el);
    this.box.insertBefore(after, this.ta.nextSibling);
  }

  setWindow(t) {
    this.winText = t;
    if (this.ta.value !== t) this.ta.value = t;
    this.grow();
  }

  // Pieces next to the window are always laid out (their heights must be
  // real when they join it); the rest only when on screen. A piece made
  // from text that was on the page (measure) keeps its measured height
  // while skipped, so nothing above the caret moves; one never laid out
  // (at the start) is as tall as its lines guess until it is.
  near(measure = true) {
    const { i } = this.win();
    const going = [];
    this.pieces.forEach((pc, k) => {
      if (pc.win) return;
      const far = Math.abs(k - i) > NEAR;
      if (far === pc.el.classList.contains("far")) return;
      if (!far) pc.el.classList.remove("far");
      else going.push(pc);
    });
    // Measure first (one layout), then change (no layout in between).
    const hs = going.map((pc) => (measure && !pc.el.style.containIntrinsicBlockSize ? pc.el.offsetHeight : 0));
    going.forEach((pc, k) => {
      if (!pc.el.style.containIntrinsicBlockSize) pc.el.style.containIntrinsicBlockSize = "auto " + (hs[k] || guess(pc.len)) + "px";
      pc.el.classList.add("far");
    });
  }

  // The pieces overlapping [lo, hi] (with the lines next to it) and the
  // window: indexes [i, j] and the text they span, [rs, re].
  span(lo, hi, withWindow = true) {
    let s = 0, i = -1, j = -1, rs = 0, re = 0;
    for (let k = 0; k < this.pieces.length; k++) {
      const pc = this.pieces[k];
      const e = s + pc.len;
      if ((e + 1 >= lo && s <= hi + 1) || (pc.win && withWindow)) {
        if (i < 0) {
          i = k;
          rs = s;
        }
        j = k;
        re = e;
      }
      s = e + 1;
    }
    return { i, j, rs, re };
  }

  // Replaces the pieces [i, j], spanning [rs, re] of the text as it is now,
  // with new ones: the window on the lines around [a, b], static text
  // either side. Answers the window's start.
  recut({ i, j, rs, re }, a, b) {
    const n = this.text.length;
    const ws = Math.max(rs, this.lineStart(Math.max(0, Math.min(a, b) - MARGIN)));
    const we = Math.max(ws, Math.min(re, this.lineEnd(Math.min(n, Math.max(a, b) + MARGIN))));
    const pre = ws > rs ? this.cut(rs, ws - 1) : [];
    const post = we < re ? this.cut(we + 1, re) : [];
    for (const pc of this.pieces.slice(i, j + 1)) if (!pc.win) pc.el.remove();
    this.place(pre, post);
    this.pieces.splice(i, j - i + 1, ...pre, { el: this.ta, len: we - ws, win: true }, ...post);
    this.setWindow(this.text.slice(ws, we));
    this.near();
    return ws;
  }

  // Moves the window to the lines around [a, b]. Near where it is, the
  // pieces between are re-cut; far from it, the window's text becomes
  // static where it is, and only the pieces there are re-cut (the text in
  // between is left as it is, heights and all).
  // The line with b (the caret) stays where it is on screen: whatever
  // heights change above it (a skipped piece laid out for the first time),
  // the page scrolls by as much.
  rewindow(a, b) {
    const y0 = this.yOf(b);
    const ws = this.move(a, b);
    const y1 = y0 === null ? null : this.yOf(b);
    if (y1 !== null && Math.abs(y1 - y0) > 0.5) window.scrollBy(0, y1 - y0);
    return ws;
  }

  move(a, b) {
    const lo = Math.min(a, b), hi = Math.max(a, b);
    const w = this.win();
    if (hi + 2 * MARGIN >= w.s && lo - 2 * MARGIN <= w.e) return this.recut(this.span(lo, hi), a, b);
    const focused = document.activeElement === this.ta;
    // The window's text, static in its place.
    const frozen = this.cut(w.s, w.e);
    const frag = document.createDocumentFragment();
    for (const pc of frozen) frag.appendChild(pc.el);
    this.box.insertBefore(frag, this.ta);
    this.pieces.splice(w.i, 1, ...frozen);
    // Measured now, while on the page (they are skipped once far).
    for (const pc of frozen) pc.el.style.containIntrinsicBlockSize = "auto " + pc.el.offsetHeight + "px";
    // The textarea to the target's pieces, which are then re-cut around it.
    const sp = this.span(lo, hi, false);
    this.box.insertBefore(this.ta, this.pieces[sp.i].el);
    this.pieces.splice(sp.i, 0, { el: this.ta, len: 0, win: true });
    sp.j++;
    const ws = this.recut(sp, a, b);
    if (focused) this.focus();
    return ws;
  }

  // THE SELECTION
  // Selects [a, b] (a > b: backwards), moving the window if needed.
  // reveal: scroll the caret into view.
  select(a, b = a, reveal = false) {
    const n = this.text.length;
    a = Math.max(0, Math.min(n, a));
    b = Math.max(0, Math.min(n, b));
    let w = this.win();
    const lo = Math.min(a, b), hi = Math.max(a, b);
    if (!this.fits(w, lo, hi)) {
      this.rewindow(a, b);
      w = this.win();
    }
    const back = a > b;
    this.ta.setSelectionRange(lo - w.s, hi - w.s, back ? "backward" : "forward");
    if (reveal) this.reveal(back ? lo : hi);
  }

  // Is [lo, hi] inside the window, EDGE from its edges (unless the text ends there)?
  fits(w, lo, hi) {
    return lo >= w.s && hi <= w.e && (w.s === 0 || lo - w.s >= EDGE) && (w.e === this.text.length || w.e - hi >= EDGE);
  }

  focus() {
    this.ta.focus({ preventScroll: true });
  }

  // After the selection moved: keep the window around it (and not too wide).
  check() {
    if (this.checking) return;
    this.checking = requestAnimationFrame(() => {
      this.checking = 0;
      if (document.activeElement !== this.ta || this.composing) return;
      const w = this.win();
      const s = this.sel();
      const wide = w.e - w.s > WIDE && s.b - s.a < MARGIN;
      if (!this.fits(w, s.a, s.b) || wide) {
        this.rewindow(s.back ? s.b : s.a, s.back ? s.a : s.b);
        const w2 = this.win();
        this.ta.setSelectionRange(s.a - w2.s, s.b - w2.s, s.back ? "backward" : "forward");
      }
    });
  }

  // Keys at the window's very edge: the window moves first, then the key
  // does what it does. Ctrl+Home/End and Ctrl+A act on the whole text.
  onKey(ev) {
    const ta = this.ta;
    const mod = ev.ctrlKey || ev.metaKey;
    const w = this.win();
    const n = this.text.length;
    if (mod && !ev.altKey && (ev.key === "a" || ev.key === "A") && (w.s > 0 || w.e < n)) {
      ev.preventDefault();
      this.select(0, n);
      return;
    }
    if (mod && (ev.key === "Home" || ev.key === "End" || (ev.metaKey && (ev.key === "ArrowUp" || ev.key === "ArrowDown")))) {
      if (w.s === 0 && w.e === n) return;
      ev.preventDefault();
      const to = ev.key === "Home" || ev.key === "ArrowUp" ? 0 : n;
      const s = this.sel();
      this.select(ev.shiftKey ? (s.back ? s.b : s.a) : to, to, true);
      return;
    }
    const s0 = ta.selectionStart, s1 = ta.selectionEnd;
    const atStart = s0 === 0 && w.s > 0, atEnd = s1 === ta.value.length && w.e < n;
    const back = ev.key === "Backspace" || ev.key === "ArrowLeft" || ev.key === "ArrowUp" || ev.key === "PageUp";
    const fwd = ev.key === "Delete" || ev.key === "ArrowRight" || ev.key === "ArrowDown" || ev.key === "PageDown";
    if ((back && (atStart || s0 < EDGE / 4)) || (fwd && (atEnd || ta.value.length - s1 < EDGE / 4))) {
      const s = this.sel();
      if ((back && w.s > 0) || (fwd && w.e < n)) {
        this.rewindow(s.back ? s.b : s.a, s.back ? s.a : s.b);
        const w2 = this.win();
        ta.setSelectionRange(s.a - w2.s, s.b - w2.s, s.back ? "backward" : "forward");
      }
    }
  }

  // TEXT FROM THE TEXTAREA
  onInput() {
    const v = this.ta.value;
    const old = this.winText;
    if (v === old) return;
    const w = this.win();
    const d = diff(old, v);
    const p = w.s + d.p;
    const delText = old.slice(d.p, d.p + d.del);
    this.text = this.text.slice(0, p) + d.ins + this.text.slice(p + d.del);
    this.pieces[w.i].len = v.length;
    this.winText = v;
    this.grow();
    this.hooks.edit(p, d.del, d.ins, delText);
    if (v.length > WIDE) this.check();
  }

  // TEXT FROM ELSEWHERE (another writer, undo, Vim, an image): [p, p + del)
  // becomes ins. keep: the selection stays with the text around it.
  apply(p, del, ins, keep = true) {
    if (del === 0 && ins === "") return;
    const n = this.text.length;
    p = Math.max(0, Math.min(p, n));
    del = Math.max(0, Math.min(del, n - p));
    const w = this.win();
    const focused = document.activeElement === this.ta;
    const s = this.sel();
    const map = (x) => (x <= p ? x : x >= p + del ? x - del + ins.length : p + ins.length);
    const delta = ins.length - del;
    const sp = this.span(p, p + del); // (before the text changes)
    this.text = this.text.slice(0, p) + ins + this.text.slice(p + del);
    if (p >= w.s && p + del <= w.e) {
      // Inside the window.
      const ta = this.ta;
      ta.setRangeText(ins, p - w.s, p - w.s + del, keep ? "preserve" : "end");
      this.pieces[w.i].len += ins.length - del;
      this.winText = ta.value;
      this.grow();
      return;
    }
    // Inside one static piece?
    let st = 0;
    for (let k = 0; k < this.pieces.length; k++) {
      const pc = this.pieces[k];
      const e = st + pc.len;
      if (!pc.win && p >= st && p + del <= e) {
        pc.len += delta;
        pc.el.textContent = this.text.slice(st, st + pc.len);
        return;
      }
      st = e + 1;
    }
    // Across pieces: re-cut them, the window where the selection now is.
    const a = map(s.back ? s.b : s.a), b = map(s.back ? s.a : s.b);
    sp.re += delta;
    const ws = this.recut(sp, a, b);
    if (focused || keep) this.ta.setSelectionRange(Math.min(a, b) - ws, Math.max(a, b) - ws, a > b ? "backward" : "forward");
  }

  // Replaces the whole text (the document arrived): the selection stays
  // with the text around it.
  reset(t) {
    if (t === this.text) return;
    const d = diff(this.text, t);
    const s = this.sel();
    const map = (x) => (x <= d.p ? x : x >= d.p + d.del ? x - d.del + d.ins.length : d.p + d.ins.length);
    this.text = t;
    const a = map(s.back ? s.b : s.a), b = map(s.back ? s.a : s.b);
    this.build(a, b);
    const w = this.win();
    this.ta.setSelectionRange(Math.min(a, b) - w.s, Math.max(a, b) - w.s, a > b ? "backward" : "forward");
  }

  // STATIC TEXT: SELECTING THERE
  // The offset in the whole text of a point in a static piece (node, off),
  // or -1.
  offsetOf(node, off) {
    let el = node;
    while (el && el.parentNode !== this.box) el = el.parentNode;
    if (!el || el === this.ta) return -1;
    let s = 0;
    for (const pc of this.pieces) {
      if (pc.el === el) {
        if (node === el) return s + (off > 0 ? pc.len : 0);
        // Offsets within the piece's text node (the ::after is not text).
        return s + Math.min(off, pc.len);
      }
      s += pc.len + 1;
    }
    return -1;
  }

  // A selection made (by mouse) in static text: select that for editing.
  adopt(ev) {
    if (ev.button !== 0) return;
    const sel = document.getSelection();
    if (!sel || !sel.rangeCount || !this.box.contains(sel.anchorNode) || document.activeElement === this.ta) return;
    const a = this.offsetOf(sel.anchorNode, sel.anchorOffset);
    const b = this.offsetOf(sel.focusNode, sel.focusOffset);
    if (a < 0 || b < 0) return;
    sel.removeAllRanges();
    this.select(a, b);
    this.focus();
  }

  // Shift+click in static text while editing: extend the selection there.
  shiftClick(ev) {
    if (!ev.shiftKey || ev.button !== 0 || document.activeElement !== this.ta || ev.target === this.ta) return;
    const at = pointOffset(this, ev.clientX, ev.clientY);
    if (at < 0) return;
    ev.preventDefault();
    const s = this.sel();
    this.select(s.back ? s.b : s.a, at);
  }

  // SCROLLING
  // The top of the line with text position p, on screen; null if it is not
  // laid out (in a skipped piece).
  yOf(p) {
    let s = 0;
    for (const pc of this.pieces) {
      const e = s + pc.len;
      if (p >= s && p <= e) {
        if (pc.win) return this.ta.getBoundingClientRect().top + caretTop(this.ta, p - s);
        const t = pc.el.firstChild;
        if (!t) return null;
        const r = document.createRange();
        const k = p - s;
        if (k < pc.len) {
          r.setStart(t, k);
          r.setEnd(t, k + 1);
        } else if (k > 0) {
          r.setStart(t, k - 1);
          r.setEnd(t, k);
        } else return pc.el.getBoundingClientRect().top;
        // (A skipped piece has no boxes: null.)
        const rs = r.getClientRects();
        return rs.length && rs[rs.length - 1].height > 0 ? rs[rs.length - 1].top : null;
      }
      s = e + 1;
    }
    return null;
  }

  // Scrolls so the caret at p is on screen (below the sticky bars).
  reveal(p) {
    const w = this.win();
    if (p < w.s || p > w.e) return;
    const y = this.box.getBoundingClientRect().top + window.scrollY + this.ta.offsetTop + caretTop(this.ta, p - w.s);
    const top = 150, bottom = 80;
    if (y < window.scrollY + top) window.scrollTo(window.scrollX, y - top);
    else if (y > window.scrollY + window.innerHeight - bottom) window.scrollTo(window.scrollX, y - window.innerHeight / 2);
  }

  // Browsers without field-sizing: the textarea as tall as its text.
  grow() {
    if (!this.grows) return;
    const ta = this.ta;
    const y = window.scrollY;
    ta.style.height = "auto";
    ta.style.height = ta.scrollHeight + "px";
    window.scrollTo(window.scrollX, y);
  }

  set readOnly(v) {
    this.ta.readOnly = v;
  }

  get readOnly() {
    return this.ta.readOnly;
  }
}

// A static piece's height before it is laid out: its characters over a
// line's worth (~70 at the editor's measure), 1.72 lines of 1.2rem each.
function guess(len) {
  return Math.max(1, Math.ceil(len / 70)) * 33;
}

// The edit between two strings: common prefix and suffix, compared 4 KB at
// a time (common.js), not splitting a surrogate pair.
import { prefix, suffix } from "./common.js";

export function diff(a, b) {
  let p = prefix(a, b);
  if (p > 0 && isHigh(a.charCodeAt(p - 1))) p--;
  let s = suffix(a, b, p);
  if (s > 0 && isLow(a.charCodeAt(a.length - s))) s--;
  return { p, del: a.length - p - s, ins: b.slice(p, b.length - s) };
}

const isHigh = (c) => c >= 0xd800 && c <= 0xdbff;
const isLow = (c) => c >= 0xdc00 && c <= 0xdfff;

// The text offset under a point in a static piece, or -1.
function pointOffset(view, x, y) {
  let node = null, off = 0;
  if (document.caretPositionFromPoint) {
    const r = document.caretPositionFromPoint(x, y);
    if (r) {
      node = r.offsetNode;
      off = r.offset;
    }
  } else if (document.caretRangeFromPoint) {
    const r = document.caretRangeFromPoint(x, y);
    if (r) {
      node = r.startContainer;
      off = r.startOffset;
    }
  }
  return node ? view.offsetOf(node, off) : -1;
}

// The caret's top in a textarea, from a mirror laid out the same way.
let mirror = null;
function caretTop(ta, i) {
  if (!mirror) {
    mirror = document.createElement("div");
    mirror.setAttribute("aria-hidden", "true");
    mirror.style.cssText = "position:absolute;left:-10000px;top:0;visibility:hidden;white-space:pre-wrap;overflow-wrap:break-word;";
    document.body.appendChild(mirror);
  }
  const cs = getComputedStyle(ta);
  mirror.style.width = ta.clientWidth + "px";
  mirror.style.font = cs.font;
  mirror.style.letterSpacing = cs.letterSpacing;
  mirror.style.padding = cs.padding;
  mirror.style.tabSize = cs.tabSize;
  mirror.textContent = ta.value.slice(0, i);
  const mark = document.createElement("span");
  mark.textContent = "​";
  mirror.appendChild(mark);
  const top = mark.offsetTop;
  mirror.textContent = "";
  return top;
}
