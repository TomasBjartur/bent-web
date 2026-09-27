// The collaborative editor (local-first: the browser holds the document
// and merges; the server stores operations). Local edits become CRDT
// operations at once; a sync loop exchanges operations with the server;
// unsent operations are kept in localStorage, so edits made offline are
// sent when back online.
//
// The parts (each built for documents of any length, a novel included):
// - src/web/fugue.js: the CRDT (typed arrays; differentially fuzzed
//   against the proved reference src/crdt.bend, tests/fugue_diff.mjs).
// - src/web/view.js: the Markdown view (a textarea window over the text).
// - src/web/history.js: undo and redo of this writer's own changes.
// - src/web/modes.js: Visual mode and Vim keybindings.
// Positions are UTF-16 units everywhere.
import { Doc, Ops } from "./fugue.js";
import { View, diff } from "./view.js";
import { History } from "./history.js";
import { setupModes, altOf } from "./modes.js";

const SYNC_MS = 1500;
const DEBOUNCE_MS = 250;
// Operations per sync request: under the server's SYNC_OPS_MAX (20000,
// src/c/db_core.h) and, at up to ~50 bytes each, under the 1 MiB request
// limit. A large paste goes up in several requests.
const SEND_OPS = 10000;
// The unsent operations are copied to localStorage at most this often
// (and when the page is hidden), not on every keystroke.
const STORE_MS = 1000;
// The server cuts a reply at SYNC_OUT_MAX (8 MiB, src/c/db_core.h); one
// this long was cut, and the rest is asked for at once.
const REPLY_FULL = 8 * 1024 * 1024 - 256;

const ta = document.getElementById("editor");
if (ta) start(ta);

// Forms that need a second thought (delete, unpublish): src/web/app.js.

function start(ta) {
  const post = ta.dataset.post;
  const rep = Number(ta.dataset.rep);
  const url = "/edit/" + post + "/sync";
  const key = "bent:post:" + post;
  const status = document.getElementById("sync-status");
  // A published post's edits are saved as you type but only go live with
  // Update: the status says so, rather than a "Saved" that reads as live.
  const live = ta.dataset.published === "1";
  let edited = false;
  // After a save here ("Draft saved", "Updated · live now"), until the next edit.
  let saveLabel = "Saved";
  const savedText = () => (live && edited ? "Saved · press Update to publish changes" : saveLabel);
  const initial = ta.value;

  const doc = new Doc();  // every operation known here
  let since = 0;          // server sequence number seen
  let batches = [];       // local operations not yet acknowledged (Ops, oldest first)
  let inflight = 0;       // how many batches the current request carries
  let busy = false;
  let timer = 0;
  let seeded = false;
  const history = new History();
  // Until the server's operations have all arrived, the view shows the
  // server-rendered text but the CRDT does not hold it yet: an edit then
  // would be made against a partial document, so the text is read-only.
  let loaded = false;

  // The textarea's value is now the CRDT's: the form saves the title only.
  ta.removeAttribute("name");
  const view = new View(ta, { edit: typed });
  view.readOnly = true;
  // For tests and debugging (the whole text is not in the textarea).
  ta.bent = { view, doc, history, loaded: () => loaded, pending: () => batches.length };

  restore();

  // Saving renders the post from the server's operations: send ours first.
  // The button pressed (save or publish) is passed on.
  const form = ta.form;
  const title = form && form.elements.namedItem("title");
  // A new draft is stored as "Untitled": show an empty title with its
  // placeholder instead, and send "Untitled" if it is still empty.
  if (title && title.value === "Untitled" && ta.dataset.published !== "1") {
    title.value = "";
    title.required = false;
  }
  let title0 = title ? title.value : "";
  // This form sends itself (src/web/app.js leaves it alone).
  if (form) form.setAttribute("data-js", "");

  // The form sent with fetch: the server saves and answers with a redirect
  // (to this page, or the post's), which is not followed.
  async function saveHere(action, by) {
    const data = new URLSearchParams(new FormData(form));
    data.set("action", by ? by.value : "save");
    try {
      const res = await fetch(form.getAttribute("action"), { method: "POST", body: data, credentials: "same-origin", redirect: "manual" });
      if (res.type === "opaqueredirect" || res.ok) {
        edited = false;
        // A draft's "Untitled" is shown as the empty title again.
        if (title && title.value === "Untitled" && !live) title.value = "";
        title0 = title ? title.value : "";
        saveLabel = action === "publish" ? "Updated · live now" : "Draft saved";
        show(saveLabel, "");
      } else if (res.status === 400) {
        show("Not saved: check the title and tags", "off");
      } else {
        show(res.status === 403 ? "Not saved: are you logged out?" : "Not saved (" + res.status + ")", "off");
      }
    } catch (e) {
      show("Offline: your text is kept on this device; save again when back online", "off");
    }
  }
  let leaving = false;
  if (form) {
    form.addEventListener("submit", async (ev) => {
      if (form.dataset.flushed === "1") return;
      ev.preventDefault();
      if (title && !title.value.trim()) title.value = "Untitled";
      const by = ev.submitter || null;
      // Scheduling: the chosen local time, as minutes since 1970 (UTC).
      if (by && by.value === "schedule") {
        const local = form.elements.namedItem("at_local");
        const t = local && local.value ? new Date(local.value).getTime() : NaN;
        if (!(t > Date.now())) {
          if (local) local.focus();
          show("Pick a time in the future to schedule", "off");
          return;
        }
        form.elements.namedItem("at").value = String(Math.floor(t / 60000));
      }
      for (const b of form.elements) if (b.tagName === "BUTTON") b.disabled = true;
      show("Saving…", "busy");
      // Until everything is sent, or a request fails (a large paste takes
      // several requests).
      for (let i = 0; i < 1000 && (busy || batches.length); i++) {
        if (busy) await new Promise((r) => setTimeout(r, 100));
        else if (!(await sync())) break;
      }
      // Saving a draft, or updating a post that is already published,
      // happens here, without leaving the page (the caret and the scroll
      // stay). Publishing and scheduling go on to their pages.
      const action = by ? by.value : "save";
      if (action === "save" || (action === "publish" && live)) {
        await saveHere(action, by);
        for (const b of form.elements) if (b.tagName === "BUTTON") b.disabled = false;
        return;
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
          if (modes.visual()) return modes.focus();
          view.focus();
          view.select(0, 0);
        }
      });
      title.addEventListener("input", () => {
        if (/[\r\n]/.test(title.value)) title.value = title.value.replace(/[\r\n]+/g, " ");
        growTitle();
      });
    }
  }
  // IMAGES: chosen, pasted or dropped. Resized in the browser (at most
  // 1600 px, JPEG) to fit the 1 MiB request limit; re-encoding also drops
  // EXIF data such as GPS positions. A small GIF is sent as it is.
  const pick = document.getElementById("image-pick");
  const addBtn = document.getElementById("image-add");
  if (addBtn && pick) {
    addBtn.addEventListener("click", () => pick.click());
    pick.addEventListener("change", () => {
      for (const f of pick.files) upload(f);
      pick.value = "";
    });
  }
  ta.addEventListener("paste", (ev) => {
    const files = [...(ev.clipboardData ? ev.clipboardData.files : [])].filter((f) => f.type.startsWith("image/"));
    if (files.length) {
      ev.preventDefault();
      for (const f of files) upload(f);
    }
  });
  ta.addEventListener("dragover", (ev) => ev.preventDefault());
  ta.addEventListener("drop", (ev) => {
    const files = [...(ev.dataTransfer ? ev.dataTransfer.files : [])].filter((f) => f.type.startsWith("image/"));
    if (files.length) {
      ev.preventDefault();
      for (const f of files) upload(f);
    }
  });

  const IMG_MAX_BYTES = 1000000;
  const IMG_MAX_SIDE = 1600;

  async function shrink(file) {
    if (file.type === "image/gif" && file.size <= IMG_MAX_BYTES) return file;
    const bmp = await createImageBitmap(file, { imageOrientation: "from-image" });
    let scale = Math.min(1, IMG_MAX_SIDE / Math.max(bmp.width, bmp.height));
    for (let round = 0; round < 6; round++) {
      const c = document.createElement("canvas");
      c.width = Math.max(1, Math.round(bmp.width * scale));
      c.height = Math.max(1, Math.round(bmp.height * scale));
      const g = c.getContext("2d");
      g.fillStyle = "#fff";
      g.fillRect(0, 0, c.width, c.height);
      g.drawImage(bmp, 0, 0, c.width, c.height);
      for (const q of [0.85, 0.72, 0.6]) {
        const blob = await new Promise((r) => c.toBlob(r, "image/jpeg", q));
        if (blob && blob.size <= IMG_MAX_BYTES) return blob;
      }
      scale *= 0.7;
    }
    throw new Error("too large");
  }

  // Uploads an image: its path, or null (the status says why).
  async function uploadImage(file) {
    show("Adding the image…", "busy");
    try {
      const blob = await shrink(file);
      const res = await fetch("/upload/" + post, {
        method: "POST",
        headers: { "Content-Type": blob.type || "application/octet-stream" },
        body: blob,
        credentials: "same-origin",
      });
      const text = (await res.text()).trim();
      if (!res.ok || !/^\/img\/[0-9a-f]{32}$/.test(text)) {
        show(text || "The image was not added", "off");
        return null;
      }
      return text;
    } catch (e) {
      show("The image could not be added", "off");
      return null;
    }
  }

  // Into the Markdown text, at the caret.
  async function upload(file) {
    const path = await uploadImage(file);
    if (!path || view.readOnly) return;
    const md = "\n![" + altOf(file.name) + "](" + path + ")\n";
    const s = view.sel();
    change(s.a, s.b - s.a, md, s.a + md.length);
  }

  // A scheduled time, shown in the reader's own time zone.
  for (const el of document.querySelectorAll(".scheduled time[datetime]")) {
    const d = new Date(el.getAttribute("datetime"));
    if (!Number.isNaN(d.getTime())) el.textContent = d.toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
  }

  // Unsent text, or a title not saved yet: ask before leaving.
  window.addEventListener("beforeunload", (ev) => {
    if (leaving) return;
    if (batches.length || (title && title.value !== title0)) ev.preventDefault();
  });

  // The title grows with its text (browsers without CSS field-sizing).
  function growTitle() {
    if (!title || (window.CSS && CSS.supports && CSS.supports("field-sizing", "content"))) return;
    title.style.height = "auto";
    title.style.height = title.scrollHeight + "px";
  }
  growTitle();

  window.addEventListener("online", () => schedule(0));
  setInterval(() => schedule(0), SYNC_MS);
  schedule(0);

  // CHANGES
  // The selection before an edit the browser makes (for undo), and the
  // input method's composition it is part of (one undo step each).
  let selBefore = null;
  let composition = 0, compositions = 0;
  ta.addEventListener("compositionstart", () => (composition = ++compositions));
  ta.addEventListener("compositionend", () => setTimeout(() => (composition = 0), 0));
  ta.addEventListener("beforeinput", (ev) => {
    if (ev.inputType === "historyUndo" || ev.inputType === "historyRedo") {
      // The Edit menu's (or a shake's) undo: ours, not the textarea's.
      ev.preventDefault();
      if (ev.inputType === "historyUndo") undo();
      else redo();
      return;
    }
    const s = view.sel();
    selBefore = { a: s.a, b: s.b };
  });
  ta.addEventListener("keydown", (ev) => {
    const mod = (ev.ctrlKey || ev.metaKey) && !ev.altKey;
    if (!mod || ev.defaultPrevented) return;
    const k = ev.key.toLowerCase();
    if (k === "z" && !ev.shiftKey) {
      ev.preventDefault();
      undo();
    } else if ((k === "z" && ev.shiftKey) || (k === "y" && ev.ctrlKey)) {
      ev.preventDefault();
      redo();
    }
  });

  // The textarea changed the text (typing, paste, drop, IME).
  function typed(p, del, ins, delText) {
    const s = view.sel();
    local(p, del, ins);
    history.record(p, delText, ins, selBefore || { a: p, b: p + del }, { a: s.a, b: s.b }, Date.now(), composition);
    selBefore = null;
  }

  // A change made here other than by the textarea (Vim, an image, Visual
  // mode, undo): into the view, the CRDT and the history; then the
  // selection [a, b] (null: where the view keeps it).
  function change(p, del, ins, a = null, b = a) {
    if (view.readOnly || (del === 0 && ins === "")) return;
    const s = view.sel();
    const delText = view.text.slice(p, p + del);
    view.apply(p, del, ins, false);
    local(p, del, ins);
    if (a !== null) view.select(a, b, true);
    const s2 = view.sel();
    // (Never merged with typing: each such change is a step of its own.)
    history.record(p, delText, ins, { a: s.a, b: s.b }, { a: s2.a, b: s2.b }, null);
  }

  // The operations for a local change.
  function local(p, del, ins) {
    queue(doc.edit(rep, p, del, ins));
    edited = true;
    saveLabel = "Saved";
    show("Unsaved changes", "busy");
    save();
    schedule(DEBOUNCE_MS);
  }

  function undo() {
    if (view.readOnly) return;
    const ch = history.undo((p, n) => view.text.slice(p, p + n));
    if (!ch) return show("Nothing to undo", batches.length ? "busy" : "");
    applyHistory(ch);
  }

  function redo() {
    if (view.readOnly) return;
    const ch = history.redo((p, n) => view.text.slice(p, p + n));
    if (!ch) return show("Nothing to redo", batches.length ? "busy" : "");
    applyHistory(ch);
  }

  function applyHistory(ch) {
    view.apply(ch.p, ch.del, ch.ins, false);
    local(ch.p, ch.del, ch.ins);
    const s = ch.sel || { a: ch.p + ch.ins.length, b: ch.p + ch.ins.length };
    modes.remote(view.text);
    if (modes.visual()) return;
    view.focus();
    view.select(s.a, s.b, true);
  }

  // Markdown or Visual mode, and Vim keybindings (modes.js). set(text): an
  // edit made there, as the whole text it should become.
  const modes = setupModes(view, {
    set(next, a = null, b = a) {
      if (next === view.text || view.readOnly) return;
      const d = diff(view.text, next);
      change(d.p, d.del, d.ins, a, b);
    },
    save() {
      if (form) form.requestSubmit();
    },
    undo,
    redo,
    upload: uploadImage,
    show,
  });

  // cls: "" all saved, "busy" work pending, "off" not reaching the server.
  function show(msg, cls) {
    if (!status) return;
    status.textContent = msg;
    status.className = "status" + (cls ? " " + cls : "");
  }

  // REMOTE CHANGES: merged, and each visible change passed to the view (and
  // the undo history) as it happens. A large batch is merged in one pass;
  // then the text is compared instead.
  function remote(ops) {
    const got = doc.apply(ops, (p, del, ins) => {
      view.apply(p, del, ins, true);
      history.remote(p, del, ins.length);
    });
    if (got === 2) showDoc();
    if (got) modes.remote(view.text);
  }

  // The view to the CRDT's text (loading, or after a large batch).
  function showDoc() {
    const next = doc.text();
    if (next === view.text) return;
    const d = diff(view.text, next);
    history.remote(d.p, d.del, d.ins.length);
    view.reset(next);
    modes.remote(next);
  }

  // SYNC
  // New local operations, cut to request size.
  function queue(ops) {
    for (let i = 0; i < ops.n; i += SEND_OPS) batches.push(i === 0 && ops.n <= SEND_OPS ? ops : ops.slice(i, Math.min(ops.n, i + SEND_OPS)));
  }

  function pending() {
    return Ops.concat(batches);
  }

  function schedule(ms) {
    clearTimeout(timer);
    timer = setTimeout(sync, ms);
  }

  async function sync() {
    if (busy) return;
    busy = true;
    // Whole batches, oldest first, up to SEND_OPS operations.
    let count = 0;
    let more = false; // the reply was cut: ask again at once
    inflight = 0;
    while (inflight < batches.length && (inflight === 0 || count + batches[inflight].n <= SEND_OPS)) count += batches[inflight++].n;
    const body = new URLSearchParams({ since: String(since), ops: Ops.concat(batches.slice(0, inflight)).encode() });
    if (batches.length) show("Saving…", "busy");
    try {
      const res = await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body,
        credentials: "same-origin",
      });
      if (!res.ok) {
        // 409: the post is at the server's limit of operations
        // (POST_OPS_MAX, 4 million: every character typed or deleted is one).
        show(res.status === 403 ? "Not saved: are you logged out?"
          : res.status === 409 ? "Not saved: this post has reached the limit of 4 million edits (deleted text counts). Your text is kept here; copy it into a new post."
          : "Could not save (" + res.status + ")", "off");
        return false;
      }
      const reply = await res.text();
      const nl = reply.lastIndexOf("\n");
      const got = Ops.decode(reply.slice(0, nl));
      since = Math.max(since, Number(reply.slice(nl + 1)) || 0);
      batches = batches.slice(inflight);
      more = nl > REPLY_FULL;
      if (got) {
        // (Before loading, unsent edits restored from last time go in with
        // the document.)
        const ops = inflight || loaded ? got : Ops.concat([got, pending()]);
        if (loaded) remote(ops);
        else doc.apply(ops);
      }
      if (!more) {
        seed(); // (needs the whole document)
        if (!loaded) {
          loaded = true;
          showDoc();
          view.readOnly = false;
          modes.loaded();
        }
      }
      save(); // throttled: after each request of a long upload, it would be quadratic
      show(batches.length ? "Unsaved changes" : savedText(), batches.length ? "busy" : "");
    } catch (e) {
      show("Offline: changes are kept on this device", "off");
      return false;
    } finally {
      busy = false;
      // More to send: at once if this request was full, else after a pause.
      if (more || (batches.length && count >= SEND_OPS)) schedule(0);
      else if (batches.length) schedule(DEBOUNCE_MS);
    }
    return true;
  }

  // A post written before the editor existed has no operations: seed them
  // from its text, deterministically (replica 1, counters from 1), so two
  // editors seeding at once produce the same operations.
  function seed() {
    if (seeded) return;
    seeded = true;
    if (doc.size === 0 && initial !== "") {
      queue(doc.edit(1, 0, 0, initial));
      schedule(0);
    }
  }

  // Only unsent operations are stored: the server has everything else, and
  // a long document would not fit in localStorage anyway. Encoding every
  // unsent operation costs time in proportion to them (a large paste not
  // yet sent is megabytes), so not on every keystroke: at most every
  // STORE_MS, and at once when the page is hidden.
  let storeTimer = 0;
  function save(now = false) {
    if (!now) {
      if (!storeTimer) storeTimer = setTimeout(() => save(true), STORE_MS);
      return;
    }
    clearTimeout(storeTimer);
    storeTimer = 0;
    try {
      if (batches.length) localStorage.setItem(key, JSON.stringify({ pending: pending().encode() }));
      else localStorage.removeItem(key);
    } catch (e) {
      // Storage full or disabled: the server still has everything sent.
    }
  }
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "hidden" && storeTimer) save(true);
  });
  window.addEventListener("pagehide", () => {
    if (storeTimer) save(true);
  });

  function restore() {
    let saved = null;
    try {
      saved = JSON.parse(localStorage.getItem(key) || "null");
    } catch (e) {
      saved = null;
    }
    if (!saved) return;
    const pe = Ops.decode(saved.pending || "");
    // Unsent edits from last time: sent with the first sync; the document
    // they belong to arrives with it (since = 0), so the text is shown then.
    if (pe && pe.n) {
      queue(pe);
      seeded = true;
    }
  }
}
