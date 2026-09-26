// Unit tests for src/c/net_core.h.
#include <string.h>

#include "../../src/c/net_core.h"

static int fails = 0;
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #x); fails++; } } while (0)

static uint32_t he(const char *s, uint32_t from) {
  return head_end((const uint8_t *)s, (uint32_t)strlen(s), from);
}

int main(void) {
  CHECK(he("", 0) == 0u);
  CHECK(he("\r\n\r\n", 0) == 4u);
  CHECK(he("GET / HTTP/1.1\r\n\r\n", 0) == 18u);
  CHECK(he("GET / HTTP/1.1\r\n\r\nbody", 0) == 18u);
  CHECK(he("a\r\n\r\nb\r\n\r\n", 0) == 5u);
  CHECK(he("\n\n\r\n", 0) == 0u);
  CHECK(he("\r\n\r", 0) == 0u);
  // Incremental: the terminator straddles the previous length.
  CHECK(he("ab\r\n\r\n", 3) == 6u);
  CHECK(he("ab\r\n\r\n", 5) == 6u);
  // from = 6 violates PRE here (the terminator lies entirely in [0, 6)),
  // so the result is unspecified; the receive loop never does this.

  uint32_t fl[3];
  SlotPool p;
  pool_init(&p, fl, 3);
  uint32_t a = pool_take(&p), b = pool_take(&p), c = pool_take(&p);
  CHECK(a != b && b != c && a != c && a < 3u && b < 3u && c < 3u);
  CHECK(pool_take(&p) == UINT32_MAX);
  pool_give(&p, b);
  CHECK(pool_take(&p) == b);

  if (fails == 0) printf("net_core_test: all passed\n");
  return fails != 0;
}
