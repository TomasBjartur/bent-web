// libFuzzer target for head_end: differential against a naive reference,
// and incremental (random chunking) must agree with a single scan.
#include <string.h>

#include "../../src/c/net_core.h"

static uint32_t reference(const uint8_t *b, uint32_t n) {
  for (uint32_t i = 0; i + 4u <= n; i++) {
    if (memcmp(b + i, "\r\n\r\n", 4) == 0) return i + 4u;
  }
  return 0u;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  if (size < 1u) return 0;
  uint8_t cut_seed = data[0];
  data++;
  size--;
  if (size > HEAD_BYTES_MAX) size = HEAD_BYTES_MAX;
  uint32_t n = (uint32_t)size;
  uint32_t want = reference(data, n);
  ASSERT(head_end(data, n, 0) == want);
  // Feed in chunks, as the receive loop does: stop at the first hit.
  uint32_t have = 0, got = 0, step = (uint32_t)(cut_seed % 7u) + 1u;
  while (have < n && got == 0u) {
    uint32_t from = have;
    have = have + step > n ? n : have + step;
    got = head_end(data, have, from);
  }
  ASSERT(got == want);
  return 0;
}
