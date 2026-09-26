// CBMC harness for src/c/token_core.h: for every 32-byte token, encode then
// decode is the identity; for every 64-byte text, decode succeeds exactly
// when all characters are lowercase hex, and then re-encoding gives the
// same text (one spelling per token).
#define BLOG_ASSERT_H
#define ASSERT(x) __CPROVER_assert((x), #x)
#include "../../src/c/token_core.h"

uint8_t nondet_u8(void);

void check_roundtrip(void) {
  uint8_t raw[TOKEN_BYTES], hex[TOKEN_HEX], back[TOKEN_BYTES];
  for (uint32_t i = 0; i < TOKEN_BYTES; i++) raw[i] = nondet_u8();
  token_encode(raw, hex);
  __CPROVER_assert(token_decode(hex, TOKEN_HEX, back) == 1, "encoded token decodes");
  for (uint32_t i = 0; i < TOKEN_BYTES; i++) __CPROVER_assert(back[i] == raw[i], "round trip");
}

void check_decode(void) {
  uint8_t text[TOKEN_HEX], raw[TOKEN_BYTES], again[TOKEN_HEX];
  _Bool all_hex = 1;
  for (uint32_t i = 0; i < TOKEN_HEX; i++) {
    text[i] = nondet_u8();
    all_hex = all_hex && ((text[i] >= '0' && text[i] <= '9') || (text[i] >= 'a' && text[i] <= 'f'));
  }
  int32_t ok = token_decode(text, TOKEN_HEX, raw);
  __CPROVER_assert(ok == (all_hex ? 1 : 0), "decode accepts exactly lowercase hex");
  if (ok) {
    token_encode(raw, again);
    for (uint32_t i = 0; i < TOKEN_HEX; i++) __CPROVER_assert(again[i] == text[i], "one spelling per token");
  }
}
