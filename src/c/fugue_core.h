// CORE: materializing a document from its CRDT operations (pure, no I/O).
// WHY C:  the Bend reference (src/crdt.bend) takes 1.7 s and 80 MB for a
//         100k-character document on the server's single event loop; novels
//         are 10x that. This does the same computation in O(n log n) over
//         integer arrays.
// PRE:    ops[0..n) are valid operations (as src/c/ops_core.h accepts them)
//         with unique (ctr, rep) ids; n <= FUGUE_OPS_MAX; the work arena has
//         been set with fugue_arena.
// POST:   out receives the UTF-8 text of the live characters in document
//         order, exactly as src/crdt.bend's `text` defines it: siblings
//         ordered by (ctr, rep, ch), in-order traversal from the root,
//         inserts whose parent is missing are not shown, a delete hides its
//         target whatever the order of arrival.
// LAWS THAT DEPEND ON THIS: none directly. Its output is refined by Bend
//         (Body) before rendering, so a bug here can garble a document but
//         not make its HTML unsafe.
// VERIFIED BY: tests/fugue_diff.mjs (differential fuzzing against the Bend
//         reference, via tests/c/fugue_cli.c), tests/c/fugue_core_test.c.
#ifndef BLOG_FUGUE_CORE_H
#define BLOG_FUGUE_CORE_H

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "assert.h"

#define FUGUE_OPS_MAX 2000000u

typedef struct {
  uint32_t c, r, kind, pc, pr, side, ch;
} FOp;

// Work space, allocated once (FUGUE_OPS_MAX entries each).
typedef struct {
  FOp *ins;        // inserts, sorted by (pc, pr, side, c, r, ch): siblings contiguous
  uint64_t *dead;  // delete targets, (pc << 32 | pr), sorted
  uint32_t *stack; // traversal stack: indexes into ins (with a phase bit)
} FugueArena;

static inline int fop_kids_lt(const FOp *a, const FOp *b) {
  if (a->pc != b->pc) return a->pc < b->pc;
  if (a->pr != b->pr) return a->pr < b->pr;
  if (a->side != b->side) return a->side < b->side;
  if (a->c != b->c) return a->c < b->c;
  if (a->r != b->r) return a->r < b->r;
  return a->ch < b->ch;
}

static int fop_cmp(const void *x, const void *y) {
  const FOp *a = x, *b = y;
  return fop_kids_lt(a, b) ? -1 : fop_kids_lt(b, a) ? 1 : 0;
}

static int u64_cmp(const void *x, const void *y) {
  uint64_t a = *(const uint64_t *)x, b = *(const uint64_t *)y;
  return (a > b) - (a < b);
}

// First index in ins[0..m) whose (pc, pr, side) >= (pc, pr, side).
static inline uint32_t fugue_kids(const FOp *ins, uint32_t m, uint32_t pc, uint32_t pr, uint32_t side) {
  uint32_t lo = 0, hi = m;
  while (lo < hi) {
    uint32_t mid = lo + (hi - lo) / 2u;
    const FOp *o = &ins[mid];
    int less = o->pc != pc ? o->pc < pc : o->pr != pr ? o->pr < pr : o->side < side;
    if (less) lo = mid + 1u;
    else hi = mid;
  }
  return lo;
}

static inline int fugue_is_dead(const uint64_t *dead, uint32_t nd, uint32_t c, uint32_t r) {
  uint64_t k = ((uint64_t)c << 32) | r;
  uint32_t lo = 0, hi = nd;
  while (lo < hi) {
    uint32_t mid = lo + (hi - lo) / 2u;
    if (dead[mid] < k) lo = mid + 1u;
    else hi = mid;
  }
  return lo < nd && dead[lo] == k;
}

static inline uint32_t utf8_put(uint32_t cp, uint8_t *o) {
  if (cp < 0x80u) { o[0] = (uint8_t)cp; return 1; }
  if (cp < 0x800u) { o[0] = (uint8_t)(0xC0u | (cp >> 6)); o[1] = (uint8_t)(0x80u | (cp & 63u)); return 2; }
  if (cp < 0x10000u) {
    o[0] = (uint8_t)(0xE0u | (cp >> 12)); o[1] = (uint8_t)(0x80u | ((cp >> 6) & 63u)); o[2] = (uint8_t)(0x80u | (cp & 63u));
    return 3;
  }
  o[0] = (uint8_t)(0xF0u | (cp >> 18)); o[1] = (uint8_t)(0x80u | ((cp >> 12) & 63u));
  o[2] = (uint8_t)(0x80u | ((cp >> 6) & 63u)); o[3] = (uint8_t)(0x80u | (cp & 63u));
  return 4;
}

// Materializes ops[0..n) into out (capacity cap bytes). Returns the number
// of bytes written, or -1 if n or the output exceed their limits.
// The phase bit of a stack entry: 0 = visit left children next, 1 = emit
// and visit right children. Index m (one past the inserts) is the root.
static inline int64_t fugue_text(FugueArena *a, const FOp *ops, uint32_t n, uint8_t *out, uint64_t cap) {
  ASSERT(a != NULL && a->ins != NULL && a->dead != NULL && a->stack != NULL);
  if (n > FUGUE_OPS_MAX) return -1;
  uint32_t m = 0, nd = 0;
  for (uint32_t i = 0; i < n; i++) {
    ASSERT(ops[i].kind <= 1u && ops[i].side <= 1u);
    if (ops[i].kind == 0u) a->ins[m++] = ops[i];
    else a->dead[nd++] = ((uint64_t)ops[i].pc << 32) | ops[i].pr;
  }
  qsort(a->ins, m, sizeof(FOp), fop_cmp);
  qsort(a->dead, nd, sizeof(uint64_t), u64_cmp);
  // Stack of (node << 1 | phase). Each node is pushed at most twice-phase
  // updated in place, and at most once: its parent pushes it once.
  uint32_t sp = 0;
  uint64_t len = 0;
  a->stack[sp++] = (m << 1);  // the root, phase 0
  for (uint64_t guard = 0; sp > 0; guard++) {
    ASSERT(guard <= 3ull * (uint64_t)m + 3ull);
    uint32_t top = a->stack[sp - 1u];
    uint32_t node = top >> 1, phase = top & 1u;
    uint32_t c = node == m ? 0u : a->ins[node].c, r = node == m ? 0u : a->ins[node].r;
    uint32_t side = phase;  // phase 0: left children; phase 1: right children
    if (phase == 1u) {
      sp--;
      if (node != m && !fugue_is_dead(a->dead, nd, c, r)) {
        if (len + 4u > cap) return -1;
        len += utf8_put(a->ins[node].ch, out + len);
      }
    } else {
      a->stack[sp - 1u] = top | 1u;
    }
    // Push this side's children in reverse, so the first is visited first.
    uint32_t lo = fugue_kids(a->ins, m, c, r, side);
    uint32_t hi = fugue_kids(a->ins, m, c, r, side + 1u);
    if (side == 1u) {
      // right children come after the node and its left subtree; the node
      // itself was emitted above (phase 1) and popped.
    }
    for (uint32_t k = hi; k > lo; k--) {
      ASSERT(sp < m + 2u);
      a->stack[sp++] = ((k - 1u) << 1);
    }
  }
  return (int64_t)len;
}

#endif
