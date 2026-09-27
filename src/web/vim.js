// Vim keybindings for the Markdown editor (opt-in: see editor.js). The core
// is pure: a key and the textarea's state (text, selection) in, the new
// state out; editor.js applies it to the textarea, whose input event turns
// any change into CRDT operations like typing does. Tested in
// tests/vim_test.mjs (commands, and random key sequences: the cursor stays
// in the text, every change undoes to the text before it).
//
// Positions are UTF-16 indexes (the textarea's); moves step over whole
// code points. Covered: counts; h j k l w b e W B E 0 ^ $ gg G f F t T ; ,
// { }; operators d c y > < with motions and text objects (iw aw iW aW i" a"
// i' a' i( a( ib i[ a[ i{ a{ iB); dd cc yy >> << D C Y x X s S r ~ J p P;
// i a I A o O; v V (d x y c > < o ~); u, Ctrl-r (undo, redo) and . (repeat);
// / ? n N (search); :w :wq :x (save), :<n> (go to line).

import { prefix, suffix } from "./common.js";

const isSpace = (c) => c === " " || c === "\t" || c === "\n" || c === "\r";
const isWord = (c) => /[\p{L}\p{N}_]/u.test(c);
// 0 blank, 1 word, 2 punctuation; big words: 0 blank, 1 anything else.
const cls = (c, big) => (c === undefined || isSpace(c) ? 0 : big || isWord(c) ? 1 : 2);

function charAt(t, i) {
  const c = t.codePointAt(i);
  return c === undefined ? undefined : String.fromCodePoint(c);
}
function next(t, i) {
  if (i >= t.length) return t.length;
  const c = t.codePointAt(i);
  return i + (c > 0xffff ? 2 : 1);
}
function prev(t, i) {
  if (i <= 0) return 0;
  const lo = t.charCodeAt(i - 1);
  return i - (lo >= 0xdc00 && lo <= 0xdfff && i >= 2 ? 2 : 1);
}
function lineStart(t, i) {
  // (lastIndexOf with -1 would still look at index 0.)
  return i <= 0 ? 0 : t.lastIndexOf("\n", i - 1) + 1;
}
function lineEnd(t, i) {
  const n = t.indexOf("\n", i);
  return n < 0 ? t.length : n;
}
// The last character of the line (where normal mode may stand), or its start if empty.
function lastOn(t, i) {
  const s = lineStart(t, i), e = lineEnd(t, i);
  return e > s ? prev(t, e) : s;
}
function firstNonBlank(t, i) {
  let p = lineStart(t, i);
  const e = lineEnd(t, i);
  while (p < e && (t[p] === " " || t[p] === "\t")) p++;
  return p;
}
function col(t, i) {
  return i - lineStart(t, i);
}
function lineOf(t, i) {
  let n = 0;
  for (let k = t.indexOf("\n"); k >= 0 && k < i; k = t.indexOf("\n", k + 1)) n++;
  return n;
}
function lineStartOf(t, n) {
  let p = 0;
  for (let k = 0; k < n; k++) {
    const q = t.indexOf("\n", p);
    if (q < 0) return p;
    p = q + 1;
  }
  return p;
}
function lineCount(t) {
  let n = 1;
  for (let k = t.indexOf("\n"); k >= 0; k = t.indexOf("\n", k + 1)) n++;
  return n;
}
const clamp = (i, lo, hi) => Math.max(lo, Math.min(hi, i));

// Word motions (big: WORD). Each answers a position in [0, t.length].
function wordFwd(t, i, big) {
  const n = t.length;
  if (i >= n) return n;
  const c0 = cls(charAt(t, i), big);
  let p = i;
  if (c0 !== 0) while (p < n && cls(charAt(t, p), big) === c0) p = next(t, p);
  while (p < n && cls(charAt(t, p), big) === 0) {
    // An empty line is a word of its own.
    if (t[p] === "\n" && t[p + 1] === "\n" && p + 1 > i) return p + 1;
    p = next(t, p);
  }
  return p;
}
function wordBack(t, i, big) {
  let p = prev(t, i);
  while (p > 0 && cls(charAt(t, p), big) === 0) {
    if (t[p] === "\n" && t[p - 1] === "\n") return p;
    p = prev(t, p);
  }
  const c = cls(charAt(t, p), big);
  while (p > 0 && cls(charAt(t, prev(t, p)), big) === c && c !== 0) p = prev(t, p);
  return p;
}
function wordEnd(t, i, big) {
  const n = t.length;
  let p = next(t, i);
  while (p < n && cls(charAt(t, p), big) === 0) p = next(t, p);
  if (p >= n) return prev(t, n);
  const c = cls(charAt(t, p), big);
  while (next(t, p) < n && cls(charAt(t, next(t, p)), big) === c) p = next(t, p);
  return p;
}
// } and {: the next (previous) empty line, past any empty lines here.
const emptyLine = (t, s) => lineEnd(t, s) === s;
function paraFwd(t, i) {
  let s = lineStart(t, i);
  while (s < t.length && emptyLine(t, s)) s = lineEnd(t, s) + 1;
  while (s < t.length) {
    const e = lineEnd(t, s);
    if (e >= t.length) return lastOn(t, s);
    s = e + 1;
    if (emptyLine(t, s)) return s;
  }
  return Math.min(s, t.length);
}
function paraBack(t, i) {
  let s = lineStart(t, i);
  while (s > 0 && emptyLine(t, s)) s = lineStart(t, s - 1);
  while (s > 0) {
    s = lineStart(t, s - 1);
    if (emptyLine(t, s)) return s;
  }
  return 0;
}

// Text objects: [start, end) around i, or null.
function wordObject(t, i, big, around) {
  if (t.length === 0) return null;
  const c = cls(charAt(t, i), big);
  let s = i, e = next(t, i);
  while (s > 0 && cls(charAt(t, prev(t, s)), big) === c && t[prev(t, s)] !== "\n") s = prev(t, s);
  while (e < t.length && cls(charAt(t, e), big) === c && t[e] !== "\n") e = next(t, e);
  if (around) {
    let e2 = e;
    while (e2 < t.length && (t[e2] === " " || t[e2] === "\t")) e2++;
    if (e2 > e) e = e2;
    else while (s > 0 && (t[s - 1] === " " || t[s - 1] === "\t")) s--;
  }
  return [s, e];
}
function quoteObject(t, i, q, around) {
  const s0 = lineStart(t, i), e0 = lineEnd(t, i);
  const qs = [];
  for (let p = s0; p < e0; p++) if (t[p] === q && t[p - 1] !== "\\") qs.push(p);
  for (let k = 0; k + 1 < qs.length; k += 2) {
    if (i >= qs[k] && i <= qs[k + 1]) return around ? [qs[k], qs[k + 1] + 1] : [qs[k] + 1, qs[k + 1]];
  }
  const after = qs.findIndex((p) => p > i);
  if (after >= 0 && after + 1 < qs.length) return around ? [qs[after], qs[after + 1] + 1] : [qs[after] + 1, qs[after + 1]];
  return null;
}
function bracketObject(t, i, open, close, around) {
  let depth = 0, s = -1;
  for (let p = i; p >= 0; p--) {
    if (t[p] === close && p !== i) depth++;
    else if (t[p] === open) {
      if (depth === 0) {
        s = p;
        break;
      }
      depth--;
    }
  }
  if (s < 0) return null;
  depth = 0;
  for (let p = s + 1; p < t.length; p++) {
    if (t[p] === open) depth++;
    else if (t[p] === close) {
      if (depth === 0) return around ? [s, p + 1] : [s + 1, p];
      depth--;
    }
  }
  return null;
}
const PAIRS = { "(": "()", ")": "()", b: "()", "[": "[]", "]": "[]", "{": "{}", "}": "{}", B: "{}", "<": "<>", ">": "<>" };
function textObject(t, i, kind, around) {
  if (kind === "w" || kind === "W") return wordObject(t, i, kind === "W", around);
  if (kind === '"' || kind === "'" || kind === "`") return quoteObject(t, i, kind, around);
  const pr = PAIRS[kind];
  return pr ? bracketObject(t, i, pr[0], pr[1], around) : null;
}

// A diff of a change: at p, `del` replaced by `ins`.
function diff(a, b) {
  const p = prefix(a, b);
  const s = suffix(a, b, p);
  return { p, del: a.slice(p, a.length - s), ins: b.slice(p, b.length - s) };
}

export class Vim {
  constructor() {
    this.mode = "normal"; // normal | insert | visual | vline
    this.keys = [];       // the command typed so far (normal and visual)
    this.reg = { text: "", line: false };
    this.undos = [];      // {p, del, ins, cur}: a change, to undo
    this.redos = [];
    this.want = -1;       // the column j and k aim for
    this.anchor = 0;      // visual mode's fixed end
    this.head = 0;        // visual mode's moving end (the cursor)
    this.find = null;     // last f/F/t/T: {k, c}
    this.search = null;   // last search: {pat, back}
    this.last = null;     // the last change, for "."
    this.change = null;   // the change being typed (its keys), until Esc
    this.insertFrom = null; // text and cursor when insert mode began
    this.cmd = null;      // ":" or "/" or "?" while a command line is open
    this.cmdText = "";
  }

  // The cursor to show: normal mode stands on a character.
  static normalize(t, c) {
    c = clamp(c, 0, t.length);
    if (c >= t.length || t[c] === "\n") {
      const s = lineStart(t, c);
      if (c > s) c = prev(t, c);
    }
    return c;
  }

  // Enter from insert mode: the insert becomes one undo step (and "." repeats it).
  escape(t, cur) {
    if (this.mode === "insert") {
      if (this.insertFrom) {
        const d = diff(this.insertFrom.text, t);
        if (d.del || d.ins) this.record(d, this.insertFrom.cur);
        if (this.change) {
          // What was typed: the change since the command made its own.
          const e = diff(this.insertFrom.after, t);
          this.last = { keys: this.change, insert: e.del === "" ? e.ins : null };
        }
      }
      this.insertFrom = null;
      this.change = null;
      this.mode = "normal";
      return { text: t, cur: Vim.normalize(t, prev(t, cur) < lineStart(t, cur) ? cur : prev(t, cur)) };
    }
    this.mode = "normal";
    this.keys = [];
    return { text: t, cur: Vim.normalize(t, cur) };
  }

  record(d, cur) {
    this.undos.push({ ...d, cur });
    if (this.undos.length > 500) this.undos.shift();
    this.redos = [];
  }

  // One key (a KeyboardEvent key, "C-r" for Ctrl+R) in normal or visual
  // mode, or in an open command line. s: {text, a, b} (the selection; in
  // normal mode the cursor is at a). Answers {text, a, b, msg, save} or
  // null when the key is not the editor's business.
  key(k, s) {
    let t = s.text;
    let cur = s.a;
    if (this.cmd !== null) return this.cmdKey(k, s);
    if (this.mode === "insert") return null;
    if (this.mode === "visual" || this.mode === "vline") cur = clamp(this.head, 0, t.length);
    this.keys.push(k);
    const r = this.run(t, cur, this.keys);
    if (r === "more") return { text: t, a: s.a, b: s.b, pending: this.keys.join("") };
    this.keys = [];
    if (r === null) return { text: t, a: s.a, b: s.b, msg: "" };
    // Normal mode shows a cursor, not a selection.
    if (this.mode === "normal" && r.b !== r.a && !r.keepCursor) r.b = r.a;
    return r;
  }

  cmdKey(k, s) {
    const t = s.text;
    if (k === "Escape") {
      this.cmd = null;
      return { text: t, a: s.a, b: s.b, cmdline: null };
    }
    if (k === "Backspace") {
      if (this.cmdText === "") this.cmd = null;
      this.cmdText = this.cmdText.slice(0, -1);
      return { text: t, a: s.a, b: s.b, cmdline: this.cmd === null ? null : this.cmd + this.cmdText };
    }
    if (k !== "Enter") {
      if ([...k].length === 1) this.cmdText += k;
      return { text: t, a: s.a, b: s.b, cmdline: this.cmd + this.cmdText };
    }
    const kind = this.cmd, arg = this.cmdText;
    this.cmd = null;
    this.cmdText = "";
    if (kind === ":") {
      const c = arg.trim();
      if (c === "w" || c === "wq" || c === "x" || c === "w!") return { text: t, a: s.a, b: s.b, save: true, cmdline: null, msg: "Saving…" };
      if (/^\d+$/.test(c)) {
        const p = firstNonBlank(t, lineStartOf(t, Math.max(0, Number(c) - 1)));
        return this.at(t, p);
      }
      if (c === "q" || c === "q!") return { text: t, a: s.a, b: s.b, cmdline: null, msg: "Leave with the ← button (your text is saved as you type)" };
      return { text: t, a: s.a, b: s.b, cmdline: null, msg: "Not an editor command: " + c };
    }
    if (arg) this.search = { pat: arg, back: kind === "?" };
    return this.searchNext(t, s.a, false) || { text: t, a: s.a, b: s.b, cmdline: null, msg: "Pattern not found: " + arg };
  }

  searchNext(t, cur, reverse) {
    if (!this.search) return null;
    const back = this.search.back !== reverse;
    const pat = this.search.pat;
    let p;
    if (back) {
      p = t.lastIndexOf(pat, cur - 1);
      if (p < 0) p = t.lastIndexOf(pat);
    } else {
      p = t.indexOf(pat, cur + 1);
      if (p < 0) p = t.indexOf(pat);
    }
    if (p < 0) return null;
    return { ...this.at(t, p), cmdline: null };
  }

  at(t, c) {
    const n = Vim.normalize(t, c);
    this.want = -1;
    if (this.mode === "visual" || this.mode === "vline") return this.visualSel(t, n);
    return { text: t, a: n, b: n, cmdline: null };
  }

  visualSel(t, c) {
    this.head = c;
    let a = Math.min(this.anchor, c), b = Math.max(this.anchor, c);
    if (this.mode === "vline") {
      a = lineStart(t, a);
      b = lineEnd(t, b);
    } else b = next(t, b);
    return { text: t, a, b, head: c };
  }

  // Parses and runs a command: "more" if incomplete, null if not a command.
  run(t, cur, keys) {
    let i = 0;
    let count = "";
    while (i < keys.length && /^[0-9]$/.test(keys[i]) && !(keys[i] === "0" && count === "")) count += keys[i++];
    if (i >= keys.length) return "more";
    const n = count === "" ? 1 : Math.min(Number(count), 100000);
    const k = keys[i];
    const rest = keys.slice(i + 1);
    const visual = this.mode === "visual" || this.mode === "vline";

    // Motions (also the targets of operators).
    const motion = this.motion(t, cur, k, rest, n, count !== "");
    if (motion === "more") return "more";
    if (motion) {
      if (motion.col !== undefined) this.want = motion.col;
      else this.want = -1;
      if (visual) return this.visualSel(t, Vim.normalize(t, motion.to));
      return { text: t, a: Vim.normalize(t, motion.to), b: Vim.normalize(t, motion.to) };
    }
    if (visual) return this.visualKey(t, cur, k, rest, n);

    switch (k) {
      case "i": return this.insert(t, cur, keys);
      case "a": return this.insert(t, cur < lineEnd(t, cur) ? next(t, cur) : cur, keys);
      case "I": return this.insert(t, firstNonBlank(t, cur), keys);
      case "A": return this.insert(t, lineEnd(t, cur), keys);
      case "o": {
        const e = lineEnd(t, cur);
        return this.insert(t.slice(0, e) + "\n" + t.slice(e), e + 1, keys, t, cur);
      }
      case "O": {
        const s0 = lineStart(t, cur);
        return this.insert(t.slice(0, s0) + "\n" + t.slice(s0), s0, keys, t, cur);
      }
      case "v":
      case "V":
        this.mode = k === "v" ? "visual" : "vline";
        this.anchor = cur;
        return this.visualSel(t, cur);
      case "x": case "s": {
        // The n characters from the cursor, within the line.
        const e0 = lineEnd(t, cur);
        let e = cur;
        for (let j = 0; j < n && e < e0; j++) e = next(t, e);
        if (e === cur) return k === "s" ? this.insert(t, cur, keys) : null;
        return this.apply(t, cur, k === "x" ? "d" : "c", { a: cur, b: e, line: false }, keys);
      }
      case "X": case "S": case "D": case "C": case "Y": {
        const map = { X: ["d", "h"], S: ["c", "c"], D: ["d", "$"], C: ["c", "$"], Y: ["y", "y"] }[k];
        return this.operate(t, cur, map[0], [map[1]], n, count !== "", keys);
      }
      case "d": case "c": case "y": case ">": case "<":
        if (rest.length === 0) return "more";
        return this.operate(t, cur, k, rest, n, count !== "", keys);
      case "p": case "P": return this.paste(t, cur, k === "P", n, keys);
      case "r": {
        if (rest.length === 0) return "more";
        const c = rest[0];
        if ([...c].length !== 1 && c !== "Enter") return null;
        let e = cur;
        for (let j = 0; j < n; j++) {
          if (e >= lineEnd(t, cur)) return null;
          e = next(t, e);
        }
        const ch = c === "Enter" ? "\n" : c;
        const u = t.slice(0, cur) + ch.repeat(n) + t.slice(e);
        return this.changed(t, u, c === "Enter" ? cur + 1 : cur + ch.length * n - ch.length, keys, cur);
      }
      case "~": {
        let e = cur;
        for (let j = 0; j < n && e < lineEnd(t, cur); j++) e = next(t, e);
        const sw = [...t.slice(cur, e)].map((c) => (c === c.toLowerCase() ? c.toUpperCase() : c.toLowerCase())).join("");
        return this.changed(t, t.slice(0, cur) + sw + t.slice(e), Math.min(e, lastOn(t, cur)), keys, cur);
      }
      case "J": {
        let u = t, c = cur;
        for (let j = 0; j < Math.max(1, n - (count ? 1 : 0)); j++) {
          const e = lineEnd(u, c);
          if (e >= u.length) break;
          let q = e + 1;
          while (q < u.length && (u[q] === " " || u[q] === "\t")) q++;
          const sep = q < u.length && u[q] !== "\n" && e > lineStart(u, c) && u[e - 1] !== " " ? " " : "";
          u = u.slice(0, e) + sep + u.slice(q);
          c = e;
        }
        return u === t ? null : this.changed(t, u, c, keys, cur);
      }
      case "u": return this.undo(t, n);
      case "C-r": return this.redo(t, n);
      case ".": {
        if (!this.last) return null;
        return this.repeat(t, cur, count ? n : 0);
      }
      case "n": case "N":
        return this.searchNext(t, cur, k === "N") || { text: t, a: cur, b: cur, msg: this.search ? "Pattern not found" : "No previous search" };
      case ":": case "/": case "?":
        this.cmd = k;
        this.cmdText = "";
        return { text: t, a: cur, b: cur, cmdline: k };
      case "Escape": return { text: t, a: cur, b: cur };
      case "g":
        if (rest.length === 0) return "more";
        return null;
      case "z": case "Z": case "m": case "q": case "@": case '"':
        if (rest.length === 0) return "more";
        return { text: t, a: cur, b: cur, msg: "Not supported here" };
      default:
        return null;
    }
  }

  // A motion: {to, col?, line?, incl?} or "more" or null.
  motion(t, cur, k, rest, n, counted) {
    let p = cur;
    switch (k) {
      case "h": case "ArrowLeft": case "Backspace":
        for (let j = 0; j < n && p > lineStart(t, cur); j++) p = prev(t, p);
        return { to: p };
      case "l": case "ArrowRight": case " ":
        for (let j = 0; j < n && p < lastOn(t, cur); j++) p = next(t, p);
        return { to: p, incl: false };
      case "j": case "k": case "ArrowDown": case "ArrowUp": case "Enter": case "+": case "-": {
        const down = k === "j" || k === "ArrowDown" || k === "Enter" || k === "+";
        const want = this.want >= 0 ? this.want : col(t, cur);
        let s = lineStart(t, cur);
        for (let j = 0; j < n; j++) {
          if (down) {
            const e = lineEnd(t, s);
            if (e >= t.length) break;
            s = e + 1;
          } else {
            if (s === 0) break;
            s = lineStart(t, s - 1);
          }
        }
        const to = k === "Enter" || k === "+" || k === "-" ? firstNonBlank(t, s) : Math.min(s + want, lastOn(t, s));
        return { to, col: k === "Enter" || k === "+" || k === "-" ? undefined : want, line: true };
      }
      case "0": case "Home": return { to: lineStart(t, cur) };
      case "^": return { to: firstNonBlank(t, cur) };
      case "$": case "End": {
        let s = lineStart(t, cur);
        for (let j = 1; j < n; j++) {
          const e = lineEnd(t, s);
          if (e >= t.length) break;
          s = e + 1;
        }
        return { to: lastOn(t, s), incl: true, col: Infinity };
      }
      case "w": case "W":
        for (let j = 0; j < n; j++) p = wordFwd(t, p, k === "W");
        return { to: p, word: true };
      case "b": case "B":
        for (let j = 0; j < n; j++) p = wordBack(t, p, k === "B");
        return { to: p };
      case "e": case "E":
        for (let j = 0; j < n; j++) p = wordEnd(t, p, k === "E");
        return { to: p, incl: true };
      case "}":
        for (let j = 0; j < n; j++) p = paraFwd(t, p);
        return { to: p };
      case "{":
        for (let j = 0; j < n; j++) p = paraBack(t, p);
        return { to: p };
      case "G":
        return { to: firstNonBlank(t, counted ? lineStartOf(t, n - 1) : lineStartOf(t, lineCount(t) - 1)), line: true };
      case "g":
        if (rest.length === 0) return "more";
        if (rest[0] === "g") return { to: firstNonBlank(t, lineStartOf(t, counted ? n - 1 : 0)), line: true };
        if (rest[0] === "e") {
          for (let j = 0; j < n; j++) {
            p = prev(t, p);
            while (p > 0 && cls(charAt(t, p)) === 0) p = prev(t, p);
            const c = cls(charAt(t, p));
            while (p > 0 && cls(charAt(t, prev(t, p))) === c && c !== 0) p = prev(t, p);
            p = Math.max(0, p - 1);
          }
          return { to: p, incl: true };
        }
        return null;
      case "f": case "F": case "t": case "T": {
        if (rest.length === 0) return "more";
        const c = rest[0];
        if ([...c].length !== 1) return null;
        this.find = { k, c };
        return this.findChar(t, cur, k, c, n);
      }
      case ";": case ",": {
        if (!this.find) return null;
        const flip = { f: "F", F: "f", t: "T", T: "t" };
        return this.findChar(t, cur, k === ";" ? this.find.k : flip[this.find.k], this.find.c, n, true);
      }
      default:
        return null;
    }
  }

  findChar(t, cur, k, c, n, again) {
    const s = lineStart(t, cur), e = lineEnd(t, cur);
    let p = cur;
    for (let j = 0; j < n; j++) {
      if (k === "f" || k === "t") {
        let q = t.indexOf(c, p + 1 + (again && k === "t" && j === 0 ? 1 : 0));
        if (q < 0 || q >= e) return { to: cur, fail: true };
        p = q;
      } else {
        let q = t.lastIndexOf(c, p - 1 - (again && k === "T" && j === 0 ? 1 : 0));
        if (q < s) return { to: cur, fail: true };
        p = q;
      }
    }
    if (k === "t") p = prev(t, p);
    if (k === "T") p = next(t, p);
    return { to: p, incl: k === "f" || k === "t" };
  }

  // The range [a, b) an operator acts on, and whether it is whole lines.
  range(t, cur, op, rest, n, counted) {
    if (rest.length === 0) return "more";
    const k = rest[0];
    if (k === op || (op === "c" && k === "c")) {
      // dd cc yy >> <<: n whole lines.
      const a = lineStart(t, cur);
      let e = lineEnd(t, cur);
      for (let j = 1; j < n && e < t.length; j++) e = lineEnd(t, e + 1);
      return { a, b: e, line: true };
    }
    if (k === "i" || k === "a") {
      if (rest.length < 2) return "more";
      const r = textObject(t, cur, rest[1], k === "a");
      return r ? { a: r[0], b: r[1], line: false } : null;
    }
    let digits = "";
    let j = 0;
    while (j < rest.length && /^[0-9]$/.test(rest[j]) && !(rest[j] === "0" && digits === "")) digits += rest[j++];
    if (j >= rest.length) return "more";
    const m2 = digits === "" ? n : n * Number(digits);
    const m = this.motion(t, cur, rest[j], rest.slice(j + 1), m2, counted || digits !== "");
    if (m === "more") return "more";
    if (!m || m.fail) return null;
    if (m.line) {
      const a = lineStart(t, Math.min(cur, m.to));
      const b = lineEnd(t, Math.max(cur, m.to));
      return { a, b, line: true };
    }
    let a = Math.min(cur, m.to), b = Math.max(cur, m.to);
    if (m.incl) b = next(t, b);
    if (m.word) {
      if (op === "c" && cls(charAt(t, cur)) !== 0) {
        // cw is ce, but a word's last character changes alone.
        const nx = next(t, cur);
        let e = nx < t.length && cls(charAt(t, nx)) === cls(charAt(t, cur)) ? wordEnd(t, cur) : cur;
        for (let q = 1; q < m2; q++) e = wordEnd(t, e);
        b = next(t, e);
      } else if (t.slice(a, b).includes("\n") && lineEnd(t, a) > a) {
        // dw stops at the end of the line.
        b = lineEnd(t, a);
      }
    }
    return { a, b, line: false };
  }

  operate(t, cur, op, rest, n, counted, keys) {
    const r = this.range(t, cur, op, rest, n, counted);
    if (r === "more") return "more";
    if (!r) return null;
    return this.apply(t, cur, op, r, keys);
  }

  // An operator on [a, b) (line: whole lines, b at the last line's end).
  apply(t, cur, op, r, keys) {
    const { a, b, line } = r;
    if (op === "y") {
      // The cursor stays for whole lines, else goes to the start.
      this.reg = { text: t.slice(a, b) + (line ? "\n" : ""), line };
      const c = Vim.normalize(t, line ? (cur >= a && cur <= b ? cur : a) : a);
      return { text: t, a: c, b: c };
    }
    if (op === ">" || op === "<") {
      const s0 = lineStart(t, a);
      const lines = t.slice(s0, lineEnd(t, b > a ? prev(t, b) : a)).split("\n");
      const out = lines.map((l) => (op === ">" ? (l ? "  " + l : l) : l.replace(/^( {1,2}|\t)/, ""))).join("\n");
      const e0 = s0 + lines.join("\n").length;
      const u = t.slice(0, s0) + out + t.slice(e0);
      return this.changed(t, u, firstNonBlank(u, s0), keys, cur);
    }
    if (line) {
      this.reg = { text: t.slice(a, b) + "\n", line: true };
      if (op === "c") {
        const indent = t.slice(a, firstNonBlank(t, a));
        const u = t.slice(0, a) + indent + t.slice(b);
        return this.insert(u, a + indent.length, keys, t, cur);
      }
      // Delete the lines and one line break with them.
      let s = a, e = b;
      if (e < t.length) e++;
      else if (s > 0) s--;
      const u = t.slice(0, s) + t.slice(e);
      return this.changed(t, u, firstNonBlank(u, Math.min(s === a ? a : s + 1, u.length)), keys, cur);
    }
    this.reg = { text: t.slice(a, b), line: false };
    const u = t.slice(0, a) + t.slice(b);
    if (op === "c") return this.insert(u, a, keys, t, cur);
    return this.changed(t, u, a, keys, cur);
  }

  visualKey(t, cur, k, rest, n) {
    const sel = this.visualSel(t, cur);
    const line = this.mode === "vline";
    const r = { a: sel.a, b: sel.b, line };
    switch (k) {
      case "Escape": case "v": case "V":
        if ((k === "v" && this.mode === "vline") || (k === "V" && this.mode === "visual")) {
          this.mode = k === "v" ? "visual" : "vline";
          return this.visualSel(t, cur);
        }
        this.mode = "normal";
        return { text: t, a: Vim.normalize(t, cur), b: Vim.normalize(t, cur) };
      case "o": {
        const head = this.anchor;
        this.anchor = cur;
        return this.visualSel(t, head);
      }
      case "d": case "x": case "y": case "c": case ">": case "<": case "s": {
        const op = k === "x" ? "d" : k === "s" ? "c" : k;
        this.mode = "normal";
        return this.apply(t, Math.min(sel.a, cur), op, r, null);
      }
      case "~": case "u": case "U": {
        const s = t.slice(r.a, r.b);
        const f = k === "u" ? s.toLowerCase() : k === "U" ? s.toUpperCase()
          : [...s].map((c) => (c === c.toLowerCase() ? c.toUpperCase() : c.toLowerCase())).join("");
        this.mode = "normal";
        return this.changed(t, t.slice(0, r.a) + f + t.slice(r.b), r.a, null, cur);
      }
      case "i": case "a":
        if (rest.length === 0) return "more";
        {
          const o = textObject(t, cur, rest[0], k === "a");
          if (!o) return this.visualSel(t, cur);
          this.anchor = o[0];
          return this.visualSel(t, prev(t, o[1]));
        }
      default:
        return this.visualSel(t, cur);
    }
  }

  paste(t, cur, before, n, keys) {
    const { text, line } = this.reg;
    if (!text) return null;
    const body = text.repeat(n);
    if (line) {
      const at = before ? lineStart(t, cur) : lineEnd(t, cur) + (lineEnd(t, cur) < t.length ? 1 : 0);
      const ins = at === t.length && !before && !t.endsWith("\n") && t !== "" ? "\n" + body.slice(0, -1) : body;
      const u = t.slice(0, at) + ins + t.slice(at);
      return this.changed(t, u, firstNonBlank(u, at === t.length && ins.startsWith("\n") ? at + 1 : at), keys, cur);
    }
    const at = before || cur >= t.length || t[cur] === "\n" ? cur : next(t, cur);
    const u = t.slice(0, at) + body + t.slice(at);
    return this.changed(t, u, prev(u, at + body.length), keys, cur);
  }

  // Insert mode at c, in text u (made from t by the command, if any).
  insert(u, c, keys, t = u, cur = c) {
    this.mode = "insert";
    this.insertFrom = { text: t, cur, after: u };
    this.change = keys ? keys.slice() : null;
    return { text: u, a: c, b: c, mode: "insert" };
  }

  // A normal-mode change from t to u, the cursor at c: one undo step.
  changed(t, u, c, keys, cur) {
    if (u !== t) {
      this.record(diff(t, u), cur);
      if (keys) this.last = { keys: keys.slice(), insert: null };
    }
    const n = Vim.normalize(u, c);
    return { text: u, a: n, b: n };
  }

  // Undo: the change is found where it was (other people's edits may have
  // moved it: then nearby); if the text there changed, nothing is undone.
  undo(t, n) {
    let u = t, c = 0, done = 0;
    for (let j = 0; j < n && this.undos.length; j++) {
      const d = this.undos[this.undos.length - 1];
      const p = locate(u, d.p, d.ins);
      if (p < 0) return { text: u, a: 0, b: 0, msg: "Cannot undo: the text there has changed", keepCursor: true };
      this.undos.pop();
      u = u.slice(0, p) + d.del + u.slice(p + d.ins.length);
      this.redos.push({ ...d, p });
      c = Math.min(d.cur, u.length);
      if (p + d.del.length < c || c < p) c = p;
      done++;
    }
    if (!done) return { text: t, a: 0, b: 0, msg: "Already at oldest change", keepCursor: true };
    const k = Vim.normalize(u, c);
    return { text: u, a: k, b: k };
  }

  redo(t, n) {
    let u = t, c = 0, done = 0;
    for (let j = 0; j < n && this.redos.length; j++) {
      const d = this.redos[this.redos.length - 1];
      const p = locate(u, d.p, d.del);
      if (p < 0) return { text: u, a: 0, b: 0, msg: "Cannot redo: the text there has changed", keepCursor: true };
      this.redos.pop();
      u = u.slice(0, p) + d.ins + u.slice(p + d.del.length);
      this.undos.push({ ...d, p });
      c = p;
      done++;
    }
    if (!done) return { text: t, a: 0, b: 0, msg: "Already at newest change", keepCursor: true };
    const k = Vim.normalize(u, c);
    return { text: u, a: k, b: k };
  }

  // ".": the last change again at the cursor (count: in place of its own).
  repeat(t, cur, count) {
    const { keys, insert } = this.last;
    let ks = keys.slice();
    if (count) {
      let i = 0;
      while (i < ks.length && /^[0-9]$/.test(ks[i])) i++;
      ks = [...String(count)].concat(ks.slice(i));
    }
    const saved = this.last;
    const r = this.run(t, cur, ks);
    if (!r || r === "more") return null;
    if (this.mode === "insert") {
      const ins = insert || "";
      const u = r.text.slice(0, r.a) + ins + r.text.slice(r.a);
      const d = diff(t, u);
      this.mode = "normal";
      this.insertFrom = null;
      this.change = null;
      if (d.del || d.ins) this.record(d, cur);
      this.last = saved;
      const c = Vim.normalize(u, prev(u, r.a + ins.length) < lineStart(u, r.a) ? r.a : prev(u, r.a + ins.length));
      return { text: u, a: c, b: c };
    }
    this.last = saved;
    return r;
  }
}

// Where `s` is in t, at p or, if other edits moved it, the nearest place
// within 4096 characters; -1 if not found.
function locate(t, p, s) {
  if (t.slice(p, p + s.length) === s) return p;
  if (s === "") return Math.min(p, t.length);
  const lo = Math.max(0, p - 4096), hi = Math.min(t.length, p + 4096 + s.length);
  const win = t.slice(lo, hi);
  let best = -1;
  for (let q = win.indexOf(s); q >= 0; q = win.indexOf(s, q + 1)) {
    if (best < 0 || Math.abs(lo + q - p) < Math.abs(best - p)) best = lo + q;
  }
  return best;
}

export const _test = { wordFwd, wordBack, wordEnd, lineStart, lineEnd, textObject, locate, diff };
