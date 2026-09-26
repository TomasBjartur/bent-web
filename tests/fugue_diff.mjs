// Differential fuzzing: src/web/fugue.js (the browser's fast CRDT) and
// src/c/fugue_core.h (the server's materializer, as build/c/fugue_cli)
// against src/crdt.bend (the reference whose merge laws are proved),
// compiled natively as build/crdt_ref. Random multi-replica histories with random,
// reordered, partial delivery. Checks, per trial:
//   - after full delivery, every JS replica has the same text;
//   - that text equals the reference's text for the union of all ops;
//   - mid-run, each replica's text equals the reference's text for exactly
//     the ops it has applied (out-of-order arrival, orphans, early deletes).
// usage: node tests/fugue_diff.mjs [trials] [seed]
import { execFileSync } from "node:child_process";
import { writeFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Doc } from "../src/web/fugue.js";

const TRIALS = Number(process.argv[2] || 200);
let seed = Number(process.argv[3] || 1);
const rnd = () => ((seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648);
const pick = (n) => Math.floor(rnd() * n);
const dir = mkdtempSync(join(tmpdir(), "fugue-"));
const REF = new URL("../build/crdt_ref", import.meta.url).pathname;
const CMAT = new URL("../build/c/fugue_cli", import.meta.url).pathname;

function run(bin, ops) {
  const f = join(dir, "ops.txt");
  writeFileSync(f, Doc.encode(ops));
  const out = execFileSync(bin, [f], { encoding: "utf8", maxBuffer: 1 << 26 });
  const m = out.match(/<<TEXT>>([\s\S]*)<<END>>/);
  if (!m) throw new Error(bin + ": " + out.slice(0, 200));
  return m[1];
}

// The Bend reference; the C materializer (the server's) must agree with it.
function reference(ops) {
  const want = run(REF, ops);
  const c = run(CMAT, ops);
  if (c !== want) {
    failures++;
    console.log(`FAIL C materializer: c ${JSON.stringify(c)} ref ${JSON.stringify(want)}\n  ops ${Doc.encode(ops)}`);
  }
  return want;
}

const ALPHABET = ["a", "b", "c", "x", "y", "\n", "é", "😀"];
let failures = 0, checks = 0;

for (let trial = 0; trial < TRIALS && failures < 5; trial++) {
  const R = 2 + pick(3);
  const reps = Array.from({ length: R }, (_, i) => ({ doc: new Doc(), rep: i + 2, applied: [], inbox: [] }));
  const all = [];
  const steps = 5 + pick(30);
  for (let s = 0; s < steps; s++) {
    const r = reps[pick(R)];
    const len = Array.from(r.doc.text()).length;
    const pos = pick(len + 1);
    const del = rnd() < 0.3 ? pick(Math.min(3, len - pos) + 1) : 0;
    let ins = "";
    for (let k = pick(4); k > 0; k--) ins += ALPHABET[pick(ALPHABET.length)];
    const ops = r.doc.edit(r.rep, pos, del, ins);
    r.applied.push(...ops);
    all.push(...ops);
    for (const o of reps) if (o !== r) o.inbox.push(...ops);
    // Random partial, reordered delivery to one replica.
    const q = reps[pick(R)];
    if (q.inbox.length) {
      const n = 1 + pick(q.inbox.length);
      const batch = [];
      for (let k = 0; k < n; k++) batch.push(q.inbox.splice(pick(q.inbox.length), 1)[0]);
      // Deliver one by one or as a batch (exercises both code paths).
      if (rnd() < 0.5) for (const op of batch) q.doc.apply(op);
      else q.doc.applyAll(batch.length > 32 ? batch : batch.concat(Array(33).fill(batch[0])));
      q.applied.push(...batch);
      checks++;
      const want = reference(q.applied);
      if (q.doc.text() !== want) {
        failures++;
        console.log(`FAIL trial ${trial} mid-run: js ${JSON.stringify(q.doc.text())} ref ${JSON.stringify(want)}\n  ops ${Doc.encode(q.applied)}`);
      }
    }
  }
  for (const q of reps) {
    while (q.inbox.length) {
      const op = q.inbox.splice(pick(q.inbox.length), 1)[0];
      q.doc.apply(op);
      q.applied.push(op);
    }
  }
  const texts = reps.map((q) => q.doc.text());
  const want = reference(all);
  checks++;
  if (!texts.every((t) => t === want)) {
    failures++;
    console.log(`FAIL trial ${trial} final: js ${JSON.stringify(texts)} ref ${JSON.stringify(want)}\n  ops ${Doc.encode(all)}`);
  }
}
console.log(`${checks} checks, ${failures} failure(s)`);
process.exit(failures ? 1 : 0);
