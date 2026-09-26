// CORE: parsing CRDT operations from the wire (pure, no I/O).
// WHY C:  the sync transaction inserts rows straight from the request text.
// PRE:    p[0..n) readable; rows has cap entries.
// POST:   returns the number of operations (<= cap), or -1 if the text is
//         not exactly repeated "c.r.k.pc.pr.s.ch;" in decimal with
//         c, r >= 1; k, s in {0, 1}; ch <= 0x10FFFF and not a surrogate;
//         every number at most 10 digits and fitting its field.
// LAWS THAT DEPEND ON THIS: none (the meaning of operations is checked in
//         Bend, src/crdt.bend decode; this is the database's floor).
// VERIFIED BY: tests/c/db_core_test.c, tests/c/ops_core_cbmc.c (CBMC,
//         all inputs up to 20 bytes).
#ifndef BLOG_OPS_CORE_H
#define BLOG_OPS_CORE_H

#include <stdint.h>

#include "assert.h"

static inline int32_t ops_parse(const char *p, uint32_t n, uint32_t (*rows)[7], uint32_t cap) {
  uint32_t count = 0, field = 0;
  uint64_t v = 0;
  int digits = 0;
  static const uint64_t field_max[7] = {4294967295u, 4294967295u, 1u, 4294967295u, 4294967295u, 1u, 1114111u};
  for (uint32_t i = 0; i < n; i++) {
    char c = p[i];
    if (c >= '0' && c <= '9') {
      if (digits >= 10) return -1;
      v = v * 10u + (uint64_t)(c - '0');
      digits++;
    } else if (c == '.' || c == ';') {
      if (digits == 0 || field >= 7u || v > field_max[field]) return -1;
      if (count >= cap) return -1;
      rows[count][field] = (uint32_t)v;
      field++;
      v = 0;
      digits = 0;
      if (c == ';') {
        if (field != 7u) return -1;
        uint32_t ch = rows[count][6];
        if (ch >= 55296u && ch <= 57343u) return -1;
        if (rows[count][0] == 0u || rows[count][1] == 0u) return -1;
        count++;
        field = 0;
      }
    } else {
      return -1;
    }
  }
  if (field != 0u || digits != 0) return -1;
  ASSERT(count <= cap);
  return (int32_t)count;
}

#endif
