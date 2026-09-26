// The collaborative editor: a textarea bound to the CRDT. Local edits
// become operations immediately; a sync loop exchanges operations with the
// server; unsent operations are kept in localStorage, so edits made offline
// are sent when back online.
//
// The CRDT here is src/web/fugue.js, differentially fuzzed against the
// proved reference src/crdt.bend (tests/fugue_diff.mjs). Bend's own JS
// output was too slow per keystroke on long documents (see docs/FINDINGS.md).
//
// Positions: the CRDT counts code points; textarea positions are UTF-16
// units. Everything here works on code point arrays and converts at the
// edges.
import { Doc } from "./fugue.js";
const SYNC_MS = 1500;
const DEBOUNCE_MS = 250;

const ta = document.getElementById("editor");
if (ta) start(ta);

// Forms that need a second thought (delete, unpublish).
document.addEventListener("submit", (ev) => {
  const q = ev.target.dataset && ev.target.dataset.confirm;
  if (q && !confirm(q)) ev.preventDefault();
});

function start(ta) {
  const post = ta.dataset.post;
  const rep = Number(ta.dataset.rep);
  const url = "/edit/" + post + "/sync";
  const key = "bent:post:" + post;
  const status = document.getElementById("sync-status");
  const initial = ta.value;

  let doc = new Doc();    // every operation known here
  let text = "";          // doc.text(), as shown
  let since = 0;          // server sequence number seen
  let batches = [];       // local operations not yet acknowledged
  let inflight = 0;       // how many batches the current request carries
  let busy = false;
  let timer = 0;
  let seeded = false;

  // The textarea's value is now the CRDT's: the form saves the title only.
  ta.removeAttribute("name");

  restore();

  // Saving renders the post from the server's operations: send ours first.
  // The button pressed (save or publish) is passed on.
  const form = ta.form;
  const title = form && form.elements.namedItem("title");
  const title0 = title ? title.value : "";
  let leaving = false;
  if (form) {
    form.addEventListener("submit", async (ev) => {
      if (form.dataset.flushed === "1") return;
      ev.preventDefault();
      const by = ev.submitter || null;
      for (const b of form.elements) if (b.tagName === "BUTTON") b.disabled = true;
      local();
      show("Saving…", "busy");
      for (let i = 0; i < 20 && (busy || batches.length); i++) {
        if (!busy) await sync();
        else await new Promise((r) => setTimeout(r, 100));
      }
      for (const b of form.elements) if (b.tagName === "BUTTON") b.disabled = false;
      form.dataset.flushed = "1";
      leaving = true;
      // Outside this event: a submit requested while one is being
      // dispatched is ignored (it would be if nothing had to be sent).
      setTimeout(() => form.requestSubmit(by), 0);
    });
    // Ctrl+S / Cmd+S: save (and re-render) without leaving the keyboard.
    document.addEventListener("keydown", (ev) => {
      if ((ev.ctrlKey || ev.metaKey) && !ev.altKey && ev.key.toLowerCase() === "s") {
        ev.preventDefault();
        form.requestSubmit();
      }
    });
    // The title is one line that wraps: Enter goes to the text, and pasted
    // line breaks become spaces (the server refuses control characters).
    if (title) {
      title.addEventListener("keydown", (ev) => {
        if (ev.key === "Enter") {
          ev.preventDefault();
          ta.focus();
          ta.setSelectionRange(0, 0);
        }
      });
      title.addEventListener("input", () => {
        if (/[\r\n]/.test(title.value)) title.value = title.value.replace(/[\r\n]+/g, " ");
        grow(title);
      });
    }
  }
  // Unsent text, or a title not saved yet: ask before leaving.
  window.addEventListener("beforeunload", (ev) => {
    if (leaving) return;
    if (batches.length || (title && title.value !== title0)) ev.preventDefault();
  });

  // Grow the textarea with its text, so the page scrolls, not a box.
  // Browsers with CSS field-sizing do it themselves.
  const grows = window.CSS && CSS.supports && CSS.supports("field-sizing", "content");
  const growing = new Map();
  function grow(el = ta) {
    if (grows || growing.has(el)) return;
    growing.set(el, requestAnimationFrame(() => {
      growing.delete(el);
      const y = window.scrollY;
      el.style.height = "auto";
      el.style.height = el.scrollHeight + "px";
      window.scrollTo(0, y);
    }));
  }
  grow();
  if (title) grow(title);

  ta.addEventListener("input", () => {
    local();
    grow();
    show("Unsaved changes", "busy");
    schedule(DEBOUNCE_MS);
  });
  window.addEventListener("online", () => schedule(0));
  setInterval(() => schedule(0), SYNC_MS);
  schedule(0);

  // cls: "" all saved, "busy" work pending, "off" not reaching the server.
  function show(msg, cls) {
    if (!status) return;
    status.textContent = msg;
    status.className = "status" + (cls ? " " + cls : "");
  }

  function cps(s) {
    return Array.from(s);
  }

  // Code point index to UTF-16 index in s.
  function u16(arr, i) {
    let n = 0;
    for (let k = 0; k < i && k < arr.length; k++) n += arr[k].length;
    return n;
  }

  // The first differing prefix/suffix of two code point arrays.
  function diff(a, b) {
    let p = 0;
    while (p < a.length && p < b.length && a[p] === b[p]) p++;
    let s = 0;
    while (s < a.length - p && s < b.length - p && a[a.length - 1 - s] === b[b.length - 1 - s]) s++;
    return { p, del: a.length - p - s, ins: b.slice(p, b.length - s).join("") };
  }

  function local() {
    const d = diff(cps(text), cps(ta.value));
    if (d.del === 0 && d.ins === "") return;
    batches.push(doc.edit(rep, d.p, d.del, d.ins));
    text = ta.value;
    save();
  }

  // Merge remote operations and show the new text, keeping the caret in
  // place relative to the text around it.
  function remote(ops) {
    if (!doc.applyAll(ops)) return;
    const next = doc.text();
    if (next === ta.value) {
      text = next;
      return;
    }
    const before = cps(ta.value);
    const selA = cps(ta.value.slice(0, ta.selectionStart)).length;
    const selB = cps(ta.value.slice(0, ta.selectionEnd)).length;
    const d = diff(before, cps(next));
    const map = (i) => (i <= d.p ? i : i >= d.p + d.del ? i - d.del + cps(d.ins).length : d.p + cps(d.ins).length);
    const focused = document.activeElement === ta;
    ta.value = next;
    text = next;
    grow();
    if (focused) {
      const arr = cps(next);
      ta.setSelectionRange(u16(arr, map(selA)), u16(arr, map(selB)));
    }
  }

  function pending() {
    return batches.flat();
  }

  function schedule(ms) {
    clearTimeout(timer);
    timer = setTimeout(sync, ms);
  }

  async function sync() {
    if (busy) return;
    busy = true;
    inflight = batches.length;
    const body = new URLSearchParams({ since: String(since), ops: Doc.encode(pending()) });
    if (batches.length) show("Saving…", "busy");
    try {
      const res = await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body,
        credentials: "same-origin",
      });
      if (!res.ok) {
        show(res.status === 403 ? "Not saved: are you logged out?" : "Could not save (" + res.status + ")", "off");
        return;
      }
      const reply = await res.text();
      const nl = reply.lastIndexOf("\n");
      const got = Doc.decode(reply.slice(0, nl));
      since = Math.max(since, Number(reply.slice(nl + 1)) || 0);
      batches = batches.slice(inflight);
      if (got) remote(inflight ? got : got.concat(pending()));
      seed();
      save();
      show(batches.length ? "Unsaved changes" : "Saved", batches.length ? "busy" : "");
    } catch (e) {
      show("Offline: changes are kept on this device", "off");
    } finally {
      busy = false;
      if (batches.length) schedule(DEBOUNCE_MS);
    }
  }

  // A post written before the editor existed has no operations: seed them
  // from its text, deterministically (replica 1, counters from 1), so two
  // editors seeding at once produce the same operations.
  function seed() {
    if (seeded) return;
    seeded = true;
    if (doc.order.length === 0 && initial !== "") {
      batches.push(doc.edit(1, 0, 0, initial));
      text = doc.text();
      ta.value = text;
      grow();
      schedule(0);
    }
  }

  // Only unsent operations are stored: the server has everything else, and
  // a long document would not fit in localStorage anyway.
  function save() {
    try {
      localStorage.setItem(key, JSON.stringify({ pending: Doc.encode(pending()) }));
    } catch (e) {
      // Storage full or disabled: the server still has everything sent.
    }
  }

  function restore() {
    let saved = null;
    try {
      saved = JSON.parse(localStorage.getItem(key) || "null");
    } catch (e) {
      saved = null;
    }
    if (!saved) return;
    const pe = Doc.decode(saved.pending || "");
    // Unsent edits from last time: sent with the first sync; the document
    // they belong to arrives with it (since = 0), so the text is shown then.
    if (pe && pe.length) {
      batches.push(pe);
      seeded = true;
    }
  }
}
