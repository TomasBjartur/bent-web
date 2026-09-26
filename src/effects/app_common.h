// Shared by src/effects/db.c and src/effects/auth.c (each Bend module may
// import its own effect file; both are spliced into one C file). Holds the
// database handle and the conversions between Bend terms and C values.
#ifndef BLOG_APP_COMMON_H
#define BLOG_APP_COMMON_H

#include <time.h>

#include "../c/db_core.c"
#include "../c/token_core.h"
#include "../c/http_headers.h"
#include "../c/limits.h"

static Db app_db;
static int32_t app_db_ready;

static uint64_t app_now_ms(void) {
  struct timespec t;
  clock_gettime(CLOCK_REALTIME, &t);
  return (uint64_t)t.tv_sec * 1000ull + (uint64_t)t.tv_nsec / 1000000ull;
}

// Session tokens live 30 days.
#define SESSION_TTL_MS (30ull * 24ull * 3600ull * 1000ull)

// The SHA-256 of the session token in `t` (a Bend String of hex), or all
// zeros (which matches no session) if it is not a well-formed token.
static void app_token_hash(Env e, Term t, uint8_t out[32]) {
  u64 n = 0;
  char *s = io_cstr(e, t, &n);
  uint8_t raw[TOKEN_BYTES];
  memset(out, 0, 32);
  if (n == TOKEN_HEX && token_decode((const uint8_t *)s, (uint32_t)n, raw)) {
    db_token_hash(raw, out);
  }
  explicit_bzero(raw, sizeof raw);
  explicit_bzero(s, n);
  free(s);
}

// Takes one element off a Bend list term: returns 1 and sets *head/*tail if
// it is a cons, 0 if it is empty.
// con: CID(Con) (the header cannot use CID; effect files pass it in).
static int app_uncons(Env e, u64 con, Term s, Term *head, Term *tail) {
  if (term_aux(s) != con) return 0;
  Term fb[2];
  spare_free(e, cls_fit(2), ctr_take(e, s, 2, fb));
  *head = fb[0];
  *tail = fb[1];
  return 1;
}

// Binary values cross the boundary as lowercase hex.

// A Bend String of lowercase hex into out; returns the byte count or -1.
static int32_t app_unhex(Env e, Term t, uint8_t *out, uint32_t cap) {
  u64 n = 0;
  char *s = io_cstr(e, t, &n);
  int32_t r = n > 8192u ? -1 : hex_decode((const uint8_t *)s, (uint32_t)n, out, cap);
  free(s);
  return r;
}

static Term app_hex(Env e, const uint8_t *raw, uint32_t n) {
  uint8_t buf[2 * 4096];
  ASSERT(n <= 4096u);
  hex_encode(raw, n, buf);
  return io_str(e, (const char *)buf, 2u * n);
}

// con, nil: CID(Con), CID(Nil).
static Term app_strs(Env e, u64 con, u64 nil, const char *const *v, const uint32_t *lens, uint32_t n) {
  Term xs = term_pak(nil, 0);
  for (uint32_t i = n; i > 0u; i--) xs = io_node(e, con, io_str(e, v[i - 1u], lens[i - 1u]), xs);
  return xs;
}


#endif
