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
export const VISUAL_MAX = 8000000; // (every post the server takes)
// Blocks are rendered when they come this near the screen (the renderer
// takes ~3 ms a KB: a novel at once would take seconds); until then each
// shows its Markdown as plain text, not editable, and far-off ones are
// skipped by the browser (content-visibility). The first and last EAGER
// blocks are rendered at once (Ctrl+Home and Ctrl+End land in them).
const AHEAD = "2000px";
const EAGER = 8;

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
    this.seen = new IntersectionObserver((es) => {
      for (const e of es) if (e.isIntersecting) this.draw(e.target);
    }, { rootMargin: AHEAD + " 0px" });
    // Before the browser types into an emptied view, there is a paragraph.
    root.addEventListener("beforeinput", () => this.ensure());
    root.addEventListener("input", (ev) => {
      if (!this.shortcut(ev)) this.commit();
    });
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
    this.seen.disconnect();
    this.root.replaceChildren();
  }

  // A block, not rendered yet (see AHEAD).
  block(b) {
    const el = document.createElement("div");
    el.className = "wblock wlazy";
    el.contentEditable = "false";
    el.textContent = b.md;
    el.md = b.md;
    el.sep = b.sep;
    this.seen.observe(el);
    return el;
  }

  // Renders a block (its Markdown is kept: rendering is not an edit).
  draw(el) {
    if (!el.classList.contains("wlazy")) return;
    this.seen.unobserve(el);
    const others = this.observer.takeRecords();
    const html = render(el.md);
    el.classList.remove("wlazy");
    if (html === null) {
      // Too long for this mode: shown as text, edited in Markdown mode.
      el.classList.add("wraw");
      el.title = "A long block: edit it in Markdown mode";
    } else {
      el.innerHTML = html; // allowed markup only (spec/markup.bend)
      el.removeAttribute("contenteditable");
    }
    this.observer.takeRecords();
    this.collect(others);
  }

  show({ prefix, blocks }) {
    this.prefix = prefix;
    this.tail = blocks.length ? blocks[blocks.length - 1].sep : "";
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
    for (let i = 0; i < els.length; i++) if (i < EAGER || i >= els.length - EAGER) this.draw(els[i]);
    this.observer.takeRecords();
    this.dirty.clear();
  }

  // Markdown shortcuts: "## ", "### ", "- ", "1. " or "> " typed at the
  // start of a paragraph make it a heading, a list or a quote. Answers
  // whether it did (the edits it makes are committed as they happen).
  shortcut(ev) {
    if (ev.inputType !== "insertText" || ev.data !== " ") return false;
    const sel = document.getSelection();
    if (!sel || !sel.isCollapsed || !this.root.contains(sel.anchorNode)) return false;
    let block = sel.anchorNode.nodeType === 1 ? sel.anchorNode : sel.anchorNode.parentNode;
    while (block && block !== this.root && !/^(P|DIV)$/.test(block.tagName)) block = block.parentNode;
    if (!block || block === this.root || block.classList.contains("wblock") && block.querySelector("p,h2,h3,ul,ol,blockquote,pre")) return false;
    const before = offsetIn(block, sel.anchorNode, sel.anchorOffset);
    const m = block.textContent.slice(0, before).match(/^(#{1,3}|[-*+]|1[.)]|>)[ \u00a0]$/);
    if (!m) return false;
    const r = document.createRange();
    r.setStart(block, 0);
    r.setEnd(sel.anchorNode, sel.anchorOffset);
    sel.removeAllRanges();
    sel.addRange(r);
    document.execCommand("delete");
    const k = m[1];
    if (k === "###") document.execCommand("formatBlock", false, "h3");
    else if (k[0] === "#") document.execCommand("formatBlock", false, "h2");
    else if (k === ">") document.execCommand("formatBlock", false, "blockquote");
    else if (k[0] === "1") document.execCommand("insertOrderedList");
    else document.execCommand("insertUnorderedList");
    this.commit();
    return true;
  }

  // An edit: the touched blocks become Markdown again.
  commit() {
    this.collect(this.observer.takeRecords());
    this.gather();
    this.observer.takeRecords();
    for (const el of this.dirty) {
      if (el.parentNode !== this.root || el.classList.contains("wraw") || el.classList.contains("wlazy")) continue;
      el.md = serialize(el);
    }
    this.dirty.clear();
    this.onChange(this.text());
  }

  // Content typed straight into the root (Safari does, once everything was
  // deleted): each run of it gathered into one paragraph block, and the
  // caret put back where it was (moving a node takes a selection out of
  // it: typing then went on in the root, a letter per block).
  gather() {
    const sel = document.getSelection();
    const at = sel && sel.rangeCount ? { node: sel.anchorNode, off: sel.anchorOffset } : null;
    let moved = false;
    let run = null;
    for (const n of [...this.root.childNodes]) {
      if (n.nodeType === 1 && n.classList.contains("wblock")) {
        run = null;
        continue;
      }
      if (!run) {
        run = document.createElement("div");
        run.className = "wblock";
        run.appendChild(document.createElement("p"));
        this.root.insertBefore(run, n);
        this.dirty.add(run);
      }
      run.firstChild.appendChild(n);
      moved = moved || (at && (at.node === n || n.contains(at.node)));
    }
    if (moved) sel.collapse(at.node, at.off);
    this.ensure();
  }

  // Never empty: an empty paragraph to type in (and the caret in it, if the
  // caret was left in the root).
  ensure() {
    if (this.root.querySelector(".wblock")) return;
    const el = document.createElement("div");
    el.className = "wblock";
    el.innerHTML = "<p><br></p>";
    el.md = "";
    el.sep = "";
    this.root.appendChild(el);
    const sel = document.getSelection();
    if (sel && this.root.contains(sel.anchorNode)) sel.collapse(el.firstChild, 0);
  }

  // The text as the blocks now say: empty blocks leave no text (the page
  // keeps them: the caret may be there), a block followed by another is
  // separated by a blank line whatever it was before, and the last one is
  // followed by what ended the text (whichever block is last now: one
  // joined into the one before takes its place).
  text() {
    const kids = [...this.root.children].filter((el) => el.md);
    let t = this.prefix;
    kids.forEach((el, i) => {
      let sep = i === kids.length - 1 ? this.tail : el.sep ?? "";
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
    for (const el of olds.slice(a, olds.length - z)) {
      this.seen.unobserve(el);
      el.remove();
    }
    for (const el of fresh) this.root.insertBefore(el, after);
    // Changed blocks on screen are drawn now, not a frame later.
    for (const el of fresh) if (el.getBoundingClientRect().top < window.innerHeight + 2000) this.draw(el);
    this.prefix = next.prefix;
    this.tail = next.blocks.length ? next.blocks[next.blocks.length - 1].sep : "";
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
