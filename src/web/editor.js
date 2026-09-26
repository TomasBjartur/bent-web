// The collaborative editor: a textarea bound to the CRDT (src/crdt.bend,
// compiled to JS). Local edits become operations immediately; a sync loop
// exchanges operations with the server; state and unsent operations are
// kept in localStorage, so edits made offline are sent when back online.
//
// Positions: the CRDT counts code points; textarea positions are UTF-16
// units. Everything here works on code point arrays and converts at the
// edges.
import C from "../crdt.bend";

const NIL = { $: "Nil" };
const SYNC_MS = 1500;
const DEBOUNCE_MS = 250;

const ta = document.getElementById("editor");
if (ta) start(ta);

function start(ta) {
  const post = ta.dataset.post;
  const rep = Number(ta.dataset.rep);
  const url = "/edit/" + post + "/sync";
  const key = "bent:post:" + post;
  const status = document.getElementById("sync-status");
  const initial = ta.value;

  let state = NIL;        // every operation known here
  let text = "";          // C.text(state), as shown
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
  const form = ta.form;
  if (form) {
    form.addEventListener("submit", async (ev) => {
      if (form.dataset.flushed === "1") return;
      ev.preventDefault();
      local();
      for (let i = 0; i < 20 && (busy || batches.length); i++) {
        if (!busy) await sync();
        else await new Promise((r) => setTimeout(r, 100));
      }
      form.dataset.flushed = "1";
      form.submit();
    });
  }

  ta.addEventListener("input", () => {
    local();
    schedule(DEBOUNCE_MS);
  });
  window.addEventListener("online", () => schedule(0));
  setInterval(() => schedule(0), SYNC_MS);
  schedule(0);

  function show(msg) {
    if (status) status.textContent = msg;
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
    const ops = C.edit(state, rep, d.p, d.del, d.ins);
    state = C.union(state, ops);
    batches.push(ops);
    text = ta.value;
    save();
  }

  // Merge remote operations and show the new text, keeping the caret in
  // place relative to the text around it.
  function remote(ops) {
    state = C.union(state, ops);
    const next = C.text(state);
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
    if (focused) {
      const arr = cps(next);
      ta.setSelectionRange(u16(arr, map(selA)), u16(arr, map(selB)));
    }
  }

  function pending() {
    let all = NIL;
    for (const b of batches) all = C.union(all, b);
    return all;
  }

  function schedule(ms) {
    clearTimeout(timer);
    timer = setTimeout(sync, ms);
  }

  async function sync() {
    if (busy) return;
    busy = true;
    inflight = batches.length;
    const body = new URLSearchParams({ since: String(since), ops: C.encode(pending()) });
    show("Syncing…");
    try {
      const res = await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body,
        credentials: "same-origin",
      });
      if (!res.ok) {
        show(res.status === 403 ? "Not allowed (signed out?)" : "Could not save: " + res.status);
        return;
      }
      const reply = await res.text();
      const nl = reply.lastIndexOf("\n");
      const got = C.decode(reply.slice(0, nl));
      since = Math.max(since, Number(reply.slice(nl + 1)) || 0);
      batches = batches.slice(inflight);
      if (got.$ === "Some") remote(got.value);
      seed();
      save();
      show(batches.length ? "Unsaved changes" : "Saved");
    } catch (e) {
      show("Offline: changes are kept on this device");
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
    if (C.text(state) === "" && initial !== "" && since >= 0 && state.$ === "Nil") {
      const ops = C.edit(NIL, 1, 0, 0, initial);
      state = C.union(state, ops);
      batches.push(ops);
      text = C.text(state);
      ta.value = text;
      schedule(0);
    }
  }

  function save() {
    try {
      localStorage.setItem(key, JSON.stringify({ since, state: C.encode(state), pending: C.encode(pending()) }));
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
    const st = C.decode(saved.state || "");
    const pe = C.decode(saved.pending || "");
    if (st.$ === "Some") state = st.value;
    if (pe.$ === "Some" && pe.value.$ !== "Nil") batches.push(pe.value);
    since = Number(saved.since) || 0;
    text = C.text(state);
    if (state.$ !== "Nil") {
      ta.value = text;
      seeded = true;
    }
  }
}
