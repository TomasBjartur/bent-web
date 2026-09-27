// src/web/visual.js split(): the blocks and separators tile the text
// exactly, and no block is empty, for random texts. (split is extracted:
// visual.js imports the Bend renderer, which Node cannot load directly.)
// usage: node tests/visual_split_test.mjs
globalThis.document = undefined;
const src = (await import("node:fs")).readFileSync("/home/claude/web/src/web/visual.js", "utf8");
const body = src.slice(src.indexOf("export function split"), src.indexOf("function render(md)"));
const split = new Function(body.replace("export function split", "return function split") )();
let s = 7; const r = (n) => ((s = (s * 1103515245 + 12345) >>> 0) % n);
const parts = ["a", "b c", "\n", "\n\n", "   ", "```", "## h", "- x", "\t"];
let bad = 0;
for (let k = 0; k < 20000; k++) {
  let t = ""; for (let j = r(12); j > 0; j--) t += parts[r(parts.length)];
  const { prefix, blocks } = split(t);
  const back = prefix + blocks.map((b) => b.md + b.sep).join("");
  if (back !== t || blocks.some((b) => b.md === "")) { bad++; if (bad < 3) console.log(JSON.stringify(t), JSON.stringify(blocks)); }
}
console.log(bad ? `FAIL split: ${bad} bad` : "PASS split tiles 20000 random texts");
process.exit(bad ? 1 : 0);
