# The laws of the blog. Code must satisfy these, and PROOF.bend must prove
# each one. `bend PROOF.bend` is the gate.
#
# RULES
# - Every predicate a law uses is defined in spec/ or here, never in the code
#   under test. A law stated with the implementation's own predicates is
#   weakened whenever the implementation is (found by mutation testing,
#   2026-09-26).
# - Laws read fields of code types by pattern matching here, not through
#   accessor functions from the code, for the same reason.
# - Every new law is mutation-tested once to show that it can fail.
import Base
import ./spec/html.bend as HtmlSpec
import ./spec/http.bend as HttpSpec
import ./src/html.bend as Html
import ./src/http.bend as Http

# HTML ESCAPING
# -------------

# LAW: escaping never produces an unsafe character. Whatever the user typed,
# Html.esc emits no < > " ' and no control characters (so it cannot open a
# tag, close an attribute, or forge an internal marker), provided what it is
# prepended to was already safe.
law html_esc_safe:
  for s: String
  for -rest: String
  for hr: {HtmlSpec.safe_str(rest) == True{} : Bool}
  {HtmlSpec.safe_str(Html.esc(s, rest)) == True{} : Bool}

# LAW: in particular, escaping a string on its own is safe.
law html_esc_safe_alone:
  for s: String
  {HtmlSpec.safe_str(Html.esc(s, "")) == True{} : Bool}

# HTTP REQUESTS
# -------------
# These are type invariants: they hold for every value of these types
# anywhere in the program, including everything the parser returns.

def seg_text(g: Http.Seg) -> String:
  match g:
    case Http.Seg{t, p}:
      t

def path_segs(p: Http.Path) -> List<&2, Http.Seg>:
  match p:
    case Http.Path{xs, pf}:
      xs

def query_text(q: Http.Query) -> String:
  match q:
    case Http.Query{t, p}:
      t

def hval_text(h: Http.Hval) -> String:
  match h:
    case Http.Hval{t, p}:
      t

def clen_n(c: Http.Clen) -> U32:
  match c:
    case Http.Clen{n, p}:
      n

# LAW: every path segment is 1..128 unreserved characters and never "." or
# "..": a request path can never traverse upward or smuggle encoded bytes.
law http_seg_ok:
  for g: Http.Seg
  {HttpSpec.seg_ok(seg_text(g)) == True{} : Bool}

# LAW: a path has at most 16 segments.
law http_path_bounded:
  for p: Http.Path
  {HttpSpec.seg_count_ok(List.length(&2, Http.Seg, path_segs(p))) == True{} : Bool}

# LAW: a query string is at most 2048 query characters.
law http_query_ok:
  for q: Http.Query
  {HttpSpec.query_ok(query_text(q)) == True{} : Bool}

# LAW: a header value has no CR, LF, NUL or other control characters, and
# is at most 4096 bytes: it can never split a response if reflected.
law http_hval_ok:
  for h: Http.Hval
  {HttpSpec.hval_ok(hval_text(h)) == True{} : Bool}

# LAW: a Content-Length is at most 1 MiB.
law http_clen_ok:
  for c: Http.Clen
  {HttpSpec.clen_ok(clen_n(c)) == True{} : Bool}

# REQUEST SMUGGLING
# -----------------
# Proved at the level of a single header line. That the parser sends every
# header line through header_after is checked by tests
# (tests/http_test.bend), not proved.

def is_fail(-A: Data, r: Result<&2, &2, U32, A>) -> Bool:
  match r:
    case Fail{e}:
      True{}
    case Done{x}:
      False{}

# LAW: a Transfer-Encoding header, in any letter case, is always rejected.
# Bodies are delimited by Content-Length only, so a front proxy and this
# server can never disagree about where a request ends.
law http_te_rejected:
  for h: Http.Hdrs
  for +name: String
  for raw: String
  for e: {String.to_lower(name) == "transfer-encoding" : String}
  {is_fail(Http.Hdrs, Http.header_after(h, name, Some{raw})) == True{} : Bool}

# Whether the field that header id k sets is already present.
def field_set(h: Http.Hdrs, k: Nat) -> Bool:
  match h:
    case Http.Hdrs{host, cookie, clen, ctype, origin, site, ds}:
      match k:
        case 1n:
          Maybe.is_some(&2, Http.Hval, host)
        case 2n:
          Maybe.is_some(&2, Http.Hval, cookie)
        case 3n:
          Maybe.is_some(&2, Http.Clen, clen)
        case 4n:
          Maybe.is_some(&2, Http.Hval, ctype)
        case 5n:
          Maybe.is_some(&2, Http.Hval, origin)
        case 6n:
          Maybe.is_some(&2, Http.Hval, site)
        case 7n:
          Maybe.is_some(&2, Http.Hval, ds)
        case _:
          False{}

# LAW: a header this server reads can never be set twice: a second Host,
# Content-Length, Cookie, Content-Type, Origin, Sec-Fetch-Site or
# Datastar-Request is rejected, never overwrites the first.
law http_no_dup:
  for +h: Http.Hdrs
  for +k: Nat
  for v: Http.Hval
  for raw: String
  for e: {field_set(h, k) == True{} : Bool}
  {is_fail(Http.Hdrs, Http.hdrs_set(h, k, v, raw)) == True{} : Bool}
