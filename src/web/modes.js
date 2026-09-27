// The editor's modes: Markdown (the textarea) or Visual (WYSIWYG,
// visual.js), and, in Markdown mode, Vim keybindings (vim.js): off by
// default; the first time they are turned on, a dialog explains them and
// asks the writer to say yes only if they know Vim. Choices are kept per
// browser (localStorage: a convenience, not a setting that must follow
// the writer).
//
// Built here, not in the page template: without JavaScript the editor is
// a plain textarea and none of this applies.
import { Vim } from "./vim.js";
import { Visual, VISUAL_MAX } from "./visual.js";

const PREF_MODE = "bent:editor-mode";
const PREF_VIM = "bent:vim";
const PREF_VIM_OK = "bent:vim-ok";

function pref(k) {
  try {
    return localStorage.getItem(k);
  } catch (e) {
    return null;
  }
}
function setPref(k, v) {
  try {
    if (v === null) localStorage.removeItem(k);
    else localStorage.setItem(k, v);
  } catch (e) {
    // Storage off: the choice lasts for this page only.
  }
}

function el(tag, attrs = {}, ...kids) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === "class") e.className = v;
    else if (k === "text") e.textContent = v;
    else e.setAttribute(k, v);
  }
  e.append(...kids);
  return e;
}

// ta: the textarea; set(text): replace the text as an edit (CRDT and
// status follow); save(): save now; upload(file) -> "/img/..." or null.
export function setupModes(ta, { set, save, upload, show }) {
  const md = el("button", { type: "button", class: "seg", "aria-pressed": "true", text: "Markdown" });
  const vis = el("button", { type: "button", class: "seg", "aria-pressed": "false", text: "Visual" });
  const B = (label, title, cmd) => el("button", { type: "button", class: "fmt", title, "aria-label": title, "data-cmd": cmd, text: label });
  const fmt = el("div", { class: "fmt-bar", role: "toolbar", "aria-label": "Formatting", hidden: "" },
    B("B", "Bold (Ctrl+B)", "bold"), B("I", "Italic (Ctrl+I)", "italic"), B("</>", "Code", "code"), B("Link", "Link (Ctrl+K)", "link"),
    B("H2", "Heading", "h2"), B("H3", "Subheading", "h3"), B("¶", "Paragraph", "p"), B("❝", "Quote", "quote"),
    B("• List", "Bulleted list", "ul"), B("1. List", "Numbered list", "ol"));
  const vimBtn = el("button", { type: "button", class: "seg vim-toggle", "aria-pressed": "false", title: "Vim keybindings", text: "Vim" });
  const modeLine = el("span", { class: "vim-line", role: "status", "aria-live": "polite", hidden: "" });
  // Into the page's empty toolbar (its height is kept for it: no shift).
  let bar = document.getElementById("edit-tools");
  if (!bar) {
    bar = el("div", { class: "edit-tools" });
    ta.parentNode.insertBefore(bar, ta);
  }
  bar.append(el("div", { class: "segs", role: "group", "aria-label": "Editing mode" }, md, vis), fmt,
    el("div", { class: "tools-end" }, modeLine, vimBtn));
  const view = el("div", { class: "body wys", contenteditable: "true", role: "textbox", "aria-multiline": "true", "aria-label": "Text", hidden: "", spellcheck: "true" });
  ta.parentNode.insertBefore(view, ta.nextSibling);
  const dialog = vimDialog();
  document.body.appendChild(dialog);

  const visual = new Visual(view, (text) => set(text));
  let mode = "markdown";

  // MODES
  function toMode(m, focus = true) {
    if (m === "visual" && ta.value.length > VISUAL_MAX) {
      show("This post is too long for Visual mode: edit it as Markdown", "off");
      m = "markdown";
    }
    if (m === mode) return;
    mode = m;
    setPref(PREF_MODE, m);
    md.setAttribute("aria-pressed", String(m === "markdown"));
    vis.setAttribute("aria-pressed", String(m === "visual"));
    fmt.hidden = m !== "visual";
    vimBtn.hidden = m === "visual"; // Vim is for the Markdown text
    if (m === "visual") {
      if (vimOn) vimShow(false);
      visual.open(ta.value);
      ta.hidden = true;
      view.hidden = false;
      if (focus) view.focus();
    } else {
      visual.close();
      view.hidden = true;
      ta.hidden = false;
      if (vimOn) vimShow(true);
      if (focus) ta.focus();
    }
  }
  md.addEventListener("click", () => toMode("markdown"));
  vis.addEventListener("click", () => toMode("visual"));

  // FORMATTING (Visual mode)
  function format(cmd) {
    view.focus();
    if (cmd === "bold" || cmd === "italic") document.execCommand(cmd);
    else if (cmd === "h2" || cmd === "h3" || cmd === "p") document.execCommand("formatBlock", false, cmd);
    else if (cmd === "quote") document.execCommand("formatBlock", false, "blockquote");
    else if (cmd === "ul") document.execCommand("insertUnorderedList");
    else if (cmd === "ol") document.execCommand("insertOrderedList");
    else if (cmd === "code") {
      const s = document.getSelection().toString().replace(/\n/g, " ");
      if (s) document.execCommand("insertHTML", false, "<code>" + escHtml(s) + "</code>");
    } else if (cmd === "link") {
      const url = prompt("Link to (https://…)", "https://");
      if (url && /^(https?:\/\/|\/)[^\s()<>"]+$/.test(url)) document.execCommand("createLink", false, url);
      else if (url && url !== "https://") show("A link must start with https:// or http://", "off");
    }
  }
  fmt.addEventListener("click", (ev) => {
    const b = ev.target.closest("button[data-cmd]");
    if (b) format(b.dataset.cmd);
  });
  fmt.addEventListener("mousedown", (ev) => ev.preventDefault()); // keep the selection in the text
  view.addEventListener("keydown", (ev) => {
    if (!(ev.ctrlKey || ev.metaKey) || ev.altKey) return;
    const k = ev.key.toLowerCase();
    if (k === "b" || k === "i") {
      ev.preventDefault();
      format(k === "b" ? "bold" : "italic");
    } else if (k === "k") {
      ev.preventDefault();
      format("link");
    }
  });
  // Images into Visual mode: uploaded, then put in at the caret.
  async function addImages(files, ev) {
    if (!files.length) return;
    ev.preventDefault();
    for (const f of files) {
      const path = await upload(f);
      if (path) {
        view.focus();
        document.execCommand("insertHTML", false, '<img src="' + path + '" alt="' + escHtml(altOf(f.name)) + '">');
      }
    }
  }
  view.addEventListener("paste", (ev) => addImages([...(ev.clipboardData ? ev.clipboardData.files : [])].filter((f) => f.type.startsWith("image/")), ev));
  view.addEventListener("drop", (ev) => addImages([...(ev.dataTransfer ? ev.dataTransfer.files : [])].filter((f) => f.type.startsWith("image/")), ev));

  // VIM
  const vim = new Vim();
  let vimOn = false;
  function vimShow(on) {
    modeLine.hidden = !on;
    ta.classList.toggle("vim", on);
    if (on) {
      if (vim.mode === "insert") vim.escape(ta.value, ta.selectionStart);
      vim.mode = "normal";
      block(ta.selectionStart);
      line();
    }
  }
  function vimSet(on) {
    vimOn = on;
    setPref(PREF_VIM, on ? "1" : null);
    vimBtn.setAttribute("aria-pressed", String(on));
    vimShow(on && mode === "markdown");
    if (mode === "markdown") ta.focus();
  }
  vimBtn.addEventListener("click", () => {
    if (vimOn) return vimSet(false);
    if (pref(PREF_VIM_OK) === "1") return vimSet(true);
    dialog.returnValue = "";
    dialog.showModal();
  });
  dialog.addEventListener("close", () => {
    if (dialog.returnValue === "yes") {
      setPref(PREF_VIM_OK, "1");
      vimSet(true);
    } else ta.focus();
  });

  // Normal mode stands on a character: shown as a one-character selection.
  function block(c) {
    const t = ta.value;
    c = Vim.normalize(t, c);
    const e = c < t.length && t[c] !== "\n" ? c + (t.codePointAt(c) > 0xffff ? 2 : 1) : c;
    ta.setSelectionRange(c, e);
  }
  function line(extra = "") {
    const names = { normal: "NORMAL", insert: "INSERT", visual: "VISUAL", vline: "VISUAL LINE" };
    modeLine.textContent = vim.cmd !== null ? vim.cmd + vim.cmdText : "-- " + names[vim.mode] + " --" + (extra ? "  " + extra : "");
    modeLine.classList.toggle("insert", vim.mode === "insert");
  }
  const NAMED = new Set(["Escape", "Enter", "Backspace", "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Home", "End"]);
  ta.addEventListener("keydown", (ev) => {
    if (!vimOn || mode !== "markdown" || ev.isComposing) return;
    let k = ev.key;
    if (ev.ctrlKey && !ev.altKey && !ev.metaKey && (k === "[" || k === "c") && vim.mode === "insert") k = "Escape";
    else if (ev.ctrlKey && !ev.altKey && !ev.metaKey && k.toLowerCase() === "r") k = "C-r";
    else if (ev.ctrlKey || ev.metaKey || ev.altKey) return; // Ctrl+S and the browser's own
    if (vim.mode === "insert" && vim.cmd === null) {
      if (k !== "Escape") return; // typing: the browser's
      ev.preventDefault();
      const r = vim.escape(ta.value, ta.selectionStart);
      block(r.cur);
      line();
      return;
    }
    if ([...k].length !== 1 && !NAMED.has(k) && k !== "C-r") return; // Shift, Tab...
    ev.preventDefault();
    const r = vim.key(k, { text: ta.value, a: ta.selectionStart, b: ta.selectionEnd });
    if (!r) return;
    if (r.text !== ta.value) set(r.text, true);
    if (r.keepCursor) block(ta.selectionStart);
    else if (vim.mode === "insert") ta.setSelectionRange(r.a, r.a);
    else if (vim.mode === "visual" || vim.mode === "vline") ta.setSelectionRange(r.a, r.b);
    else block(r.a);
    line(r.msg || r.pending || "");
    if (r.save) save();
  });
  // A click in normal mode moves the block cursor there.
  ta.addEventListener("mouseup", () => {
    if (!vimOn || mode !== "markdown" || vim.mode === "insert") return;
    if (ta.selectionEnd - ta.selectionStart > 2) {
      vim.mode = "visual";
      vim.anchor = ta.selectionStart;
      vim.head = ta.selectionEnd - 1;
      line();
    } else {
      vim.mode = "normal";
      block(ta.selectionStart);
      line();
    }
  });

  // Where we were last time.
  if (pref(PREF_VIM) === "1" && pref(PREF_VIM_OK) === "1") vimSet(true);
  if (pref(PREF_MODE) === "visual") toMode("visual", false);

  return {
    // The text changed elsewhere (another writer, or a sync).
    remote(text) {
      if (mode === "visual") visual.refresh(text);
    },
    visual: () => mode === "visual",
  };
}

function vimDialog() {
  const d = el("dialog", { class: "modal", "aria-labelledby": "vim-title" });
  const form = el("form", { method: "dialog", class: "stack" },
    el("h2", { id: "vim-title", text: "Turn on Vim keybindings?" }),
    el("p", { text: "Vim is a modal editor. With this on, the editor starts in Normal mode, where keys are commands, not text: pressing a letter moves the cursor or changes the text instead of typing it." }),
    el("p", { text: "Press i to type, Esc to stop typing, and :w to save. Your text still saves as you type, and you can turn this off again with the Vim button." }),
    el("p", { class: "warn", text: "Only click Yes if you already know Vim. If you are not sure, click No." }),
    el("div", { class: "row" },
      el("button", { value: "no", class: "primary", autofocus: "", text: "No, keep normal typing" }),
      el("button", { value: "yes", class: "quiet", text: "Yes, I know Vim" })));
  d.appendChild(form);
  return d;
}

function escHtml(s) {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
}

export function altOf(name) {
  return (name || "").replace(/\.[a-z0-9]+$/i, "").replace(/[\[\]\r\n]/g, " ").slice(0, 100).trim();
}
