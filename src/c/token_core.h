// CORE: session token encoding (pure, no I/O).
// WHY C:  used by the session effects next to the hashing.
// LAWS THAT DEPEND ON THIS: none directly; session integrity depends on it
//         (a token maps to exactly one 32-byte value).
// VERIFIED BY: tests/c/token_core_test.c (unit), tests/c/token_core_cbmc.c
//         (CBMC: round trip and rejection, all inputs of 64 chars).
#ifndef BLOG_TOKEN_CORE_H
#define BLOG_TOKEN_CORE_H

#include <stdint.h>

#include "assert.h"

#define TOKEN_BYTES 32u
#define TOKEN_HEX (TOKEN_BYTES * 2u)

static inline uint8_t hex_digit(uint8_t v) {
  ASSERT(v < 16u);
  return (uint8_t)(v < 10u ? '0' + v : 'a' + (v - 10u));
}

// -1 if c is not a lowercase hex digit.
static inline int32_t hex_value(uint8_t c) {
  if (c >= '0' && c <= '9') return (int32_t)(c - '0');
  if (c >= 'a' && c <= 'f') return (int32_t)(c - 'a' + 10);
  return -1;
}

// POST: out[0..64) is lowercase hex of raw[0..32).
static inline void token_encode(const uint8_t raw[TOKEN_BYTES], uint8_t out[TOKEN_HEX]) {
  for (uint32_t i = 0; i < TOKEN_BYTES; i++) {
    out[2u * i] = hex_digit((uint8_t)(raw[i] >> 4));
    out[2u * i + 1u] = hex_digit((uint8_t)(raw[i] & 15u));
  }
}

// Returns 1 and fills raw iff text is exactly 64 lowercase hex digits.
// Uppercase is rejected so each token has exactly one spelling.
static inline int32_t token_decode(const uint8_t *text, uint32_t len, uint8_t raw[TOKEN_BYTES]) {
  if (len != TOKEN_HEX) return 0;
  for (uint32_t i = 0; i < TOKEN_BYTES; i++) {
    int32_t hi = hex_value(text[2u * i]), lo = hex_value(text[2u * i + 1u]);
    if (hi < 0 || lo < 0) return 0;
    raw[i] = (uint8_t)((hi << 4) | lo);
  }
  return 1;
}

// Decodes lowercase hex text[0..len) into out (capacity cap). Returns the
// number of bytes, or -1 if len is odd, too long for cap, or any character
// is not a lowercase hex digit.
static inline int32_t hex_decode(const uint8_t *text, uint32_t len, uint8_t *out, uint32_t cap) {
  if ((len & 1u) != 0u || len / 2u > cap) return -1;
  for (uint32_t i = 0; i < len / 2u; i++) {
    int32_t hi = hex_value(text[2u * i]), lo = hex_value(text[2u * i + 1u]);
    if (hi < 0 || lo < 0) return -1;
    out[i] = (uint8_t)((hi << 4) | lo);
  }
  return (int32_t)(len / 2u);
}

// Encodes raw[0..n) as lowercase hex into out (2n bytes).
static inline void hex_encode(const uint8_t *raw, uint32_t n, uint8_t *out) {
  for (uint32_t i = 0; i < n; i++) {
    out[2u * i] = hex_digit((uint8_t)(raw[i] >> 4));
    out[2u * i + 1u] = hex_digit((uint8_t)(raw[i] & 15u));
  }
}

#endif
