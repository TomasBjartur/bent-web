// A Fugue list CRDT for the browser: the same algorithm and operation
// format as src/crdt.bend (the proved reference), written for speed and
// memory on long documents.
//
// Why a second implementation: Bend's JS output rebuilds the tree and walks
// the whole document on every edit. Why it can be trusted:
// tests/fugue_diff.mjs runs random multi-replica histories through this,
// the reference and the server's C materializer, and requires the same
// text (differential fuzzing against the reference whose merge laws are
// proved).
//
// Operation: (ctr, rep, kind, pctr, prep, side, ch); kind 0 insert (side 0
// left, 1 right child of (pctr, prep); (0, 0) is the root), kind 1 delete
// of (pctr, prep). Siblings are ordered by (ctr, rep, ch) ascending, like
// the reference's state order.
//
// DATA LAYOUT (a novel is millions of characters; one object per character
// cost ~400 bytes and seconds of GC at 1 MB):
// - Nodes are integer indexes into typed-array columns (struct of arrays):
//   id, character, flags, and the tree as first-left-child, first-right-
//   child and next-sibling links. ~42 bytes a character in all.
// - Ids map to nodes through an open-addressing hash table of node indexes
//   (no string keys, no Map).
// - The document order (tombstones included) is kept in blocks of up to
//   BLOCK node indexes, all in one Int32Array pool; a Fenwick tree over the
//   blocks' live lengths finds a position in O(log blocks + BLOCK).
// - Positions are UTF-16 units, the textarea's (a character above U+FFFF is
//   2 wide), so the editor never converts.
// - Operations travel as columns too (Ops), parsed straight from the wire.
// No recursion anywhere: the tree can be a million deep (typed text is a
// chain of right children).

const ROOT = 0;
const BLOCK = 512;         // node indexes per order block (tests use tiny ones)
const DEAD = 2;            // flags: bit 0 side (1 right), bit 1 deleted
// A batch this large (and a sizeable part of the document) is merged into
// the tree first and the order rebuilt in one pass, rather than placed one
// operation at a time.
const BATCH_MIN = 256;

// Operations as records: one flat Uint32Array, 7 numbers per operation
// (ctr, rep, kind, pctr, prep, side, ch). One array of one type keeps every
// read and write monomorphic.
export const F = 7;

export class Ops {
  constructor(cap = 16) {
    this.n = 0;
    this.a = new Uint32Array(cap * F);
  }

  grow(need) {
    if (need * F <= this.a.length) return;
    let cap = (this.a.length / F) * 2;
    while (cap < need) cap *= 2;
    const a = new Uint32Array(cap * F);
    a.set(this.a.subarray(0, this.n * F));
    this.a = a;
  }

  push(ctr, rep, kind, pctr, prep, side, ch) {
    if ((this.n + 1) * F > this.a.length) this.grow(this.n + 1);
    const a = this.a, i = this.n++ * F;
    a[i] = ctr;
    a[i + 1] = rep;
    a[i + 2] = kind;
    a[i + 3] = pctr;
    a[i + 4] = prep;
    a[i + 5] = side;
    a[i + 6] = ch;
  }

  // Operations [a, b) as a new batch.
  slice(a, b) {
    const o = new Ops(Math.max(1, b - a));
    o.a.set(this.a.subarray(a * F, b * F));
    o.n = b - a;
    return o;
  }

  append(o) {
    this.grow(this.n + o.n);
    this.a.set(o.a.subarray(0, o.n * F), this.n * F);
    this.n += o.n;
  }

  static concat(list) {
    let n = 0;
    for (const o of list) n += o.n;
    const out = new Ops(Math.max(1, n));
    for (const o of list) out.append(o);
    return out;
  }

  // The wire format: "ctr.rep.kind.pctr.prep.side.ch;" per operation.
  encode(from = 0, to = this.n) {
    const parts = [];
    const a = this.a;
    let s = "";
    for (let i = from * F, e = to * F; i < e; i += F) {
      s += a[i] + "." + a[i + 1] + "." + a[i + 2] + "." + a[i + 3] + "." + a[i + 4] + "." + a[i + 5] + "." + a[i + 6] + ";";
      if (s.length > 65536) {
        parts.push(s);
        s = "";
      }
    }
    parts.push(s);
    return parts.join("");
  }

  // Parses the wire format (as the server does, src/c/ops_core.h): numbers
  // of at most 10 digits within their field, ctr and rep >= 1, no
  // surrogate code points. Null if malformed.
  static decode(s) {
    let count = 0;
    for (let i = s.indexOf(";"); i >= 0; i = s.indexOf(";", i + 1)) count++;
    const o = new Ops(Math.max(1, count));
    const a = o.a;
    let field = 0, v = 0, digits = 0, at = 0;
    for (let i = 0, len = s.length; i < len; i++) {
      const c = s.charCodeAt(i);
      if (c >= 48 && c <= 57) {
        if (++digits > 10) return null;
        v = v * 10 + (c - 48);
      } else if (c === 46 || c === 59) {
        if (digits === 0 || field >= F || v > FIELD_MAX[field]) return null;
        a[at + field] = v;
        field++;
        v = 0;
        digits = 0;
        if (c === 59) {
          if (field !== F || a[at] === 0 || a[at + 1] === 0 || (a[at + 6] >= 0xd800 && a[at + 6] <= 0xdfff)) return null;
          at += F;
          field = 0;
        }
      } else return null;
    }
    if (field !== 0 || digits !== 0) return null;
    o.n = at / F;
    return o;
  }

  // For tests: operations as arrays, and back.
  toArrays() {
    const out = [];
    for (let i = 0; i < this.n; i++) out.push(Array.from(this.a.subarray(i * F, i * F + F)));
    return out;
  }

  static fromArrays(list) {
    const o = new Ops(Math.max(1, list.length));
    for (const a of list) o.push(a[0], a[1], a[2], a[3], a[4], a[5], a[6]);
    return o;
  }
}

const FIELD_MAX = [4294967295, 4294967295, 1, 4294967295, 4294967295, 1, 1114111];

const width = (ch) => (ch > 0xffff ? 2 : 1);

export class Doc {
  constructor(block = BLOCK) {
    this.B = block;
    this.cap = 0;
    this.n = 1;             // nodes, the root included
    this.alloc(1024);
    this.flags[ROOT] = DEAD;
    this.firstL[ROOT] = this.firstR[ROOT] = this.next[ROOT] = -1;
    this.block[ROOT] = -1;
    // Hash: node index + 1 per slot, 0 empty.
    this.slots = new Int32Array(2048);
    this.used = 0;
    // Order blocks: pool[b * this.B + k], the k-th node of block b; seq
    // lists blocks in document order; pos[b] is b's index in seq.
    this.nb = 0;            // blocks allocated
    this.bcap = 0;
    this.balloc(8);
    this.seq = new Int32Array(8);
    this.ns = 0;            // blocks in seq
    this.fen = new Int32Array(9); // Fenwick over seq: live widths
    this.live = 0;          // live UTF-16 units
    this.maxCtr = 0;
    this.orphans = new Map(); // "pctr,prep" -> [[ctr, rep, side, ch]] waiting for their parent
    this.early = new Set();   // "ctr,rep" deleted before it arrived
  }

  get length() {
    return this.live;
  }

  // NODES
  alloc(cap) {
    const grow = (a, T) => {
      const b = new T(cap);
      if (a) b.set(a.subarray(0, this.n));
      return b;
    };
    this.ctr = grow(this.ctr, Uint32Array);
    this.rep = grow(this.rep, Uint32Array);
    this.ch = grow(this.ch, Uint32Array);
    this.flags = grow(this.flags, Uint8Array);
    this.firstL = grow(this.firstL, Int32Array);
    this.firstR = grow(this.firstR, Int32Array);
    this.next = grow(this.next, Int32Array);
    this.block = grow(this.block, Int32Array);
    this.cap = cap;
  }

  newNode(ctr, rep, side, ch, dead) {
    if (this.n === this.cap) this.alloc(this.cap * 2);
    const i = this.n++;
    this.ctr[i] = ctr;
    this.rep[i] = rep;
    this.ch[i] = ch;
    this.flags[i] = side | (dead ? DEAD : 0);
    this.firstL[i] = this.firstR[i] = this.next[i] = -1;
    this.block[i] = -1;
    this.hashPut(i);
    return i;
  }

  // HASH (open addressing, linear probing, power-of-two size)
  static hash(ctr, rep) {
    return (Math.imul(ctr, 0x9e3779b1) ^ Math.imul(rep ^ (rep >>> 15), 0x85ebca77)) >>> 0;
  }

  find(ctr, rep) {
    if (ctr === 0 && rep === 0) return ROOT;
    const s = this.slots, mask = s.length - 1;
    for (let h = Doc.hash(ctr, rep) & mask; ; h = (h + 1) & mask) {
      const v = s[h];
      if (v === 0) return -1;
      if (this.ctr[v - 1] === ctr && this.rep[v - 1] === rep) return v - 1;
    }
  }

  hashPut(i) {
    if ((this.used + 1) * 2 > this.slots.length) this.rehash(this.slots.length * 2);
    const s = this.slots, mask = s.length - 1;
    let h = Doc.hash(this.ctr[i], this.rep[i]) & mask;
    while (s[h] !== 0) h = (h + 1) & mask;
    s[h] = i + 1;
    this.used++;
  }

  rehash(size) {
    const old = this.slots;
    this.slots = new Int32Array(size);
    const mask = size - 1;
    for (let k = 0; k < old.length; k++) {
      const v = old[k];
      if (v === 0) continue;
      let h = Doc.hash(this.ctr[v - 1], this.rep[v - 1]) & mask;
      while (this.slots[h] !== 0) h = (h + 1) & mask;
      this.slots[h] = v;
    }
  }

  // Sibling order: (ctr, rep, ch) ascending.
  before(a, b) {
    if (this.ctr[a] !== this.ctr[b]) return this.ctr[a] < this.ctr[b];
    if (this.rep[a] !== this.rep[b]) return this.rep[a] < this.rep[b];
    return this.ch[a] < this.ch[b];
  }

  // The first and last node of n's subtree in document order.
  first(n) {
    while (this.firstL[n] !== -1) n = this.firstL[n];
    return n;
  }

  last(n) {
    for (let r = this.firstR[n]; r !== -1; r = this.firstR[n]) {
      while (this.next[r] !== -1) r = this.next[r];
      n = r;
    }
    return n;
  }

  // Links node into its parent's sorted children; answers the sibling
  // before it (-1 if first) and after it (-1 if last).
  link(parent, node) {
    const right = (this.flags[node] & 1) === 1;
    let prev = -1;
    let k = right ? this.firstR[parent] : this.firstL[parent];
    while (k !== -1 && this.before(k, node)) {
      prev = k;
      k = this.next[k];
    }
    this.next[node] = k;
    if (prev === -1) {
      if (right) this.firstR[parent] = node;
      else this.firstL[parent] = node;
    } else this.next[prev] = node;
    this.linkPrev = prev;
    return k;
  }

  // BLOCKS AND THE ORDER
  balloc(cap) {
    const pool = new Int32Array(cap * this.B);
    const len = new Int32Array(cap), lv = new Int32Array(cap), pos = new Int32Array(cap);
    if (this.pool) {
      pool.set(this.pool);
      len.set(this.blen);
      lv.set(this.blive);
      pos.set(this.bpos);
    }
    this.pool = pool;
    this.blen = len;
    this.blive = lv;
    this.bpos = pos;
    this.bcap = cap;
  }

  newBlock() {
    if (this.nb === this.bcap) this.balloc(this.bcap * 2);
    const b = this.nb++;
    this.blen[b] = 0;
    this.blive[b] = 0;
    return b;
  }

  // Puts block b into seq at index at.
  seqInsert(at, b) {
    if (this.ns === this.seq.length) {
      const s = new Int32Array(this.seq.length * 2);
      s.set(this.seq);
      this.seq = s;
    }
    this.seq.copyWithin(at + 1, at, this.ns);
    this.seq[at] = b;
    this.ns++;
    for (let i = at; i < this.ns; i++) this.bpos[this.seq[i]] = i;
    this.fenBuild();
  }

  fenBuild() {
    const n = this.ns;
    if (this.fen.length < n + 1) this.fen = new Int32Array(Math.max(n + 1, this.fen.length * 2));
    const f = this.fen;
    f.fill(0, 0, n + 1);
    for (let i = 1; i <= n; i++) {
      f[i] += this.blive[this.seq[i - 1]];
      const j = i + (i & -i);
      if (j <= n) f[j] += f[i];
    }
  }

  fenAdd(i, d) {
    for (let k = i + 1; k <= this.ns; k += k & -k) this.fen[k] += d;
  }

  // Live units in seq[0, i).
  fenSum(i) {
    let s = 0;
    for (let k = i; k > 0; k -= k & -k) s += this.fen[k];
    return s;
  }

  // The seq index i with fenSum(i) < p <= fenSum(i + 1), for 1 <= p <= live.
  fenFind(p) {
    let i = 0;
    let step = 1;
    while (step * 2 <= this.ns) step *= 2;
    for (; step > 0; step >>= 1) {
      if (i + step <= this.ns && this.fen[i + step] < p) {
        i += step;
        p -= this.fen[i];
      }
    }
    return i;
  }

  // Index of node n within its block.
  offsetOf(n) {
    const b = this.block[n], base = b * this.B, len = this.blen[b], pool = this.pool;
    for (let k = 0; k < len; k++) if (pool[base + k] === n) return k;
    throw new Error("fugue: node not in its block");
  }

  // Puts node n into the order at (block b, offset k).
  placeAt(b, k, n) {
    if (this.blen[b] === this.B) {
      // Split: the upper half goes to a new block after b.
      const c = this.newBlock();
      const half = this.B >> 1, pool = this.pool;
      pool.copyWithin(c * this.B, b * this.B + half, b * this.B + this.B);
      let moved = 0;
      for (let j = 0; j < this.B - half; j++) {
        const m = pool[c * this.B + j];
        this.block[m] = c;
        if ((this.flags[m] & DEAD) === 0) moved += width(this.ch[m]);
      }
      this.blen[b] = half;
      this.blen[c] = this.B - half;
      this.blive[b] -= moved;
      this.blive[c] = moved;
      this.seqInsert(this.bpos[b] + 1, c);
      if (k > half) {
        b = c;
        k -= half;
      }
    }
    const base = b * this.B;
    this.pool.copyWithin(base + k + 1, base + k, base + this.blen[b]);
    this.pool[base + k] = n;
    this.blen[b]++;
    this.block[n] = b;
    if ((this.flags[n] & DEAD) === 0) {
      const w = width(this.ch[n]);
      this.blive[b] += w;
      this.fenAdd(this.bpos[b], w);
      this.live += w;
    }
  }

  placeBefore(x, n) {
    this.placeAt(this.block[x], this.offsetOf(x), n);
  }

  placeAfter(x, n) {
    this.placeAt(this.block[x], this.offsetOf(x) + 1, n);
  }

  // At the very start of the order.
  placeFirst(n) {
    if (this.ns === 0) this.seqInsert(0, this.newBlock());
    this.placeAt(this.seq[0], 0, n);
  }

  // The node after n in the order (tombstones included), or -1; n = ROOT:
  // the first node.
  succ(n) {
    let b, k;
    if (n === ROOT) {
      if (this.ns === 0) return -1;
      b = this.seq[0];
      k = 0;
    } else {
      b = this.block[n];
      k = this.offsetOf(n) + 1;
    }
    while (k >= this.blen[b]) {
      const i = this.bpos[b] + 1;
      if (i >= this.ns) return -1;
      b = this.seq[i];
      k = 0;
    }
    return this.pool[b * this.B + k];
  }

  // UTF-16 position of node n (its start) in the live text.
  posOf(n) {
    const b = this.block[n], base = b * this.B, pool = this.pool;
    let p = this.fenSum(this.bpos[b]);
    for (let k = 0; ; k++) {
      const m = pool[base + k];
      if (m === n) return p;
      if ((this.flags[m] & DEAD) === 0) p += width(this.ch[m]);
    }
  }

  // The live node whose end is at position p (1 <= p <= live): the node
  // before an insertion at p. A p inside a surrogate pair rounds up.
  nodeEndingAt(p) {
    const i = this.fenFind(p);
    const b = this.seq[i], base = b * this.B, pool = this.pool;
    let q = p - this.fenSum(i);
    for (let k = 0; ; k++) {
      const m = pool[base + k];
      if ((this.flags[m] & DEAD) === 0) {
        q -= width(this.ch[m]);
        if (q <= 0) return m;
      }
    }
  }

  // Where a new node goes in the order, from its place in the tree (the
  // in-order position; see the reference, src/crdt.bend).
  place(parent, n) {
    const after = this.link(parent, n);
    const prev = this.linkPrev;
    const isRoot = parent === ROOT;
    if ((this.flags[n] & 1) === 0) {
      if (after !== -1) this.placeBefore(this.first(after), n);
      else if (!isRoot) this.placeBefore(parent, n);
      else if (prev !== -1) this.placeAfter(this.last(prev), n);
      else this.placeFirst(n);
    } else if (prev !== -1) this.placeAfter(this.last(prev), n);
    else if (!isRoot) this.placeAfter(parent, n);
    else {
      // The smallest right child of the root: after the root's left subtree.
      let l = this.firstL[ROOT];
      if (l === -1) this.placeFirst(n);
      else {
        while (this.next[l] !== -1) l = this.next[l];
        this.placeAfter(this.last(l), n);
      }
    }
  }

  // Rebuilds the order from the tree in one in-order pass (after a batch).
  rebuild() {
    this.nb = 0;
    this.ns = 0;
    this.live = 0;
    const need = Math.ceil(this.n / this.B) + 2;
    if (this.bcap < need) {
      this.pool = null;
      this.balloc(need);
    }
    if (this.seq.length < need) this.seq = new Int32Array(need);
    let b = -1;
    const emit = (m) => {
      if (b === -1 || this.blen[b] === this.B) {
        b = this.newBlock();
        this.seq[this.ns] = b;
        this.bpos[b] = this.ns++;
      }
      this.pool[b * this.B + this.blen[b]++] = m;
      this.block[m] = b;
      if ((this.flags[m] & DEAD) === 0) {
        const w = width(this.ch[m]);
        this.blive[b] += w;
        this.live += w;
      }
    };
    // Iterative in-order: frames (node, phase, child cursor). The last right
    // child replaces its parent's frame, so a chain stays one frame deep.
    const cap = 64;
    let sn = new Int32Array(cap), sp = new Uint8Array(cap), sc = new Int32Array(cap);
    let top = 0;
    sn[0] = ROOT;
    sp[0] = 0;
    sc[0] = this.firstL[ROOT];
    top = 1;
    while (top > 0) {
      const f = top - 1;
      const c = sc[f];
      if (c !== -1) {
        sc[f] = this.next[c];
        if (sp[f] === 1 && this.next[c] === -1) {
          // Tail: replace this frame.
          sn[f] = c;
          sp[f] = 0;
          sc[f] = this.firstL[c];
          continue;
        }
        if (top === sn.length) {
          const g = (a) => {
            const x = new a.constructor(a.length * 2);
            x.set(a);
            return x;
          };
          sn = g(sn);
          sp = g(sp);
          sc = g(sc);
        }
        sn[top] = c;
        sp[top] = 0;
        sc[top] = this.firstL[c];
        top++;
      } else if (sp[f] === 0) {
        if (sn[f] !== ROOT) emit(sn[f]);
        sp[f] = 1;
        sc[f] = this.firstR[sn[f]];
      } else top--;
    }
    this.fenBuild();
  }

  // APPLYING OPERATIONS
  // Applies a batch. sink(pos, del, ins), if given, hears each visible
  // change as it happens (positions as of that moment, UTF-16), so a view
  // can follow without re-reading the text. Answers 0 (nothing changed),
  // 1 (changed, all reported to sink) or 2 (changed, too much at once to
  // report: re-read the text).
  apply(ops, sink = null) {
    const batch = ops.n >= BATCH_MIN && ops.n * 8 >= this.n;
    let changed = 0;
    this.sink = batch ? null : sink;
    this.place1 = !batch;
    this.attached = false;
    const a = ops.a;
    for (let i = 0, e = ops.n * F; i < e; i += F) {
      if (this.applyOne(a[i], a[i + 1], a[i + 2], a[i + 3], a[i + 4], a[i + 5], a[i + 6])) changed = 1;
    }
    this.flush();
    this.sink = null;
    // In a batch new nodes are only linked, and deletes not counted: redo the order.
    if (batch && (this.attached || changed)) this.rebuild();
    if (batch && changed) return 2;
    this.place1 = true;
    return changed;
  }

  applyOne(ctr, rep, kind, pctr, prep, side, ch) {
    if (ctr > this.maxCtr) this.maxCtr = ctr;
    if (kind === 1) {
      const t = this.find(pctr, prep);
      if (t <= 0) {
        if (t < 0) this.early.add(pctr + "," + prep);
        return false;
      }
      if (this.flags[t] & DEAD) return false;
      if (this.place1 && this.block[t] !== -1) {
        const w = width(this.ch[t]);
        if (this.sink) this.report(this.posOf(t), w, "");
        const b = this.block[t];
        this.blive[b] -= w;
        this.fenAdd(this.bpos[b], -w);
        this.live -= w;
      }
      this.flags[t] |= DEAD;
      return true;
    }
    if (this.find(ctr, rep) !== -1) return false; // a duplicate id: the first one stands
    const p = this.find(pctr, prep);
    if (p < 0) {
      const k = pctr + "," + prep;
      let w = this.orphans.get(k);
      if (!w) this.orphans.set(k, (w = []));
      w.push([ctr, rep, side, ch]);
      return false;
    }
    return this.attach(p, ctr, rep, side, ch);
  }

  // A node under parent, and the nodes that were waiting for it.
  attach(parent, ctr, rep, side, ch) {
    // The common case: nothing waits for this node, nothing deleted early.
    if (this.orphans.size === 0 && this.early.size === 0) {
      const n = this.newNode(ctr, rep, side, ch, false);
      this.attached = true;
      if (this.place1) {
        this.place(parent, n);
        if (this.sink) this.report(this.posOf(n), 0, String.fromCodePoint(ch));
      } else this.link(parent, n);
      return true;
    }
    const stack = [[parent, ctr, rep, side, ch]];
    let visible = false;
    while (stack.length) {
      const [pa, c, r, s, x] = stack.pop();
      if (this.find(c, r) !== -1) continue;
      const key = c + "," + r;
      const dead = this.early.size > 0 && this.early.delete(key);
      const n = this.newNode(c, r, s, x, dead);
      this.attached = true;
      if (this.place1) {
        this.place(pa, n);
        if (!dead) {
          visible = true;
          if (this.sink) this.report(this.posOf(n), 0, String.fromCodePoint(x));
        }
      } else {
        this.link(pa, n);
        if (!dead) visible = true;
      }
      const waiting = this.orphans.size ? this.orphans.get(key) : undefined;
      if (waiting) {
        this.orphans.delete(key);
        for (const w of waiting) stack.push([n, w[0], w[1], w[2], w[3]]);
      }
    }
    return visible;
  }

  // Changes reported to the sink, adjacent ones joined.
  report(pos, del, ins) {
    const r = this.pend;
    if (r && ins !== "" && r.del === 0 && pos === r.pos + r.ins.length) {
      r.ins += ins;
      return;
    }
    if (r && ins === "" && r.ins === "" && pos === r.pos) {
      r.del += del;
      return;
    }
    if (r && ins === "" && r.ins === "" && pos + del === r.pos) {
      r.pos = pos;
      r.del += del;
      return;
    }
    this.flush();
    this.pend = { pos, del, ins };
  }

  flush() {
    const r = this.pend;
    this.pend = null;
    if (r && this.sink) this.sink(r.pos, r.del, r.ins);
  }

  // LOCAL EDITS
  // The operations for deleting del units at pos and inserting ins there
  // (UTF-16 positions, not inside a surrogate pair), by replica rep.
  // Applies them and returns them.
  edit(rep, pos, del, ins) {
    const ops = new Ops(Math.max(1, ins.length + del));
    let ctr = this.maxCtr + 1;
    pos = Math.max(0, Math.min(pos, this.live));
    const before = pos === 0 ? ROOT : this.nodeEndingAt(pos);
    const after = this.succ(before);
    // Deletes: the live nodes covering the next del units.
    let left = Math.min(del, this.live - pos);
    for (let m = after; left > 0 && m !== -1; m = this.succ(m)) {
      if (this.flags[m] & DEAD) continue;
      ops.push(ctr++, rep, 1, this.ctr[m], this.rep[m], 0, 0);
      left -= width(this.ch[m]);
    }
    // Inserts: the first by the Fugue rule, the rest as right children.
    if (ins.length) {
      let pc, pr, side;
      if (this.firstR[before] === -1 || after === -1) {
        pc = this.ctr[before];
        pr = this.rep[before];
        side = 1;
      } else {
        pc = this.ctr[after];
        pr = this.rep[after];
        side = 0;
      }
      for (let i = 0; i < ins.length; ) {
        const c = ins.codePointAt(i);
        i += width(c);
        if (c >= 0xd800 && c <= 0xdfff) continue; // a lone surrogate: not a character
        ops.push(ctr, rep, 0, pc, pr, side, c);
        pc = ctr;
        pr = rep;
        side = 1;
        ctr++;
      }
    }
    this.apply(ops);
    return ops;
  }

  // The live text.
  text() {
    const out = new Uint16Array(this.live);
    let j = 0;
    const pool = this.pool;
    for (let i = 0; i < this.ns; i++) {
      const b = this.seq[i], base = b * this.B, len = this.blen[b];
      if (this.blive[b] === 0) continue;
      for (let k = 0; k < len; k++) {
        const m = pool[base + k];
        if (this.flags[m] & DEAD) continue;
        const c = this.ch[m];
        if (c > 0xffff) {
          out[j++] = 0xd800 + ((c - 0x10000) >> 10);
          out[j++] = 0xdc00 + ((c - 0x10000) & 0x3ff);
        } else out[j++] = c;
      }
    }
    return utf16(out);
  }

  // Nodes in the order, tombstones included (0: an empty document).
  get size() {
    return this.n - 1;
  }
}

const decoder = typeof TextDecoder === "function" ? new TextDecoder("utf-16le") : null;

function utf16(a) {
  if (decoder && a.length > 64) return decoder.decode(a);
  let s = "";
  for (let i = 0; i < a.length; i += 8192) s += String.fromCharCode.apply(null, a.subarray(i, Math.min(a.length, i + 8192)));
  return s;
}
