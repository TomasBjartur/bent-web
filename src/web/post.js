// The post page, enhanced. Without this script every form still works
// (with a page load); with it: liking swaps the button in place, a comment
// is sent without leaving the page, and new comments appear as they are
// written (long polling /live/<post>?after=<newest id>: the server holds
// the request until there is a comment or 25 s pass).
//
// The HTML inserted comes from this site's own templates (the proved
// escaper and Markdown renderer); it is parsed in a <template>, so nothing
// in it runs.
"use strict";
(() => {
  const thread = document.getElementById("thread");
  let last = thread ? Number(thread.dataset.last) || 0 : 0;
  let wake = null; // resolves the poll loop's pause

  const sleep = (ms) => new Promise((r) => { wake = r; setTimeout(r, ms); });

  async function post(form, extra) {
    const body = new URLSearchParams(new FormData(form));
    for (const [k, v] of Object.entries(extra)) body.set(k, v);
    return fetch(form.action, { method: "POST", body, credentials: "same-origin" });
  }

  function note(form, msg) {
    let p = form.querySelector(".form-note");
    if (!p) {
      p = document.createElement("p");
      p.className = "form-note meta";
      form.appendChild(p);
    }
    p.textContent = msg;
  }

  document.addEventListener("submit", async (ev) => {
    const form = ev.target;
    const like = form.closest("#social") && form.action.includes("/like/");
    const comment = form.classList.contains("cform") && form.closest("#comments");
    if (!like && !comment) return;
    ev.preventDefault();
    const btn = form.querySelector("button");
    if (btn) btn.disabled = true;
    try {
      const r = await post(form, { frag: "1" });
      if (like && r.ok && (r.headers.get("content-type") || "").startsWith("text/html")) {
        const social = document.getElementById("social");
        if (social) social.outerHTML = await r.text();
        return;
      }
      if (comment && r.ok) {
        form.reset();
        note(form, "");
        if (wake) wake(); // the live update brings it in
        return;
      }
      if (comment && r.status === 429) {
        note(form, "That is a lot of comments in a minute. Wait a moment and send it again.");
        return;
      }
    } catch (e) {
      // Offline or refused: fall back to a normal submission below.
    } finally {
      if (btn) btn.disabled = false;
    }
    form.submit();
  });

  // A link to a comment inside a collapsed thread opens the thread.
  function reveal(id) {
    const el = document.getElementById(id);
    for (let d = el && el.parentElement; d; d = d.parentElement) if (d.tagName === "DETAILS") d.open = true;
    if (el) el.scrollIntoView();
  }
  if (/^#c\d+$/.test(location.hash)) reveal(location.hash.slice(1));

  function insert(html) {
    const tpl = document.createElement("template");
    tpl.innerHTML = html;
    for (const c of [...tpl.content.children]) {
      if (!c.classList.contains("comment") || !/^c\d+$/.test(c.id)) continue;
      last = Math.max(last, Number(c.id.slice(1)));
      if (document.getElementById(c.id)) continue;
      const parent = document.getElementById("c" + c.dataset.parent);
      const into = parent ? parent.querySelector(":scope > details.replies") : null;
      c.classList.add("new");
      (into || thread).appendChild(c);
    }
  }

  async function poll() {
    for (;;) {
      if (document.hidden) {
        await new Promise((r) => document.addEventListener("visibilitychange", r, { once: true }));
        continue;
      }
      try {
        const r = await fetch(`/live/${thread.dataset.post}?after=${last}`, { credentials: "same-origin" });
        if (r.status === 200) insert(await r.text());
        else if (r.status === 429) await sleep(20000 + Math.random() * 10000);
        else if (r.status !== 204) await sleep(15000);
      } catch (e) {
        await sleep(5000);
      }
    }
  }
  if (thread && thread.dataset.post) poll();
})();
