// A Fugue list CRDT for the browser: the same algorithm and operation
// format as src/crdt.bend (the proved reference), written for speed.
//
// Why a second implementation: Bend's JS output rebuilds the tree and walks
// the whole document on every edit (177 ms per keystroke at 10k
// characters, 2.5 s at 100k). This one keeps the tree and the document
// order and integrates each operation incrementally.
//
// Why it can be trusted: tests/fugue_diff.py runs random multi-replica
// histories through both and requires identical text (differential
// fuzzing against the reference whose merge laws are proved).
//
// Operation: [ctr, rep, kind, pctr, prep, side, ch]; kind 0 insert (side 0
// left, 1 right child of (pctr, prep); (0, 0) is the root), kind 1 delete
// of (pctr, prep). Siblings are ordered by (ctr, rep, ch) ascending, like
// the reference's state order.

const ROOT = "0,0";

export class Doc {
  constructor() {
    const root = { id: ROOT, c: 0, r: 0, ch: 0, dead: true, left: [], right: [], parent: null };
    this.nodes = new Map([[ROOT, root]]);
    this.order = [];          // document order, tombstones included (not the root)
    this.dead = new Set();    // deleted ids (also for deletes that arrive first)
    this.orphans = new Map(); // parent id -> inserts waiting for their parent
    this.seen = new Set();    // operation keys already applied
    this.maxCtr = 0;
  }

  static key(op) {
    return op.join(".");
  }

  // Applies operations. Many at once (loading, a burst from other editors,
  // a paste) only update the tree, then rebuild the order in one pass:
  // placing each one individually costs O(n), so loading would be O(n^2).
  applyAll(ops) {
    const batch = ops.length > 32;
    let changed = false;
    for (const op of ops) changed = this.apply(op, !batch) || changed;
    if (batch && changed) this.rebuild(); // (a reply is often only our own operations)
    return changed;
  }

  // The document order, from the tree, in one iterative in-order pass.
  rebuild() {
    const out = [];
    const stack = [[this.nodes.get(ROOT), 0]];
    while (stack.length) {
      const top = stack[stack.length - 1];
      const n = top[0];
      if (top[1] === 0) {
        top[1] = 1;
        for (let i = n.left.length - 1; i >= 0; i--) stack.push([n.left[i], 0]);
      } else if (top[1] === 1) {
        top[1] = 2;
        if (n.id !== ROOT) out.push(n);
        for (let i = n.right.length - 1; i >= 0; i--) stack.push([n.right[i], 0]);
      } else {
        stack.pop();
      }
    }
    this.order = out;
  }

  // Applies one operation (placed in the order unless `place` is false).
  // Returns true if the document may have changed.
  apply(op, place = true) {
    const k = Doc.key(op);
    if (this.seen.has(k)) return false;
    const [c, r, kind, pc, pr, side, ch] = op;
    const id = c + "," + r;
    // Ids are unique per document (the server enforces it); a conflicting
    // duplicate is ignored, first one wins.
    if (kind === 0 && this.nodes.has(id)) return false;
    this.seen.add(k);
    if (c > this.maxCtr) this.maxCtr = c;
    if (kind === 1) {
      const target = pc + "," + pr;
      this.dead.add(target);
      const n = this.nodes.get(target);
      if (n) n.dead = true;
      return true;
    }
    const pid = pc + "," + pr;
    const parent = this.nodes.get(pid);
    const node = { id, c, r, ch, side, dead: this.dead.has(id), left: [], right: [], parent: null };
    if (!parent) {
      if (!this.orphans.has(pid)) this.orphans.set(pid, []);
      this.orphans.get(pid).push(node);
      return false;
    }
    this.attach(parent, node, place);
    return true;
  }

  static before(a, b) {
    return a.c !== b.c ? a.c < b.c : a.r !== b.r ? a.r < b.r : a.ch < b.ch;
  }

  first(n) {
    while (n.left.length) n = n.left[0];
    return n;
  }

  last(n) {
    while (n.right.length) n = n.right[n.right.length - 1];
    return n;
  }

  attach(parent, node, place = true) {
    node.parent = parent;
    // A delete may have arrived while this node waited for its parent.
    node.dead = this.dead.has(node.id);
    this.nodes.set(node.id, node);
    const kids = node.side === 0 ? parent.left : parent.right;
    let i = 0;
    while (i < kids.length && Doc.before(kids[i], node)) i++;
    kids.splice(i, 0, node);
    // In-order position (the root has none: it sits between its left and
    // right subtrees).
    //   left child:  before the subtree of the next larger left sibling,
    //                else just before the parent (after smaller siblings);
    //   right child: after the subtree of the previous smaller right
    //                sibling, else just after the parent.
    const isRoot = parent.id === ROOT;
    let at = 0;
    if (!place) {
      // placed later by rebuild()
    } else if (node.side === 0) {
      if (i + 1 < kids.length) at = this.order.indexOf(this.first(kids[i + 1]));
      else if (!isRoot) at = this.order.indexOf(parent);
      else at = i > 0 ? this.order.indexOf(this.last(kids[i - 1])) + 1 : 0;
    } else if (i > 0) {
      at = this.order.indexOf(this.last(kids[i - 1])) + 1;
    } else if (!isRoot) {
      at = this.order.indexOf(parent) + 1;
    } else {
      at = parent.left.length ? this.order.indexOf(this.last(parent.left[parent.left.length - 1])) + 1 : 0;
    }
    if (place) this.order.splice(at, 0, node);
    const waiting = this.orphans.get(node.id);
    if (waiting) {
      this.orphans.delete(node.id);
      for (const w of waiting) if (!this.nodes.has(w.id)) this.attach(node, w, place);
    }
  }

  text() {
    let s = "";
    for (const n of this.order) if (!n.dead) s += String.fromCodePoint(n.ch);
    return s;
  }

  // The operations for deleting `del` code points at `pos` and inserting
  // `ins` there, by replica rep. Applies them and returns them.
  edit(rep, pos, del, ins) {
    const ops = [];
    let ctr = this.maxCtr + 1;
    // The node before the insertion point: the pos-th live node, or root.
    let i = 0, seen = 0, before = this.nodes.get(ROOT), idx = -1;
    while (seen < pos && i < this.order.length) {
      if (!this.order[i].dead) {
        seen++;
        before = this.order[i];
        idx = i;
      }
      i++;
    }
    // Deletes: the next `del` live nodes after it.
    let j = idx + 1, n = del;
    while (n > 0 && j < this.order.length) {
      if (!this.order[j].dead) {
        ops.push([ctr++, rep, 1, this.order[j].c, this.order[j].r, 0, 0]);
        n--;
      }
      j++;
    }
    // Inserts: the first by the Fugue rule, the rest as right children.
    const chars = Array.from(ins);
    if (chars.length) {
      const next = this.order[idx + 1];
      let p, side;
      if (before.right.length === 0 || next === undefined) {
        p = before;
        side = 1;
      } else {
        p = next;
        side = 0;
      }
      let pc = p.c, pr = p.r;
      for (let k = 0; k < chars.length; k++) {
        const op = [ctr, rep, 0, pc, pr, k === 0 ? side : 1, chars[k].codePointAt(0)];
        ops.push(op);
        pc = ctr;
        pr = rep;
        ctr++;
      }
    }
    this.applyAll(ops);
    return ops;
  }

  static encode(ops) {
    let s = "";
    for (const op of ops) s += op.join(".") + ";";
    return s;
  }

  // Parses the wire format; returns null if malformed.
  static decode(s) {
    const ops = [];
    if (!s) return ops;
    for (const part of s.split(";")) {
      if (!part) continue;
      const f = part.split(".");
      if (f.length !== 7) return null;
      const op = f.map(Number);
      if (op.some((x) => !Number.isInteger(x) || x < 0)) return null;
      ops.push(op);
    }
    return ops;
  }
}
