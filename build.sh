#!/bin/sh
# Build the server: check all laws, emit C from Bend, compile with our
# hardening flags (docs/C_STYLE.md section 10).
#
# The generated TU contains Bend's runtime, which we do not own, so strict
# warnings (-Werror, -Wconversion, ...) are applied to our pure C cores
# instead, which compile standalone (tests/c/build.sh). The hardening
# code-generation flags apply to everything.
set -eu
cd "$(dirname "$0")"
CC="${CC:-clang}"
export BEND_NO_TELEMETRY=1
mkdir -p build

echo "== laws"
bend PROOF.bend

echo "== bend -> C"
bend src/main.bend -o build/server.c > build/bend.log 2>&1 || { cat build/bend.log; exit 1; }

if [ ! -f build/sqlite3.o ] || [ vendor/sqlite/sqlite3.c -nt build/sqlite3.o ]; then
  echo "== sqlite"
  $CC -O2 -c -DSQLITE_THREADSAFE=2 -DSQLITE_DQS=0 -DSQLITE_OMIT_LOAD_EXTENSION \
    -DSQLITE_DEFAULT_MEMSTATUS=0 -DSQLITE_DEFAULT_FOREIGN_KEYS=1 \
    -fstack-protector-strong -D_FORTIFY_SOURCE=3 -fPIE \
    vendor/sqlite/sqlite3.c -o build/sqlite3.o 2>/dev/null
fi

if [ ! -f build/libbearssl.a ]; then
  echo "== bearssl"
  mkdir -p build/bearssl
  for f in vendor/bearssl/src/*.c vendor/bearssl/src/*/*.c; do
    $CC -O2 -fPIE -fstack-protector-strong -Ivendor/bearssl/inc -Ivendor/bearssl/src \
      -c "$f" -o "build/bearssl/$(echo "$f" | tr / _).o" 2>/dev/null
  done
  ar="$(dirname "$(command -v clang 2>/dev/null || echo /usr/bin/clang)")/llvm-ar"
  [ -x "$ar" ] || ar="${AR:-ar}"
  "$ar" rcs build/libbearssl.a build/bearssl/*.o
fi

echo "== server"
# -ftrivial-auto-var-init=zero is omitted here: it makes clang run out of
# registers on Bend's runtime (clang 19). Our standalone cores keep it.
HARDEN="-fstack-protector-strong -D_FORTIFY_SOURCE=3 -fno-strict-aliasing -fPIE"
$CC -std=c11 -O2 $HARDEN -Wno-everything build/server.c build/sqlite3.o build/libbearssl.a \
  -lpthread -lm -pie -Wl,-z,relro,-z,now -o build/server
echo "built build/server"
