// Differential fuzzing: src/web/fugue.js (the browser's fast CRDT) and
// src/c/fugue_core.h (the server's materializer, as build/c/fugue_cli)
// against src/crdt.bend (the reference whose merge laws are proved),
// compiled natively as build/crdt_ref. Random multi-replica histories with random,
// reordered, partial delivery. Checks, per trial:
//   - after full delivery, every JS replica has the same text;
//   - that text equals the reference's text for the union of all ops;
//   - mid-run, each replica's text equals the reference's text for exactly
//     the ops it has applied (out-of-order arrival, orphans, early deletes);
//   - the changes a replica reports while applying (what the editor's view
//     follows) turn its previous text into its new text, exactly;
//   - a local edit changes the text exactly as the string splice would
//     (positions in UTF-16 units, never inside a surrogate pair).
// Deliveries go one operation at a time or as one batch padded past the
// batch threshold (the order is then rebuilt in one pass): both paths.
// usage: node tests/fugue_diff.mjs [trials] [seed]
import { execFileSync } from "node:child_process";
import { writeFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Doc, Ops } from "../src/web/fugue.js";

const TRIALS = Number(process.argv[2] || 200);
let seed = Number(process.argv[3] || 1);
const rnd = () => ((seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648);
const pick = (n) => Math.floor(rnd() * n);
const dir = mkdtempSync(join(tmpdir(), "fugue-"));
const REF = new URL("../build/crdt_ref", import.meta.url).pathname;
const CMAT = new URL("../build/c/fugue_cli", import.meta.url).pathname;

function run(bin, ops) {
  const f = join(dir, "ops.txt");
  writeFileSync(f, Ops.fromArrays(ops).encode());
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
    console.log(`FAIL C materializer: c ${JSON.stringify(c)} ref ${JSON.stringify(want)}\n  ops ${Ops.fromArrays(ops).encode()}`);
  }
  return want;
}

const ALPHABET = ["a", "b", "c", "x", "y", "\n", "é", "😀"];
let failures = 0, checks = 0;

for (let trial = 0; trial < TRIALS && failures < 5; trial++) {
  const R = 2 + pick(3);
  // Tiny order blocks split all the time (the default, 512, rarely in a test).
  const B = [2, 3, 4, 8, 512][pick(5)];
  const reps = Array.from({ length: R }, (_, i) => ({ doc: new Doc(B), rep: i + 2, applied: [], inbox: [] }));
  const all = [];
  const steps = 5 + pick(30);
  for (let s = 0; s < steps; s++) {
    const r = reps[pick(R)];
    const before = r.doc.text();
    const cps = Array.from(before);
    const cp = pick(cps.length + 1);
    const cdel = rnd() < 0.3 ? pick(Math.min(3, cps.length - cp) + 1) : 0;
    let ins = "";
    for (let k = rnd() < 0.1 ? pick(40) : pick(4); k > 0; k--) ins += ALPHABET[pick(ALPHABET.length)];
    // UTF-16 positions, as the editor gives them.
    const pos = cps.slice(0, cp).join("").length;
    const del = cps.slice(cp, cp + cdel).join("").length;
    const ops = r.doc.edit(r.rep, pos, del, ins).toArrays();
    checks++;
    const spliced = before.slice(0, pos) + ins + before.slice(pos + del);
    if (r.doc.text() !== spliced) {
      failures++;
      console.log(`FAIL trial ${trial} local edit: got ${JSON.stringify(r.doc.text())} want ${JSON.stringify(spliced)}`);
    }
    r.applied.push(...ops);
    all.push(...ops);
    for (const o of reps) if (o !== r) o.inbox.push(...ops);
    // Random partial, reordered delivery to one replica.
    const q = reps[pick(R)];
    if (q.inbox.length) {
      const n = 1 + pick(q.inbox.length);
      const batch = [];
      for (let k = 0; k < n; k++) batch.push(q.inbox.splice(pick(q.inbox.length), 1)[0]);
      const how = rnd();
      if (how < 0.33) {
        // As one small batch (placed op by op; adjacent changes reported
        // joined, in any order the ops come).
        let mirror = q.doc.text();
        const got = q.doc.apply(Ops.fromArrays(batch.length < 256 ? batch : batch.slice(0, 255)), (p, d, t) => {
          mirror = mirror.slice(0, p) + t + mirror.slice(p + d);
        });
        if (batch.length >= 256) q.doc.apply(Ops.fromArrays(batch.slice(255)));
        checks++;
        if (got === 1 && batch.length < 256 && mirror !== q.doc.text()) {
          failures++;
          console.log(`FAIL trial ${trial} reported changes (small batch): ${JSON.stringify(mirror)} vs ${JSON.stringify(q.doc.text())}`);
        }
      } else if (how < 0.66) {
        // One at a time: every change reported must match the text.
        for (const op of batch) {
          let mirror = q.doc.text();
          const got = q.doc.apply(Ops.fromArrays([op]), (p, d, t) => {
            mirror = mirror.slice(0, p) + t + mirror.slice(p + d);
          });
          checks++;
          if (got !== 2 && mirror !== q.doc.text()) {
            failures++;
            console.log(`FAIL trial ${trial} reported changes: ${JSON.stringify(mirror)} vs ${JSON.stringify(q.doc.text())}`);
          }
        }
      } else {
        // As one batch, padded with duplicates past the batch threshold.
        const padded = batch.length >= 256 ? batch : batch.concat(Array(256).fill(batch[0]));
        let mirror = q.doc.text();
        const got = q.doc.apply(Ops.fromArrays(padded), (p, d, t) => {
          mirror = mirror.slice(0, p) + t + mirror.slice(p + d);
        });
        checks++;
        if (got === 1 && mirror !== q.doc.text()) {
          failures++;
          console.log(`FAIL trial ${trial} reported changes (batch): ${JSON.stringify(mirror)} vs ${JSON.stringify(q.doc.text())}`);
        }
      }
      q.applied.push(...batch);
      checks++;
      const want = reference(q.applied);
      if (q.doc.text() !== want) {
        failures++;
        console.log(`FAIL trial ${trial} mid-run: js ${JSON.stringify(q.doc.text())} ref ${JSON.stringify(want)}\n  ops ${Ops.fromArrays(q.applied).encode()}`);
      }
    }
  }
  for (const q of reps) {
    while (q.inbox.length) {
      const op = q.inbox.splice(pick(q.inbox.length), 1)[0];
      q.doc.apply(Ops.fromArrays([op]));
      q.applied.push(op);
    }
  }
  const texts = reps.map((q) => q.doc.text());
  const want = reference(all);
  checks++;
  if (!texts.every((t) => t === want)) {
    failures++;
    console.log(`FAIL trial ${trial} final: js ${JSON.stringify(texts)} ref ${JSON.stringify(want)}\n  ops ${Ops.fromArrays(all).encode()}`);
  }
}
console.log(`${checks} checks, ${failures} failure(s)`);
process.exit(failures ? 1 : 0);
