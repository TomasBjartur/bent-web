// src/web/history.js (the editor's undo): random edits, undos and redos.
// Checks:
//   - every undo (redo) replaces exactly the text its step put there (took
//     away), wherever other edits moved it;
//   - with only this writer's edits: undoing everything gives the text we
//     started with, and redoing everything gives the text before that;
//   - with another writer's edits mixed in (upper case, ours lower case):
//     undo and redo never change their text.
// usage: node tests/history_test.mjs [trials] [seed]
import { History } from "../src/web/history.js";

const TRIALS = Number(process.argv[2] || 3000);
let seed = Number(process.argv[3] || 1);
const rnd = () => ((seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648);
const pick = (n) => Math.floor(rnd() * n);
let fails = 0, checks = 0;
const fail = (msg) => {
  fails++;
  if (fails <= 10) console.log("FAIL " + msg);
};

function word(upper) {
  const a = upper ? "ABC \n" : "abc \n";
  let s = "";
  for (let k = 1 + pick(3); k > 0; k--) s += a[pick(a.length)];
  return s;
}

// Applies ch = {p, del, ins} to text, checking the step's text is there.
function applyStep(text, ch, want, what) {
  checks++;
  if (text.slice(ch.p, ch.p + ch.del) !== want) fail(`${what}: text at ${ch.p} is ${JSON.stringify(text.slice(ch.p, ch.p + ch.del))}, step says ${JSON.stringify(want)}`);
  return text.slice(0, ch.p) + ch.ins + text.slice(ch.p + ch.del);
}

// Undoes everything; answers the text and how many steps were undone.
function undoAll(h, text) {
  let n = 0;
  for (let ch; (ch = h.undo((p, k) => text.slice(p, p + k))); n++) text = applyStep(text, ch, h.redos[h.redos.length - 1].ins, "undo");
  return [text, n];
}

// Redoes n steps (those undoAll undid: the redo list held others before).
function redoN(h, text, n) {
  for (let ch; n > 0 && (ch = h.redo((p, k) => text.slice(p, p + k))); n--) text = applyStep(text, ch, h.undos[h.undos.length - 1].del, "redo");
  return text;
}

const upper = (t) => t.replace(/[^A-Z]/g, "");

for (let trial = 0; trial < TRIALS && fails < 10; trial++) {
  const remoteToo = trial % 2 === 1;
  const h = new History();
  const start = word(false) + word(false);
  let text = start;
  let now = 0;
  const steps = 5 + pick(40);
  for (let k = 0; k < steps; k++) {
    now += rnd() < 0.2 ? 5000 : pick(300);
    const r = rnd();
    if (r < 0.55) {
      // Our edit: typing on, deleting, or replacing somewhere.
      const p = rnd() < 0.5 && h.undos.length ? Math.min(text.length, h.undos[h.undos.length - 1].p + h.undos[h.undos.length - 1].ins.length) : pick(text.length + 1);
      const del = rnd() < 0.3 ? pick(Math.min(4, text.length - p) + 1) : 0;
      const ins = del && rnd() < 0.5 ? "" : word(false);
      if (!del && !ins) continue;
      // Only our own text is ours to delete when others write too.
      if (remoteToo && /[A-Z]/.test(text.slice(p, p + del))) continue;
      const d = text.slice(p, p + del);
      text = text.slice(0, p) + ins + text.slice(p + del);
      h.record(p, d, ins, { a: p, b: p + del }, { a: p + ins.length, b: p + ins.length }, now);
    } else if (r < 0.7) {
      const ch = h.undo((p, n) => text.slice(p, p + n));
      if (ch) text = applyStep(text, ch, h.redos[h.redos.length - 1].ins, "undo");
    } else if (r < 0.8) {
      const ch = h.redo((p, n) => text.slice(p, p + n));
      if (ch) text = applyStep(text, ch, h.undos[h.undos.length - 1].del, "redo");
    } else if (remoteToo) {
      // Another writer inserts (upper case) or deletes their own text.
      const caps = [...text.matchAll(/[A-Z]/g)];
      if (caps.length && rnd() < 0.3) {
        const at = caps[pick(caps.length)].index;
        text = text.slice(0, at) + text.slice(at + 1);
        h.remote(at, 1, 0);
      } else {
        const at = pick(text.length + 1);
        const ins = word(true);
        text = text.slice(0, at) + ins + text.slice(at);
        h.remote(at, 0, ins.length);
      }
    }
  }
  // Undo everything, then redo everything, on a copy.
  const before = text;
  const theirs = upper(text);
  const h2 = new History();
  h2.undos = structuredClone(h.undos);
  h2.redos = structuredClone(h.redos);
  const [undone, count] = undoAll(h2, text);
  checks++;
  if (!remoteToo && undone !== start) fail(`trial ${trial}: undo all gave ${JSON.stringify(undone)}, started with ${JSON.stringify(start)}`);
  if (remoteToo && upper(undone) !== theirs) fail(`trial ${trial}: undo changed another writer's text: ${JSON.stringify(undone)} (theirs ${JSON.stringify(theirs)})`);
  const redone = redoN(h2, undone, count);
  checks++;
  if (!remoteToo && redone !== before) fail(`trial ${trial}: redo all gave ${JSON.stringify(redone)}, want ${JSON.stringify(before)}`);
  if (remoteToo && upper(redone) !== theirs) fail(`trial ${trial}: redo changed another writer's text`);
}

// Precision: another writer only before all our text (a prefix), or only
// after it (a suffix). Every step must survive and undo exactly: undoing
// everything leaves their text and the text we started with. (Their part
// keeps a fixed character next to ours: text restored where a deletion was,
// right where they inserted, could go on either side of theirs.)
for (let trial = 0; trial < TRIALS && fails < 10; trial++) {
  const suffixSide = trial % 2 === 1;
  const h = new History();
  const start = word(false) + word(false);
  let ours = start, theirs = "|";
  let now = 0;
  const whole = () => (suffixSide ? ours + theirs : theirs + ours);
  const base = () => (suffixSide ? 0 : theirs.length); // where our text starts
  for (let k = 5 + pick(40); k > 0; k--) {
    now += rnd() < 0.2 ? 5000 : pick(300);
    const r = rnd();
    const text = whole();
    if (r < 0.5) {
      const p = pick(ours.length + 1), del = rnd() < 0.3 ? pick(Math.min(4, ours.length - p) + 1) : 0;
      const ins = del && rnd() < 0.5 ? "" : word(false);
      if (!del && !ins) continue;
      const d = ours.slice(p, p + del);
      ours = ours.slice(0, p) + ins + ours.slice(p + del);
      h.record(base() + p, d, ins, null, null, now);
    } else if (r < 0.65 || r < 0.75) {
      const ch = r < 0.65 ? h.undo((p, n) => text.slice(p, p + n)) : h.redo((p, n) => text.slice(p, p + n));
      if (ch) {
        const t2 = text.slice(0, ch.p) + ch.ins + text.slice(ch.p + ch.del);
        ours = suffixSide ? t2.slice(0, t2.length - theirs.length) : t2.slice(theirs.length);
      }
    } else {
      // Theirs: insert or delete within their part, away from ours.
      const fixed = suffixSide ? 0 : theirs.length - 1;
      const at = suffixSide ? 1 + pick(theirs.length) : pick(theirs.length);
      if (theirs.length > 1 && rnd() < 0.3) {
        let q = pick(theirs.length);
        if (q === fixed) q = suffixSide ? 1 : 0;
        if (q >= theirs.length || q === fixed) continue;
        theirs = theirs.slice(0, q) + theirs.slice(q + 1);
        h.remote((suffixSide ? ours.length : 0) + q, 1, 0);
      } else {
        const ins = word(true);
        theirs = theirs.slice(0, at) + ins + theirs.slice(at);
        h.remote((suffixSide ? ours.length : 0) + at, 0, ins.length);
      }
    }
  }
  const [undone] = undoAll(h, whole());
  checks++;
  const want = suffixSide ? start + theirs : theirs + start;
  if (undone !== want) fail(`precision trial ${trial} (${suffixSide ? "suffix" : "prefix"}): undo all gave ${JSON.stringify(undone)}, want ${JSON.stringify(want)}`);
}

// Stale steps alone (no check of the text before undoing) keep another
// writer's text: they write inside our steps' text too.
for (let trial = 0; trial < TRIALS && fails < 10; trial++) {
  const h = new History();
  let text = word(false) + word(false);
  let now = 0;
  for (let k = 5 + pick(30); k > 0; k--) {
    now += pick(3000);
    if (rnd() < 0.6) {
      const p = pick(text.length + 1), del = rnd() < 0.3 ? pick(Math.min(4, text.length - p) + 1) : 0;
      const ins = del && rnd() < 0.5 ? "" : word(false);
      if ((!del && !ins) || /[A-Z]/.test(text.slice(p, p + del))) continue;
      const d = text.slice(p, p + del);
      text = text.slice(0, p) + ins + text.slice(p + del);
      h.record(p, d, ins, null, null, now);
    } else {
      const at = pick(text.length + 1);
      const ins = word(true);
      text = text.slice(0, at) + ins + text.slice(at);
      h.remote(at, 0, ins.length);
    }
  }
  const theirs = upper(text);
  for (let ch; (ch = h.undo(null)); ) text = text.slice(0, ch.p) + ch.ins + text.slice(ch.p + ch.del);
  checks++;
  if (upper(text) !== theirs) fail(`stale trial ${trial}: undo (trusting the steps) changed another writer's text: ${JSON.stringify(text)} (theirs ${JSON.stringify(theirs)})`);
}

// Typing merges a word at a time; a pause or a new word starts a new step.
{
  const h = new History();
  let t = 0;
  const type = (p, s) => h.record(p, "", s, null, null, (t += 100));
  type(0, "h");
  type(1, "i");
  type(2, " ");
  type(3, "y");
  checks++;
  if (h.undos.length !== 2 || h.undos[0].ins !== "hi" || h.undos[1].ins !== " y") fail("typing merges by words (a word with the space before it): " + JSON.stringify(h.undos.map((s) => s.ins)));
  t += 5000;
  type(4, "o");
  checks++;
  if (h.undos.length !== 3) fail("a pause starts a new step");
}

// Typing over a selection, then on: one step. A composition (updates
// rewriting its own text): one step.
{
  const h = new History();
  let text = "Hello there";
  const rec = (p, del, ins, t, group = false) => {
    const d = text.slice(p, p + del);
    text = text.slice(0, p) + ins + text.slice(p + del);
    h.record(p, d, ins, null, null, t, group);
  };
  rec(6, 5, "w", 100);
  rec(7, 0, "o", 200);
  rec(8, 0, "rld", 300);
  const at = (p, n) => text.slice(p, p + n);
  let ch = h.undo(at);
  text = text.slice(0, ch.p) + ch.ins + text.slice(ch.p + ch.del);
  checks++;
  if (text !== "Hello there") fail("typing over a selection undoes in one step: " + JSON.stringify(text));
  const g = new History();
  text = "Tokyo: ";
  const rec2 = (p, del, ins, t, group) => {
    const d = text.slice(p, p + del);
    text = text.slice(0, p) + ins + text.slice(p + del);
    g.record(p, d, ins, null, null, t, group);
  };
  rec2(7, 0, "と", 5000, 1);
  rec2(7, 1, "とう", 5100, 1);
  rec2(7, 2, "とうきょう", 5200, 1);
  rec2(7, 5, "東京", 5300, 1);
  rec2(9, 0, "駅", 5400, 2);
  ch = g.undo((p, n) => text.slice(p, p + n));
  text = text.slice(0, ch.p) + ch.ins + text.slice(ch.p + ch.del);
  checks++;
  if (text !== "Tokyo: 東京") fail("two compositions are two steps: " + JSON.stringify(text));
  ch = g.undo((p, n) => text.slice(p, p + n));
  text = text.slice(0, ch.p) + ch.ins + text.slice(ch.p + ch.del);
  checks++;
  if (text !== "Tokyo: ") fail("a composition undoes in one step: " + JSON.stringify(text));
}

console.log(`${checks} checks, ${fails} failure(s)`);
process.exit(fails ? 1 : 0);
