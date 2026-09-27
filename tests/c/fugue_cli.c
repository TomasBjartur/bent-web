// The C materializer as a program, with the same interface as
// tests/crdt_ref.bend: reads a file of operations (wire format), prints the
// text between markers. Used by tests/fugue_diff.mjs.
#include <stdio.h>
#include <stdlib.h>

#include "../../src/c/fugue_core.h"
#include "../../src/c/ops_core.h"

int main(int argc, char **argv) {
  if (argc < 2) return 2;
  FILE *f = fopen(argv[1], "rb");
  if (!f) return 2;
  // Up to FUGUE_OPS_MAX operations of at most 58 bytes each.
  static char buf[58u * FUGUE_OPS_MAX + 1u];
  size_t n = fread(buf, 1, sizeof buf, f);
  fclose(f);
  if (n == sizeof buf) return 2;
  static uint32_t rows[FUGUE_OPS_MAX][7];
  int32_t k = ops_parse(buf, (uint32_t)n, rows, FUGUE_OPS_MAX);
  if (k < 0) {
    printf("<<INVALID>>\n");
    return 0;
  }
  static FOp ops[FUGUE_OPS_MAX];
  for (int32_t i = 0; i < k; i++) {
    ops[i] = (FOp){rows[i][0], rows[i][1], rows[i][2], rows[i][3], rows[i][4], rows[i][5], rows[i][6]};
  }
  FugueArena a = {malloc(sizeof(FOp) * FUGUE_OPS_MAX), malloc(sizeof(uint64_t) * FUGUE_OPS_MAX),
                  malloc(sizeof(uint32_t) * (FUGUE_OPS_MAX + 2u))};
  static uint8_t out[4u * FUGUE_OPS_MAX + 16u];
  if (!a.ins || !a.dead || !a.stack) return 2;
  int64_t len = fugue_text(&a, ops, (uint32_t)k, out, sizeof out);
  free(a.ins);
  free(a.dead);
  free(a.stack);
  if (len < 0) {
    printf("<<TOO LARGE>>\n");
    return 0;
  }
  fputs("<<TEXT>>", stdout);
  fwrite(out, 1, (size_t)len, stdout);
  fputs("<<END>>\n", stdout);
  return fflush(stdout) == 0 ? 0 : 1;
}
