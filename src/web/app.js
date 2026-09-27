// The site's own small script, on every page: what only the browser can
// do well (CLAUDE.md: vanilla JS for purely client-side interaction).
// Everything works without it; with it:
//
// - Forms with data-confirm ask first, in a dialog that looks like the
//   site (not the browser's confirm box).
// - A form sent the ordinary way (a page load follows) shows its button as
//   busy and cannot be sent twice. Datastar's forms (data-on:submit) show
//   their own state.
// - Page loads cross-fade (CSS view transitions, app.css) and links are
//   fetched ahead on hover (speculation rules, in the page's head).

const dialog = document.createElement("dialog");
dialog.className = "modal";
dialog.setAttribute("aria-labelledby", "confirm-text");
dialog.innerHTML =
  '<form method="dialog" class="stack"><p id="confirm-text"></p><div class="row">' +
  '<button value="no" class="quiet" autofocus>Cancel</button><button value="yes" class="danger-btn">OK</button></div></form>';
let confirmed = null; // the form (and button) the dialog said yes to

document.addEventListener(
  "submit",
  (ev) => {
    const form = ev.target;
    const by = ev.submitter || null;
    const q = (by && by.dataset.confirm) || form.dataset.confirm;
    if (q && confirmed !== form) {
      ev.preventDefault();
      ev.stopImmediatePropagation(); // Datastar's handler too, until confirmed
      ask(q, (by && by.dataset.ok) || form.dataset.ok || "OK", () => {
        confirmed = form;
        form.requestSubmit(by);
        confirmed = null;
      });
      return;
    }
    // Forms that send themselves: Datastar's, the editor's (data-js), dialogs.
    if (ev.defaultPrevented || form.hasAttribute("data-on:submit") || form.hasAttribute("data-js") || form.method === "dialog") return;
    // An ordinary submit: a page load is coming.
    if (form.dataset.sending === "1") {
      ev.preventDefault();
      return;
    }
    form.dataset.sending = "1";
    if (by) by.setAttribute("aria-busy", "true");
    // After the form's data is taken (a disabled button would be left out).
    setTimeout(() => {
      for (const b of form.querySelectorAll("button")) b.disabled = true;
    }, 0);
  },
  true,
);

// Back to a page kept in the back/forward cache: its forms work again.
window.addEventListener("pageshow", (ev) => {
  if (!ev.persisted) return;
  for (const f of document.querySelectorAll("form[data-sending]")) {
    f.removeAttribute("data-sending");
    for (const b of f.querySelectorAll("button")) {
      b.disabled = false;
      b.removeAttribute("aria-busy");
    }
  }
});

function ask(text, ok, then) {
  if (!dialog.isConnected) document.body.appendChild(dialog);
  dialog.querySelector("#confirm-text").textContent = text;
  dialog.querySelector("button[value=yes]").textContent = ok;
  dialog.returnValue = "";
  dialog.onclose = () => {
    if (dialog.returnValue === "yes") then();
  };
  dialog.showModal();
}
