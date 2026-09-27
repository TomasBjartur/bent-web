// The editor's Visual (WYSIWYG) mode. The Markdown text stays the document
// (the textarea, bound to the CRDT); this mode shows it rendered and turns
// edits back into Markdown:
//
// - The text is cut into blocks (runs of lines between blank lines; a
//   fenced code block is one block). Each block is rendered by the proved
//   renderer (src/markdown.bend, compiled to JS: src/web/md.bend), so what
//   you see is what the server will publish, and the HTML put on the page
//   is provably allowed markup (spec/markup.bend). Pasted HTML is never
//   inserted: pastes are plain text.
// - An edit re-serializes only the blocks it touched (to the Markdown
//   subset the renderer reads); the other blocks keep their exact source,
//   so an edit is a small, local change to the text, as typing is.
// - Remote changes re-render only the blocks whose source changed.
//
// Tested in real Chrome (tests/browser_test.py: render -> serialize ->
// render gives the same HTML for random documents; typing and the toolbar
// change the text as expected).
import Md from "./md.bend";

const BLOCK_MAX = 6000;       // longer blocks are shown read-only (the renderer's JS recursion)
export const VISUAL_MAX = 300000; // longer documents stay in Markdown mode

// The text as prefix + blocks, each {md, sep}: text = prefix + md0 + sep0
// + md1 + sep1 ... A block is a run of non-blank lines, or a fenced code
// block (blank lines and all); sep is what follows it up to the next block
// (line breaks and blank lines). Exact by construction: every part is a
// slice of the text, and the slices tile it.
export function split(text) {
  const lines = [];
  for (let s = 0; ; ) {
    const e = text.indexOf("\n", s);
    if (e < 0) {
      lines.push({ s, e: text.length });
      break;
    }
    lines.push({ s, e });
    s = e + 1;
  }
  const n = lines.length;
  const line = (k) => text.slice(lines[k].s, lines[k].e);
  const blank = (k) => line(k).trim() === "";
  const fence = (k) => /^```/.test(line(k));
  let i = 0;
  while (i < n && blank(i)) i++;
  const prefix = text.slice(0, i < n ? lines[i].s : text.length);
  const blocks = [];
  while (i < n) {
    const start = i;
    if (fence(i)) {
      i++;
      while (i < n && !fence(i)) i++;
      if (i < n) i++;
    } else {
      while (i < n && !blank(i) && !(i > start && fence(i))) i++;
    }
    const s0 = lines[start].s, e0 = lines[i - 1].e;
    while (i < n && blank(i)) i++;
    const next = i < n ? lines[i].s : text.length;
    blocks.push({ md: text.slice(s0, e0), sep: text.slice(e0, next) });
  }
  return { prefix, blocks };
}

function render(md) {
  if (md.length > BLOCK_MAX) return null;
  try {
    return Md.html_of(md);
  } catch (e) {
    return null;
  }
}

// MARKDOWN FROM THE EDITED HTML: the subset src/markdown.bend reads.
const esc = (s) => s.replace(/[\\*_`[\]]/g, "\\$&");
// A paragraph line that would start a block is escaped.
const escStart = (s) => s.replace(/^(\s*)([#>+-]|\d+\.|```)/, "$1\\$2");

function inline(node) {
  let out = "";
  for (const n of node.childNodes) {
    if (n.nodeType === 3) {
      out += esc(n.nodeValue.replace(/ /g, " "));
      continue;
    }
    if (n.nodeType !== 1) continue;
    const tag = n.tagName;
    if (tag === "BR") out += "\n";
    else if (tag === "STRONG" || tag === "B") out += wrap("**", inline(n));
    else if (tag === "EM" || tag === "I") out += wrap("*", inline(n));
    else if (tag === "CODE") {
      const c = n.textContent.replace(/`/g, "'").replace(/\n/g, " ");
      out += c ? "`" + c + "`" : "";
    } else if (tag === "A") {
      const href = n.getAttribute("href") || "";
      const text = inline(n);
      out += /^(https?:\/\/|\/)[^\s()<>"]*$/.test(href) && text ? "[" + text + "](" + href + ")" : text;
    } else if (tag === "IMG") {
      const src = n.getAttribute("src") || "";
      if (/^\/img\/[0-9a-f]{32}$/.test(src)) out += "![" + (n.getAttribute("alt") || "").replace(/[[\]\n]/g, " ") + "](" + src + ")";
    } else out += inline(n);
  }
  return out;
}

// Emphasis around text: the markers go inside any spaces at the ends.
function wrap(m, s) {
  const lead = s.match(/^\s*/)[0], trail = s.match(/\s*$/)[0];
  const core = s.slice(lead.length, s.length - trail.length);
  return core ? lead + m + core + m + trail : s;
}

const para = (s) =>
  s.split("\n").map((l) => escStart(l.trim())).filter((l) => l !== "").join("\n");

function blocksOf(el) {
  const out = [];
  let run = null; // inline content directly in el, gathered into a paragraph
  const flush = () => {
    if (run !== null) {
      const p = para(run);
      if (p) out.push(p);
      run = null;
    }
  };
  for (const n of el.childNodes) {
    const tag = n.nodeType === 1 ? n.tagName : "";
    if (n.nodeType === 3 || ["STRONG", "B", "EM", "I", "CODE", "A", "IMG", "SPAN", "BR", "FONT", "U", "S"].includes(tag)) {
      const frag = document.createElement("span");
      frag.appendChild(n.cloneNode(true));
      run = (run || "") + inline(frag);
      continue;
    }
    flush();
    if (n.nodeType !== 1) continue;
    if (tag === "P" || tag === "DIV") out.push(...blocksOf(n));
    else if (tag === "H1" || tag === "H2") {
      const s = inline(n).replace(/\n/g, " ").trim();
      if (s) out.push("## " + s);
    } else if (/^H[3-6]$/.test(tag)) {
      const s = inline(n).replace(/\n/g, " ").trim();
      if (s) out.push("### " + s);
    } else if (tag === "UL" || tag === "OL") {
      const items = [];
      for (const li of n.querySelectorAll(":scope > li")) {
        const s = inline(li).replace(/\n/g, " ").trim();
        if (s) items.push((tag === "OL" ? items.length + 1 + ". " : "- ") + s);
      }
      if (items.length) out.push(items.join("\n"));
    } else if (tag === "BLOCKQUOTE") {
      const inner = blocksOf(n).join("\n\n");
      if (inner) out.push(inner.split("\n").map((l) => "> " + l).join("\n"));
    } else if (tag === "PRE") {
      out.push("```\n" + n.innerText.replace(/\n$/, "").replace(/^```/gm, "'''") + "\n```");
    } else if (tag === "HR") {
      continue;
    } else out.push(...blocksOf(n));
  }
  flush();
  return out;
}

// A block element's Markdown.
export function serialize(el) {
  return blocksOf(el).join("\n\n");
}

export class Visual {
  // text: the Markdown; onChange(text): an edit made here.
  constructor(root, onChange) {
    this.root = root;
    this.onChange = onChange;
    this.prefix = "";
    this.dirty = new Set();
    this.observer = new MutationObserver((recs) => this.collect(recs));
    root.addEventListener("input", () => this.commit());
    root.addEventListener("paste", (ev) => {
      const files = [...(ev.clipboardData ? ev.clipboardData.files : [])].filter((f) => f.type.startsWith("image/"));
      if (files.length) return; // images: the editor uploads them (see editor.js)
      ev.preventDefault();
      const t = ev.clipboardData ? ev.clipboardData.getData("text/plain") : "";
      if (t) document.execCommand("insertText", false, t);
    });
  }

  // The blocks mutations touched (and blocks added at the top level).
  collect(recs) {
    for (const r of recs) {
      if (r.target === this.root) for (const a of r.addedNodes) this.dirty.add(a);
      const b = blockOf(this.root, r.target);
      if (b) this.dirty.add(b);
    }
  }

  open(text) {
    document.execCommand("defaultParagraphSeparator", false, "p");
    this.show(split(text));
    this.observer.observe(this.root, { childList: true, subtree: true, characterData: true });
  }

  close() {
    this.observer.disconnect();
    this.root.replaceChildren();
  }

  block(b) {
    const el = document.createElement("div");
    el.className = "wblock";
    const html = render(b.md);
    if (html === null) {
      // Too long for this mode: shown as text, edited in Markdown mode.
      el.contentEditable = "false";
      el.className = "wblock wraw";
      el.textContent = b.md;
      el.title = "A long block: edit it in Markdown mode";
    } else el.innerHTML = html; // allowed markup only (spec/markup.bend)
    el.md = b.md;
    el.sep = b.sep;
    return el;
  }

  show({ prefix, blocks }) {
    this.prefix = prefix;
    const els = blocks.map((b) => this.block(b));
    // An empty document: one empty paragraph to type in.
    if (!els.length || (els.length === 1 && !blocks[0].md)) {
      const el = document.createElement("div");
      el.className = "wblock";
      el.innerHTML = "<p><br></p>";
      el.md = "";
      el.sep = "";
      els.splice(0, els.length, el);
    }
    this.root.replaceChildren(...els);
    this.dirty.clear();
  }

  // An edit: the touched blocks become Markdown again.
  commit() {
    this.collect(this.observer.takeRecords());
    // Content typed straight into the root (all blocks deleted) gets a block.
    for (const n of [...this.root.childNodes]) {
      if (n.nodeType === 1 && n.classList.contains("wblock")) continue;
      if (n.nodeType === 3 && !n.nodeValue.trim()) {
        n.remove();
        continue;
      }
      const el = document.createElement("div");
      el.className = "wblock";
      this.root.insertBefore(el, n);
      el.appendChild(n);
      this.dirty.add(el);
    }
    this.observer.takeRecords();
    for (const el of this.dirty) {
      if (el.parentNode !== this.root || el.classList.contains("wraw")) continue;
      el.md = serialize(el);
    }
    this.dirty.clear();
    this.onChange(this.text());
  }

  // The text as the blocks now say: empty blocks leave no text (the page
  // keeps them: the caret may be there), and a block followed by another
  // is separated by a blank line whatever it was before.
  text() {
    const kids = [...this.root.children].filter((el) => el.md);
    let t = this.prefix;
    kids.forEach((el, i) => {
      let sep = el.sep ?? "";
      if (i < kids.length - 1 && !/\n[ \t]*\n/.test(sep)) sep = "\n\n";
      t += el.md + sep;
    });
    return t;
  }

  // The text changed elsewhere (another writer): re-render what differs.
  refresh(text) {
    if (text === this.text()) return;
    const next = split(text);
    const olds = [...this.root.children];
    let a = 0;
    while (a < olds.length && a < next.blocks.length && olds[a].md === next.blocks[a].md) a++;
    let z = 0;
    while (z < olds.length - a && z < next.blocks.length - a && olds[olds.length - 1 - z].md === next.blocks[next.blocks.length - 1 - z].md) z++;
    const sel = document.getSelection();
    const focusBlock = sel && sel.anchorNode && this.root.contains(sel.anchorNode) ? blockOf(this.root, sel.anchorNode) : null;
    const focusAt = focusBlock ? offsetIn(focusBlock, sel.anchorNode, sel.anchorOffset) : 0;
    const focusIndex = focusBlock ? olds.indexOf(focusBlock) : -1;
    const fresh = next.blocks.slice(a, next.blocks.length - z).map((b) => this.block(b));
    const after = olds[olds.length - z] || null;
    for (const el of olds.slice(a, olds.length - z)) el.remove();
    for (const el of fresh) this.root.insertBefore(el, after);
    this.prefix = next.prefix;
    [...this.root.children].forEach((el, i) => (el.sep = next.blocks[i].sep));
    if (focusIndex >= a && focusIndex < olds.length - z && fresh.length) {
      const el = fresh[Math.min(focusIndex - a, fresh.length - 1)];
      placeCaret(el, focusAt);
    }
    this.dirty.clear();
    this.observer.takeRecords();
  }
}

function blockOf(root, n) {
  while (n && n.parentNode !== root) n = n.parentNode;
  return n;
}

function offsetIn(el, node, off) {
  const r = document.createRange();
  r.setStart(el, 0);
  try {
    r.setEnd(node, off);
  } catch (e) {
    return 0;
  }
  return r.toString().length;
}

function placeCaret(el, at) {
  const w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
  let n, left = at;
  while ((n = w.nextNode())) {
    if (left <= n.nodeValue.length) {
      document.getSelection().collapse(n, left);
      return;
    }
    left -= n.nodeValue.length;
  }
  document.getSelection().collapse(el, el.childNodes.length);
}
