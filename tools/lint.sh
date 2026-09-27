#!/bin/sh
# Structural rules the type system does not enforce. Each rule says why.
set -eu
cd "$(dirname "$0")/.."
fail=0
rule() { echo "LINT: $1"; fail=1; }

# 1. Writes only through Db.apply (which takes a Permit).
hits=$(grep -rn "apply_raw(\|sync_page(\|upload_raw(" src --include=*.bend | grep -v "^src/db.bend:" || true)
[ -z "$hits" ] || rule "apply_raw called outside src/db.bend (writes must go through apply, which takes a Permit): $hits"

# 2. Permits (and WritePermits: the write budget) are only constructed by
#    authorize and authorize_write.
hits=$(grep -rn "Permit{" src --include=*.bend | grep -v "^src/authz.bend:" | grep -v "case Authz.Permit{\|case Authz.WritePermit{" || true)
[ -z "$hits" ] || rule "a Permit or WritePermit is built outside src/authz.bend: $hits"

# 2b. Whether an email has an account is private: looked up only through
#     Db.user_by_email, which takes a Permit to manage a blog.
hits=$(grep -rn "q_user_by_email" src --include=*.bend | grep -v "^src/db.bend:" || true)
[ -z "$hits" ] || rule "q_user_by_email used outside src/db.bend (use Db.user_by_email): $hits"

# 3. Refined values are only built by their smart constructors (a literal
#    proof {==} next to a constructor outside its module would forge one).
for t in Seg Path Query Hval Clen Title Body Slug Email Name; do
  hits=$(grep -rn "[^A-Za-z.]$t{" src --include=*.bend | grep -v "case " | grep -v "^src/http.bend:" | grep -v "^src/text.bend:" || true)
  [ -z "$hits" ] || rule "$t built outside its module: $hits"
done

# 4. Only src/db.bend and src/auth.bend declare database effects.
hits=$(grep -rln 'import "./effects/db.c"' src | grep -v "^src/db.bend$" || true)
[ -z "$hits" ] || rule "database effects declared outside src/db.bend, src/auth.bend: $hits"

# 4b. Sessions are only created from a RegOk / LoginOk: the raw effects are
#     only called by register.go and login_go in src/auth.bend.
hits=$(grep -rn "auth_register_raw(\|auth_login_raw(" src --include=*.bend | grep -v "^src/auth.bend:.*def auth_" || true)
bad=$(echo "$hits" | grep -v "^$" | while IFS= read -r line; do
  n=$(echo "$line" | cut -d: -f2)
  fn=$(head -n "$n" src/auth.bend | grep "^def " | tail -1)
  case "$fn" in "def register.go("*|"def login_go("*) ;; *) echo "$line ($fn)";; esac
done)
[ -z "$bad" ] || rule "session effect called outside register.go/login_go: $bad"

# 4c. RegOk / LoginOk only built in src/webauthn.bend.
hits=$(grep -rn "RegOk{\|LoginOk{" src --include=*.bend | grep -v "^src/webauthn.bend:" | grep -v "case WA\." || true)
[ -z "$hits" ] || rule "RegOk/LoginOk built outside src/webauthn.bend: $hits"

# 5. Banned C functions (docs/C_STYLE.md section 8).
hits=$(grep -rnE '\b(strcpy|strcat|sprintf|vsprintf|gets|strtok|atoi|atol|scanf|sscanf|rand|system|popen)\s*\(' src/c src/effects || true)
[ -z "$hits" ] || rule "banned C function: $hits"

# 6. No SQL built at run time: every SQL string is a literal in db_core.c.
hits=$(grep -rn "sqlite3_prepare\|sqlite3_exec" src | grep -v "^src/c/db_core.c:" || true)
[ -z "$hits" ] || rule "SQL outside src/c/db_core.c: $hits"

# The Bend query ids (src/db.bend q_*) must match the C enum order.
python3 - <<'PY' || rule "query ids differ between src/c/db_core.h and src/db.bend"
import re, sys
h = open("src/c/db_core.h").read()
enum = h[h.index("Q_BLOG_BY_SLUG = 0"):h.index("Q_COUNT")]
names = re.findall(r"^\s*(Q_[A-Z_]+)", enum, re.M)
b = open("src/db.bend").read()
ids = dict(re.findall(r"def (q_\w+)\(\) -> U32:\n\s+(\d+)", b))
bad = [(n, i, ids.get(n.lower())) for i, n in enumerate(names) if n.lower() in ids and int(ids[n.lower()]) != i]
missing = [n for n in names if n.lower() not in ids]
if bad or missing:
    print("mismatched:", bad, "missing in db.bend:", missing)
    sys.exit(1)
PY

[ $fail -eq 0 ] && echo "lint: ok"
exit $fail
