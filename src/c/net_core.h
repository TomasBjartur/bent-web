// EFFECT CORE: pure helpers for the network effects (no Bend, no I/O).
// WHY C:  byte scanning at receive time; buffering in Bend would copy the
//         growing head on every chunk (a slowloris amplifier).
// PRE/POST: per function below.
// LAWS THAT DEPEND ON THIS: none directly. The HTTP laws are about what
//         Bend does with the bytes; this only finds where the head ends.
// VERIFIED BY: tests/c/net_core_test.c (unit), tests/c/net_core_fuzz.c
//         (libFuzzer), tests/c/net_core_cbmc.c (CBMC, bound 16 bytes).
#ifndef BLOG_NET_CORE_H
#define BLOG_NET_CORE_H

#include <stdint.h>

#include "assert.h"
#include "limits.h"

// Returns the length of the head including its final CRLFCRLF, or 0 if
// buf[0..len) holds no CRLFCRLF yet. Scans only [from - 3, len), so a
// caller that appends chunks can pass the previous length as `from` and
// the total work stays linear.
// PRE:  len <= HEAD_BYTES_MAX, from <= len, and no CRLFCRLF lies entirely
//       within buf[0..from) (true when from is the length passed to the
//       previous call and that call returned 0, or when from is 0).
// POST: result == 0, or 4 <= result <= len and buf[result-4..result) is
//       "\r\n\r\n" and no earlier CRLFCRLF starts at or after from - 3.
static inline uint32_t head_end(const uint8_t *buf, uint32_t len, uint32_t from) {
  ASSERT(len <= HEAD_BYTES_MAX);
  ASSERT(from <= len);
  uint32_t start = from >= 3u ? from - 3u : 0u;
  for (uint32_t i = start; i + 4u <= len; i++) {
    if (buf[i] == '\r' && buf[i + 1u] == '\n' && buf[i + 2u] == '\r' && buf[i + 3u] == '\n') {
      uint32_t end = i + 4u;
      ASSERT(end >= 4u && end <= len);
      return end;
    }
  }
  return 0u;
}

// A fixed pool of slot indices (a free-list stack). Single-threaded: only
// the event loop thread calls these.
typedef struct {
  uint32_t free_count;
  uint32_t capacity;
  uint32_t *free_list;  // capacity entries
} SlotPool;

// PRE: capacity > 0; free_list has capacity entries.
static inline void pool_init(SlotPool *p, uint32_t *free_list, uint32_t capacity) {
  ASSERT(capacity > 0u);
  p->free_list = free_list;
  p->capacity = capacity;
  p->free_count = capacity;
  for (uint32_t i = 0; i < capacity; i++) free_list[i] = capacity - 1u - i;
}

// Returns a free slot index, or UINT32_MAX if none.
static inline uint32_t pool_take(SlotPool *p) {
  ASSERT(p->free_count <= p->capacity);
  if (p->free_count == 0u) return UINT32_MAX;
  p->free_count--;
  uint32_t slot = p->free_list[p->free_count];
  ASSERT(slot < p->capacity);
  return slot;
}

// PRE: slot was returned by pool_take and not yet given back.
static inline void pool_give(SlotPool *p, uint32_t slot) {
  ASSERT(slot < p->capacity);
  ASSERT(p->free_count < p->capacity);
  p->free_list[p->free_count] = slot;
  p->free_count++;
}

#endif
