// Every C-side limit, in one place (docs/C_STYLE.md section 7). The Bend
// side's limits live in spec/http.bend; the ones shared by both are
// checked against each other by tests/limits_test.sh.
#ifndef BLOG_LIMITS_H
#define BLOG_LIMITS_H

#include <stdint.h>

// Largest request head (request line + headers + blank line). Also bounds
// the header count indirectly. Matches no Bend limit exactly: Bend limits
// each line to 4096 and the count to 64.
#define HEAD_BYTES_MAX 8192u

// Concurrent connections reading a head. Each holds one head buffer.
// Exhausting the pool answers 503 instead of allocating.
#define HEAD_SLOTS 1024u

// Largest request body (spec/http.bend: lim_body).
#define BODY_BYTES_MAX (1024u * 1024u)

// Concurrent body reads. Each holds one body buffer.
#define BODY_SLOTS 16u

// Deadline for a whole request head, and for a whole body (slowloris).
#define HEAD_TIMEOUT_MS 10000u
#define BODY_TIMEOUT_MS 30000u

// Largest response (head + body) this server sends.
#define RESPONSE_BYTES_MAX (4u * 1024u * 1024u)

_Static_assert(HEAD_BYTES_MAX >= 4u, "a head needs room for CRLFCRLF");
_Static_assert(BODY_BYTES_MAX < (UINT32_MAX / 2u), "body sizes fit u32 math");

#endif
