// Undo and redo for the editor: this writer's own changes only, in the
// whole text (the textarea shows only a window of it, and the browser's own
// undo knows nothing of other writers). Pure: tested in node
// (tests/history_test.mjs).
//
// A step {p, del, ins}: at p, the text del was replaced by ins. The undo
// list is last in, first out: each step's position holds in the text as it
// will be once the steps above it are undone (so this writer's own later
// edits never disturb it). The redo list likewise.
//
// Another writer's change arrives in the current text. Going down a list,
// it moves each step it falls before, and is carried into the coordinates
// of the step below (the text as it was before that step). A change that
// touches a step's text makes the step stale: undo will not touch that text
// (it would delete their words), and when undo reaches a stale step it
// drops it, carrying the change the step made permanent down to the steps
// below. Before any undo or redo the text is checked to be exactly what the
// step expects; if not, the step is dropped the same way.
//
// Typing and deleting merge into one step a word at a time, and not across
// a pause of MERGE_MS, as the browsers' own undo does.

const LIMIT = 1000;
const MERGE_MS = 1500;

export class History {
  constructor() {
    this.undos = [];
    this.redos = [];
  }

  // A change made here: [p, p + del.length) held del and now holds ins.
  // now: a timestamp (ms), or null for a change that is a step of its own.
  // group: which input method's composition this is part of (0: none);
  // a composition is one step.
  record(p, del, ins, before, after, now, group = 0) {
    this.redos = [];
    const top = this.undos[this.undos.length - 1];
    if (group && top && !top.stale && top.group === group && p >= top.p && p + del.length <= top.p + top.ins.length) {
      // A composition rewrites its own text: still one step.
      const k = p - top.p;
      top.ins = top.ins.slice(0, k) + ins + top.ins.slice(k + del.length);
      top.after = after;
      top.t = now === null ? top.t : now;
      return;
    }
    if (!group && top && !top.stale && now !== null && now - top.t <= MERGE_MS && joins(top, p, del, ins)) {
      if (ins !== "") top.ins += ins;
      else if (p === top.p) top.del += del;
      else {
        top.p = p;
        top.del = del + top.del;
      }
      top.after = after;
      top.t = now;
      return;
    }
    const st = step(p, del, ins, before, after, now === null ? -Infinity : now);
    st.group = group;
    this.undos.push(st);
    if (this.undos.length > LIMIT) this.undos.shift();
  }

  // Another writer's change: [p, p + del) became insLen units.
  remote(p, del, insLen) {
    carry(this.undos, true, this.undos.length - 1, p, del, insLen);
    carry(this.redos, false, this.redos.length - 1, p, del, insLen);
  }

  // The change undo makes, {p, del, ins, sel}, or null. at(p, n): the text
  // at [p, p + n) now (null: trust the steps; tests only).
  undo(at) {
    for (;;) {
      const s = this.undos.pop();
      if (!s) return null;
      if (s.stale || (at && at(s.p, s.ins.length) !== s.ins)) {
        drop(this.undos, true, s);
        continue;
      }
      this.redos.push(s);
      return { p: s.p, del: s.ins.length, ins: s.del, sel: s.before };
    }
  }

  redo(at) {
    for (;;) {
      const s = this.redos.pop();
      if (!s) return null;
      if (s.stale || (at && at(s.p, s.del.length) !== s.del)) {
        drop(this.redos, false, s);
        continue;
      }
      this.undos.push(s);
      return { p: s.p, del: s.del.length, ins: s.ins, sel: s.after };
    }
  }
}

function step(p, del, ins, before, after, t) {
  return { p, del, ins, before, after, t, stale: false, cur: 0, oth: 0 };
}

// Typing on at the end of the last typing, which may have replaced a
// selection (a step is a word with the spaces before it: a space after a
// word starts the next one; a line break ends a step); deleting on
// backwards (Backspace) or forwards (Delete) from the last deletion.
function joins(top, p, del, ins) {
  if (del === "" && ins !== "" && top.ins !== "" && !top.group) {
    if (p !== top.p + top.ins.length || ins.includes("\n") || top.ins.endsWith("\n")) return false;
    return !(!/\s$/.test(top.ins) && /^\s/.test(ins));
  }
  if (ins === "" && top.ins === "" && del !== "" && top.del !== "" && !del.includes("\n")) {
    return p + del.length === top.p || p === top.p;
  }
  return false;
}

// The length of a step's text in the current text (the side it is on:
// ins for a done step, del for an undone one) and on the other side.
function cur(s, done) {
  return s.stale ? s.cur : done ? s.ins.length : s.del.length;
}
function oth(s, done) {
  return s.stale ? s.oth : done ? s.del.length : s.ins.length;
}

// Carries the change [p, p + d) -> l (in the coordinates of list[k]'s
// current side) down the list from index k.
function carry(list, done, k, p, d, l) {
  for (; k >= 0; k--) {
    const s = list[k];
    const c = cur(s, done), o = oth(s, done);
    if (p + d <= s.p) {
      s.p += l - d;
    } else if (p >= s.p + c) {
      p -= c - o;
    } else {
      // It touches the step's text: stale, and its region takes the change
      // in (the steps below see only the step's region change, later).
      const u0 = Math.min(p, s.p), u1 = Math.max(s.p + c, p + d);
      s.cur = u1 - u0 + l - d;
      s.oth = u1 - (c - o) - u0;
      s.p = u0;
      s.stale = true;
      return;
    }
  }
}

// A step undo (redo) cannot make: the change it made stays, so the steps
// below it move by it.
function drop(list, done, s) {
  const c = cur(s, done), o = oth(s, done);
  carry(list, done, list.length - 1, s.p, o, c);
}
