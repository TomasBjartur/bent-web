// Tests src/web/vim.js: commands against what Vim does, then random key
// sequences (invariants: the cursor stays in the text; undoing every
// change gives back the starting text; redoing gives back the end).
// usage: node tests/vim_test.mjs [seed]
import { Vim } from "../src/web/vim.js";

let fails = 0;
function check(name, ok, detail = "") {
  if (!ok) fails++;
  console.log((ok ? "PASS " : "FAIL ") + name + (ok ? "" : "   " + detail));
}

// Keys as Vim writes them: <Esc> <CR> <C-r> <BS>; anything else one key each.
function tokens(s) {
  const out = [];
  for (let i = 0; i < s.length; ) {
    if (s[i] === "<") {
      const j = s.indexOf(">", i);
      if (j > i) {
        const name = s.slice(i + 1, j);
        out.push({ Esc: "Escape", CR: "Enter", "C-r": "C-r", BS: "Backspace" }[name] || s.slice(i, j + 1));
        i = j + 1;
        continue;
      }
    }
    const c = String.fromCodePoint(s.codePointAt(i));
    out.push(c);
    i += c.length;
  }
  return out;
}

// What the textarea would do: in insert mode keys type (Enter a newline,
// Backspace deletes); otherwise the Vim core decides.
function drive(vim, st, keys) {
  for (const k of keys) {
    if (vim.mode === "insert" && vim.cmd === null) {
      if (k === "Escape") {
        const r = vim.escape(st.text, st.a);
        st = { text: r.text, a: r.cur, b: r.cur };
      } else if (k === "Backspace") {
        if (st.a > 0) st = { text: st.text.slice(0, st.a - 1) + st.text.slice(st.a), a: st.a - 1, b: st.a - 1 };
      } else {
        const c = k === "Enter" ? "\n" : k;
        st = { text: st.text.slice(0, st.a) + c + st.text.slice(st.b), a: st.a + c.length, b: st.a + c.length };
      }
      continue;
    }
    const r = vim.key(k, st);
    if (r) st = { text: r.text, a: r.keepCursor ? st.a : r.a, b: r.keepCursor ? st.b : r.b, save: r.save || st.save };
  }
  return st;
}

// Runs keys on text with the cursor at the "|" (removed); answers the text
// with "|" at the cursor.
function vim(start, keys, v = new Vim()) {
  const a = start.indexOf("|");
  const st = drive(v, { text: start.replace("|", ""), a, b: a }, tokens(keys));
  return st.text.slice(0, st.a) + "|" + st.text.slice(st.a);
}

const cases = [
  // motions
  ["|hello world", "w", "hello |world"],
  ["|hello, world", "w", "hello|, world"],
  ["|hello, world", "W", "hello, |world"],
  ["hello |world", "b", "|hello world"],
  ["|hello world", "e", "hell|o world"],
  ["|hello world", "$", "hello worl|d"],
  ["  hel|lo", "0", "|  hello"],
  ["  hel|lo", "^", "  |hello"],
  ["|one two three", "2w", "one two |three"],
  ["a|bc\ndef\nghi", "j", "abc\nd|ef\nghi"],
  ["abc\nd|ef\nghi", "k", "a|bc\ndef\nghi"],
  ["abcdef|g\nab\nabcdefgh", "jj", "abcdefg\nab\nabcdef|gh"],
  ["one\ntwo\nth|ree", "gg", "|one\ntwo\nthree"],
  ["|one\ntwo\nthree", "G", "one\ntwo\n|three"],
  ["|one\ntwo\nthree", "2G", "one\n|two\nthree"],
  ["|a,b,c", "f,", "a|,b,c"],
  ["|a,b,c", "2f,", "a,b|,c"],
  ["|a,b,c", "t,", "|a,b,c"],
  ["|a,b,c", "f,;", "a,b|,c"],
  ["|abc", "l l", "ab|c"],
  ["|abc", "10l", "ab|c"],
  ["p1\n|p1\n\np2\np2", "}", "p1\np1\n|\np2\np2"],
  // operators
  ["|hello world", "dw", "|world"],
  ["hello |world", "dw", "hello| "],
  ["|hello world", "cwbye<Esc>", "by|e world"],
  ["|hello world", "de", "| world"],
  ["hel|lo world", "d$", "he|l"],
  ["hel|lo world", "D", "he|l"],
  ["hel|lo world", "d0", "|lo world"],
  ["one\ntw|o\nthree", "dd", "one\n|three"],
  ["one\ntwo\nthr|ee", "dd", "one\n|two"],
  ["|one\ntwo\nthree", "2dd", "|three"],
  ["|one\ntwo\nthree", "dj", "|three"],
  ["one\ntwo\n|three", "dk", "|one"],
  ["|abc", "x", "|bc"],
  ["|abc", "2x", "|c"],
  ["ab|c", "x", "a|b"],
  ["a|bc", "X", "|bc"],
  ["say \"he|llo there\" now", "di\"", "say \"|\" now"],
  ["say \"he|llo there\" now", "da\"", "say | now"],
  ["f(a, |b)", "ci(x<Esc>", "f(|x)"],
  ["f(a, |b)", "da(", "|f"],
  ["one tw|o three", "diw", "one | three"],
  ["one tw|o three", "daw", "one |three"],
  ["one tw|o three", "ciwX<Esc>", "one |X three"],
  ["|abc", "rX", "|Xbc"],
  ["|abc", "~~", "AB|c"],
  ["|one\ntwo", "J", "one| two"],
  ["|one\n  two", "J", "one| two"],
  // insert
  ["|abc", "iX<Esc>", "|Xabc"],
  ["|abc", "aX<Esc>", "a|Xbc"],
  ["a|bc", "AX<Esc>", "abc|X"],
  ["  a|bc", "IX<Esc>", "  |Xabc"],
  ["|abc", "oX<Esc>", "abc\n|X"],
  ["|abc", "OX<Esc>", "|X\nabc"],
  ["|abc", "sX<Esc>", "|Xbc"],
  ["a|bc", "SX<Esc>", "|X"],
  ["ab|c def", "CX<Esc>", "ab|X"],
  ["|abc", "ix<CR>y<Esc>", "x\n|yabc"],
  // yank and put
  ["|one two", "yiwP", "on|eone two"],
  ["|one two", "yiw$p", "one twoon|e"],
  ["|one\ntwo", "yyp", "one\n|one\ntwo"],
  ["|one\ntwo", "yyjp", "one\ntwo\n|one"],
  ["one\n|two", "ddP", "|two\none"],
  ["|ab", "xp", "b|a"],
  // visual
  ["|hello world", "vld", "|llo world"],
  ["|hello world", "veyP", "hell|ohello world"],
  ["|one\ntwo\nthree", "Vjd", "|three"],
  ["|hello", "vlcX<Esc>", "|Xllo"],
  ["|hello", "v$~", "|HELLO"],
  // undo, redo, repeat
  ["|abc", "xxu", "|bc"],
  ["|abc", "xxuu", "|abc"],
  ["|abc", "xxuu<C-r>", "|bc"],
  ["|abc", "xuuu", "|abc"],
  ["|a b c d", "dw..", "|d"],
  ["|abc", "iX<Esc>j.", "|XXabc"],
  ["|abc\nabc", "AX<Esc>j.", "abcX\nabc|X"],
  ["|one two three", "cwX<Esc>w.", "X |X three"],
  ["|a\nb", "ddu", "|a\nb"],
  // indent
  ["|a\nb", ">>", "  |a\nb"],
  ["  |a\nb", "<<", "|a\nb"],
  ["|a\nb", ">j", "  |a\n  b"],
  // search and command line
  ["|one two one", "/one<CR>", "one two |one"],
  ["|one two one", "/one<CR>n", "|one two one"],
  ["one two |one", "?two<CR>", "one |two one"],
  ["|a\nb\nc", ":3<CR>", "a\nb\n|c"],
  // surrogate pairs
  ["|😀b", "l", "😀|b"],
  ["😀|b", "h", "|😀b"],
  ["|😀b", "x", "|b"],
];
for (const [start, keys, want] of cases) {
  let got;
  try {
    got = vim(start, keys);
  } catch (e) {
    got = "threw " + e.message;
  }
  check(JSON.stringify(start) + " " + keys, got === want, "got " + JSON.stringify(got) + " want " + JSON.stringify(want));
}

// :w asks to save.
{
  const v = new Vim();
  const st = drive(v, { text: "abc", a: 0, b: 0 }, tokens(":w<CR>"));
  check(":w saves", st.save === true && st.text === "abc");
}

// Random sequences.
const seed = Number(process.argv[2] || 1);
let s = seed >>> 0 || 1;
const rnd = (n) => {
  s ^= s << 13;
  s ^= s >>> 17;
  s ^= s << 5;
  return (s >>> 0) % n;
};
const KEYS = "hjklwbeWBE0^$GggxXdDcCyYpPrJ~ioaAIOvV.u<C-r>}{fFtT;,iw\"()aw23<Esc><Esc>>< ".match(/<[^>]+>|./gu);
const WORDS = ["one", "two", "(x)", "\"q\"", "😀", "  ", "\n", "\n\n", "a-b", "_z"];
let bad = 0;
for (let round = 0; round < Number(process.env.ROUNDS ?? 3000) && bad < 5; round++) {
  const v = new Vim();
  let text = "";
  for (let j = rnd(12); j > 0; j--) text += WORDS[rnd(WORDS.length)] + (rnd(3) ? " " : "");
  const start = text;
  let st = { text, a: 0, b: 0 };
  const seq = [];
  let ok = true;
  for (let j = 0; j < 40 && ok; j++) {
    const k = KEYS[rnd(KEYS.length)];
    seq.push(k);
    try {
      st = drive(v, st, [k]);
    } catch (e) {
      ok = false;
      console.log("threw", e.message, JSON.stringify(start), seq.join(""));
    }
    if (ok && !(st.a >= 0 && st.b >= st.a && st.b <= st.text.length)) {
      ok = false;
      console.log("cursor out of text", JSON.stringify(st), seq.join(""));
    }
  }
  if (ok) {
    // Undo everything: back to the start (from insert mode, Esc first).
    st = drive(v, st, ["Escape", "Escape"]);
    const end = st.text;
    const n = v.undos.length;
    st = drive(v, st, Array(n + 1).fill("u"));
    if (st.text !== start) {
      ok = false;
      console.log("undo all", JSON.stringify(start), "->", JSON.stringify(st.text), seq.join(""));
    } else {
      // Exactly the changes undone (any undone before stay undone).
      st = drive(v, st, Array(n).fill("C-r"));
      if (st.text !== end) {
        ok = false;
        console.log("redo all", JSON.stringify(end), "->", JSON.stringify(st.text), seq.join(""));
      }
    }
  }
  if (!ok) bad++;
}
check("random key sequences: cursor in the text, undo and redo exact", bad === 0, bad + " bad");

console.log(`\n${fails} failure(s)`);
process.exit(fails ? 1 : 0);
