#!/bin/sh
# Structural rules the type system does not enforce. Each rule says why.
set -eu
cd "$(dirname "$0")/.."
fail=0
rule() { echo "LINT: $1"; fail=1; }

# 1. Writes only through Db.apply (which takes a Permit).
hits=$(grep -rn "apply_raw(" src --include=*.bend | grep -v "^src/db.bend:" || true)
[ -z "$hits" ] || rule "apply_raw called outside src/db.bend (writes must go through apply, which takes a Permit): $hits"

# 2. Permits are only constructed by authorize.
hits=$(grep -rn "Permit{" src --include=*.bend | grep -v "^src/authz.bend:" | grep -v "case Authz.Permit{" || true)
[ -z "$hits" ] || rule "a Permit is built outside src/authz.bend: $hits"

# 3. Refined values are only built by their smart constructors (a literal
#    proof {==} next to a constructor outside its module would forge one).
for t in Seg Path Query Hval Clen Title Body Slug; do
  hits=$(grep -rn "[^A-Za-z.]$t{" src --include=*.bend | grep -v "case " | grep -v "^src/http.bend:" | grep -v "^src/text.bend:" || true)
  [ -z "$hits" ] || rule "$t built outside its module: $hits"
done

# 4. Only src/db.bend declares database effects.
hits=$(grep -rln 'import "./effects/db.c"' src | grep -v "^src/db.bend$" || true)
[ -z "$hits" ] || rule "database effects declared outside src/db.bend: $hits"

# 5. Banned C functions (docs/C_STYLE.md section 8).
hits=$(grep -rnE '\b(strcpy|strcat|sprintf|vsprintf|gets|strtok|atoi|atol|scanf|sscanf|rand|system|popen)\s*\(' src/c src/effects || true)
[ -z "$hits" ] || rule "banned C function: $hits"

# 6. No SQL built at run time: every SQL string is a literal in db_core.c.
hits=$(grep -rn "sqlite3_prepare\|sqlite3_exec" src | grep -v "^src/c/db_core.c:" || true)
[ -z "$hits" ] || rule "SQL outside src/c/db_core.c: $hits"

[ $fail -eq 0 ] && echo "lint: ok"
exit $fail
