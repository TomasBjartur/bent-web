// CBMC harness for src/c/net_core.h. Proves, for every input up to BOUND
// bytes: no out-of-bounds access, no overflow, no ASSERT can fire, and the
// POST conditions below hold. Also checks the slot pool never hands out a
// slot twice, over every sequence of OPS operations.
#define BLOG_ASSERT_H
#define ASSERT(x) __CPROVER_assert((x), #x)
#include "../../src/c/net_core.h"

#define BOUND 16u
#define OPS 6u
#define CAP 3u

uint32_t nondet_u32(void);
uint8_t nondet_u8(void);
_Bool nondet_bool(void);

static _Bool crlf2(const uint8_t *b, uint32_t i) {
  return b[i] == '\r' && b[i + 1u] == '\n' && b[i + 2u] == '\r' && b[i + 3u] == '\n';
}

void check_head_end(void) {
  uint8_t buf[BOUND];
  for (uint32_t i = 0; i < BOUND; i++) buf[i] = nondet_u8();
  uint32_t len = nondet_u32(), from = nondet_u32();
  __CPROVER_assume(len <= BOUND && from <= len);
  uint32_t r = head_end(buf, len, from);
  uint32_t start = from >= 3u ? from - 3u : 0u;
  if (r != 0u) {
    __CPROVER_assert(r >= 4u && r <= len, "result in range");
    __CPROVER_assert(crlf2(buf, r - 4u), "result ends a CRLFCRLF");
    for (uint32_t j = start; j + 4u < r; j++) __CPROVER_assert(!crlf2(buf, j), "first match");
  } else {
    for (uint32_t j = start; j + 4u <= len; j++) __CPROVER_assert(!crlf2(buf, j), "no match missed");
  }
}

void check_pool(void) {
  uint32_t fl[CAP];
  _Bool taken[CAP] = {0};
  SlotPool p;
  pool_init(&p, fl, CAP);
  for (uint32_t k = 0; k < OPS; k++) {
    if (nondet_bool()) {
      uint32_t s = pool_take(&p);
      if (s != UINT32_MAX) {
        __CPROVER_assert(s < CAP, "slot in range");
        __CPROVER_assert(!taken[s], "slot never handed out twice");
        taken[s] = 1;
      } else {
        for (uint32_t i = 0; i < CAP; i++) __CPROVER_assert(taken[i], "empty only when all taken");
      }
    } else {
      uint32_t s = nondet_u32();
      __CPROVER_assume(s < CAP && taken[s]);
      pool_give(&p, s);
      taken[s] = 0;
    }
  }
}
