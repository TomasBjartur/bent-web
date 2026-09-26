#!/bin/sh
# Verification ladder for the pure C cores (docs/C_STYLE.md section 11):
# strict compile, unit tests under sanitizers, fuzzing, CBMC.
# usage: tests/c/build.sh [fuzz_seconds]   (default 20)
set -eu
cd "$(dirname "$0")"
CC="${CC:-clang}"
CBMC="${CBMC:-cbmc}"
FUZZ_SECONDS="${1:-20}"
OUT=../../build/c
mkdir -p "$OUT"
STRICT="-std=c23 -O1 -g -Wall -Wextra -Werror -Wconversion -Wsign-conversion -Wshadow -Wvla \
  -Wimplicit-fallthrough -Wformat=2 -Wnull-dereference -fstack-protector-strong \
  -D_FORTIFY_SOURCE=3 -ftrivial-auto-var-init=zero -fno-strict-aliasing"

echo "== unit (ASan + UBSan)"
$CC $STRICT -fsanitize=address,undefined -fno-sanitize-recover=all net_core_test.c -o "$OUT/net_core_test"
"$OUT/net_core_test"

$CC $STRICT -fsanitize=address,undefined -fno-sanitize-recover=all token_core_test.c -o "$OUT/token_core_test"
"$OUT/token_core_test"
$CC $STRICT -fsanitize=address,undefined -fno-sanitize-recover=all db_core_test.c ../../src/c/db_core.c \
  ../../build/sqlite3.o ../../build/libbearssl.a -lpthread -lm -o "$OUT/db_core_test"
$CC $STRICT -Wno-sign-conversion -Wno-conversion -fsanitize=address,undefined -fno-sanitize-recover=all \
  auth_core_test.c ../../src/c/db_core.c ../../build/sqlite3.o ../../build/libbearssl.a -lpthread -lm \
  -o "$OUT/auth_core_test"
"$OUT/auth_core_test"
"$OUT/db_core_test"
$CC $STRICT -Wno-sign-conversion -Wno-conversion -fsanitize=address,undefined -fno-sanitize-recover=all \
  auth_core_test.c ../../src/c/db_core.c ../../build/sqlite3.o ../../build/libbearssl.a -lpthread -lm \
  -o "$OUT/auth_core_test"
"$OUT/auth_core_test"

echo "== fuzz (${FUZZ_SECONDS}s)"
$CC $STRICT -fsanitize=fuzzer,address,undefined -fno-sanitize-recover=all net_core_fuzz.c -o "$OUT/net_core_fuzz"
mkdir -p "$OUT/corpus_net_core"
"$OUT/net_core_fuzz" -max_total_time="$FUZZ_SECONDS" -max_len=9000 "$OUT/corpus_net_core" 2>&1 | grep -E "^Done|ERROR|SUMMARY" || true

echo "== cbmc"
$CC -E -P net_core_cbmc.c -o "$OUT/net_core_cbmc.i"
$CC -E -P token_core_cbmc.c -o "$OUT/token_core_cbmc.i"
$CC -E -P ops_core_cbmc.c -o "$OUT/ops_core_cbmc.i"
for pair in net_core:check_head_end net_core:check_pool token_core:check_roundtrip token_core:check_decode ops_core:check_ops_parse; do
  file=${pair%%:*}; fn=${pair##*:}
  printf "%-16s " "$fn"
  $CBMC "$OUT/${file}_cbmc.i" --function "$fn" --bounds-check --pointer-check \
    --signed-overflow-check --unsigned-overflow-check --unwinding-assertions \
    --unwind 70 > "$OUT/cbmc_$fn.log" 2>&1 && echo "VERIFIED" || { echo "FAILED"; tail -30 "$OUT/cbmc_$fn.log"; exit 1; }
done
