// CBMC harness for src/c/ops_core.h: for every input of up to BOUND bytes,
// no out-of-bounds access or overflow, at most CAP rows, and every row
// returned satisfies the POST ranges.
#define BLOG_ASSERT_H
#define ASSERT(x) __CPROVER_assert((x), #x)
#include "../../src/c/ops_core.h"

#define BOUND 20u
#define CAP 2u

char nondet_char(void);
uint32_t nondet_u32(void);

void check_ops_parse(void) {
  char buf[BOUND];
  for (uint32_t i = 0; i < BOUND; i++) buf[i] = nondet_char();
  uint32_t n = nondet_u32();
  __CPROVER_assume(n <= BOUND);
  uint32_t rows[CAP][7];
  int32_t r = ops_parse(buf, n, rows, CAP);
  __CPROVER_assert(r >= -1 && r <= (int32_t)CAP, "count in range");
  for (int32_t i = 0; i < r; i++) {
    __CPROVER_assert(rows[i][0] >= 1u && rows[i][1] >= 1u, "ids nonzero");
    __CPROVER_assert(rows[i][2] <= 1u && rows[i][5] <= 1u, "kind and side are bits");
    __CPROVER_assert(rows[i][6] <= 1114111u && !(rows[i][6] >= 55296u && rows[i][6] <= 57343u), "scalar");
  }
}
