// Unit tests for src/c/token_core.h.
#include <string.h>

#include "../../src/c/token_core.h"

static int fails = 0;
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #x); fails++; } } while (0)

int main(void) {
  uint8_t raw[32], back[32], hex[64];
  for (uint32_t i = 0; i < 32; i++) raw[i] = (uint8_t)(i * 37u + 5u);
  token_encode(raw, hex);
  CHECK(token_decode(hex, 64, back) == 1 && memcmp(raw, back, 32) == 0);
  CHECK(token_decode(hex, 63, back) == 0);
  hex[10] = 'A';
  CHECK(token_decode(hex, 64, back) == 0);
  hex[10] = 'g';
  CHECK(token_decode(hex, 64, back) == 0);
  if (fails == 0) printf("token_core_test: all passed\n");
  return fails != 0;
}
