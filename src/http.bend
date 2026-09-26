# HTTP/1.1 request head parser.
#
# Input: the raw bytes received so far, one Char per byte (0..255), as
# returned by Net.recv (src/net.c). Output: PMore (need more bytes), PBad
# (reject with a status code), or PDone (a parsed head, plus the bytes after
# it, which begin the body).
#
# Every value the parser hands out is a refinement type: Seg, Path, Query,
# Hval and Clen can only be built after their spec/http.bend predicate
# returned True, and they carry that proof. So no bug in this file can
# produce, e.g., a ".." segment or a header value containing CR/LF; the
# checker would reject it. LAWS.bend states these guarantees explicitly.
#
# Deliberately strict (request-smuggling defenses):
# - HTTP/1.1 only; lines end in CRLF; a bare CR or LF is rejected.
# - Transfer-Encoding is rejected (501): bodies use Content-Length only.
# - A duplicate Host, Content-Length, Cookie, Content-Type, Origin,
#   Sec-Fetch-Site or Datastar-Request header is rejected.
# - Header names are tokens; obsolete line folding is rejected.
#
# Loops over characters pass the class of the next character as an argument
# (instead of matching on a computed value, which Bend does not allow, or
# calling a helper that recurses back, which would be mutual recursion).
import Base
import ../spec/http.bend as Spec

# REFINED VALUES
# --------------

type Seg is Data:
  Seg{text: String, pf: {Spec.seg_ok(text) == True{} : Bool}}
type Path is Data:
  Path{segs: List<&2, Seg>, pf: {Spec.seg_count_ok(List.length(&2, Seg, segs)) == True{} : Bool}}
type Query is Data:
  Query{text: String, pf: {Spec.query_ok(text) == True{} : Bool}}
type Hval is Data:
  Hval{text: String, pf: {Spec.hval_ok(text) == True{} : Bool}}
type Clen is Data:
  Clen{n: U32, pf: {Spec.clen_ok(n) == True{} : Bool}}
# REQUEST
# -------
type Method is Data:
  GET{}
  HEAD{}
  POST{}
  PUT{}
  PATCH{}
  DELETE{}
# The headers this server reads. Everything else is checked for syntax and
# then ignored.
type Hdrs is Data:
  Hdrs{host: Maybe<&2, Hval>, cookie: Maybe<&2, Hval>, clen: Maybe<&2, Clen>, ctype: Maybe<&2, Hval>, origin: Maybe<&2, Hval>, site: Maybe<&2, Hval>, ds: Maybe<&2, Hval>}
type Head is Data:
  Head{method: Method, path: Path, query: Query, hdrs: Hdrs}
# Headers, and the bytes after the blank line.
type HB is Data:
  HB{hdrs: Hdrs, rest: String}

type Parse is Data:
  PMore{}
  PBad{status: U32}
  PDone{head: Head, body: String}
# LINES
# -----
type Line is Data:
  LLine{text: String, rest: String}
  LMore{}
  LBad{}
# SPLITTING
# ---------
# s split at the first x: the part before, and the part after if x occurs.
type Split is Data:
  Split{before: String, after: Maybe<&2, String>}
type Target is Data:
  Target{path: Path, query: Query}
type RLine is Data:
  RLine{method: Method, target: Target}
def mk_seg.go(b: Bool, +s: String, e: {Spec.seg_ok(s) == b : Bool}) -> Maybe<&2, Seg>:
  match b:
    case True{}:
      Some{Seg{s, e}}
    case False{}:
      None{}
def mk_seg(+s: String) -> Maybe<&2, Seg>:
  mk_seg.go(Spec.seg_ok(s), s, {==})
def mk_path.go(b: Bool, +xs: List<&2, Seg>, e: {Spec.seg_count_ok(List.length(&2, Seg, xs)) == b : Bool}) -> Maybe<&2, Path>:
  match b:
    case True{}:
      Some{Path{xs, e}}
    case False{}:
      None{}
def mk_path(+xs: List<&2, Seg>) -> Maybe<&2, Path>:
  mk_path.go(Spec.seg_count_ok(List.length(&2, Seg, xs)), xs, {==})
def mk_query.go(b: Bool, +s: String, e: {Spec.query_ok(s) == b : Bool}) -> Maybe<&2, Query>:
  match b:
    case True{}:
      Some{Query{s, e}}
    case False{}:
      None{}
def mk_query(+s: String) -> Maybe<&2, Query>:
  mk_query.go(Spec.query_ok(s), s, {==})
def mk_hval.go(b: Bool, +s: String, e: {Spec.hval_ok(s) == b : Bool}) -> Maybe<&2, Hval>:
  match b:
    case True{}:
      Some{Hval{s, e}}
    case False{}:
      None{}
def mk_hval(+s: String) -> Maybe<&2, Hval>:
  mk_hval.go(Spec.hval_ok(s), s, {==})
def mk_clen.go(b: Bool, +n: U32, e: {Spec.clen_ok(n) == b : Bool}) -> Maybe<&2, Clen>:
  match b:
    case True{}:
      Some{Clen{n, e}}
    case False{}:
      None{}
def mk_clen(+n: U32) -> Maybe<&2, Clen>:
  mk_clen.go(Spec.clen_ok(n), n, {==})
def Seg.text(g: Seg) -> String:
  match g:
    case Seg{t, p}:
      t
def Path.segs(p: Path) -> List<&2, Seg>:
  match p:
    case Path{xs, pf}:
      xs
def Query.text(q: Query) -> String:
  match q:
    case Query{t, p}:
      t
def Hval.text(h: Hval) -> String:
  match h:
    case Hval{t, p}:
      t
def Clen.n(c: Clen) -> U32:
  match c:
    case Clen{n, p}:
      n
def Hdrs.empty() -> Hdrs:
  Hdrs{None{}, None{}, None{}, None{}, None{}, None{}, None{}}
# 0: ordinary, 1: CR, 2: LF.
def line_class(+c: Char) -> Nat:
  U32.to_nat((Bool.to_u32(Char.is_eq(c, '\r')) + (2 * Bool.to_u32(Char.is_eq(c, '\n'))) : U32))
def line_cons(+c: Char, r: Line) -> Line:
  match r:
    case LLine{t, rest}:
      LLine{SCon{c, t}, rest}
    case LMore{}:
      LMore{}
    case LBad{}:
      LBad{}
def line_lf(b: Bool, t: String) -> Line:
  match b:
    case True{}:
      LLine{"", t}
    case False{}:
      LBad{}
def line_cr(t: String) -> Line:
  match t:
    case SNil{}:
      LMore{}
    case SCon{+d, t2}:
      line_lf(Char.is_eq(d, '\n'), t2)
# Budget n bounds the line length; running out rejects the line.
def line_go(n: Nat, k: Nat, +c: Char, t: String) -> Line:
  match n:
    case 0n:
      LBad{}
    case 1n+p:
      match k:
        case 0n:
          match t:
            case SNil{}:
              LMore{}
            case SCon{+d, t2}:
              line_cons(c, line_go(p, line_class(d), d, t2))
        case 1n:
          line_cr(t)
        case _:
          LBad{}
# The first line of s (without its CRLF) and what follows it.
def take_line(s: String) -> Line:
  match s:
    case SNil{}:
      LMore{}
    case SCon{+c, t}:
      line_go(Spec.lim_line(), line_class(c), c, t)
def split_cons(+c: Char, r: Split) -> Split:
  match r:
    case Split{b, a}:
      Split{SCon{c, b}, a}
# c is the current character and hit whether it equals x; t is what follows.
def split_go(t: String, +c: Char, hit: Bool, +x: Char) -> Split:
  match t:
    case SNil{}:
      match hit:
        case True{}:
          Split{"", Some{""}}
        case False{}:
          Split{SCon{c, ""}, None{}}
    case SCon{+d, t2}:
      match hit:
        case True{}:
          Split{"", Some{SCon{d, t2}}}
        case False{}:
          split_cons(c, split_go(t2, d, Char.is_eq(d, x), x))
def split_at(s: String, +x: Char) -> Split:
  match s:
    case SNil{}:
      Split{"", None{}}
    case SCon{+c, t}:
      split_go(t, c, Char.is_eq(c, x), x)
def method_pick(k: Nat) -> Maybe<&2, Method>:
  match k:
    case 0n:
      None{}
    case 1n:
      Some{GET{}}
    case 2n:
      Some{HEAD{}}
    case 3n:
      Some{POST{}}
    case 4n:
      Some{PUT{}}
    case 5n:
      Some{PATCH{}}
    case 6n:
      Some{DELETE{}}
    case _:
      None{}
# REQUEST LINE
# ------------
def method_of(+s: String) -> Maybe<&2, Method>:
  method_pick(U32.to_nat((Bool.to_u32(String.eq(s, "GET")) + (2 * Bool.to_u32(String.eq(s, "HEAD"))) + (3 * Bool.to_u32(String.eq(s, "POST"))) + (4 * Bool.to_u32(String.eq(s, "PUT"))) + (5 * Bool.to_u32(String.eq(s, "PATCH"))) + (6 * Bool.to_u32(String.eq(s, "DELETE"))) : U32)))
# Segments, all valid, or None.
def segs_cons(a: Maybe<&2, Seg>, b: Maybe<&2, List<&2, Seg>>) -> Maybe<&2, List<&2, Seg>>:
  match a b:
    case Some{x} Some{xs}:
      Some{x <> xs}
    case _ _:
      None{}
def mk_segs(xs: List<&2, String>) -> Maybe<&2, List<&2, Seg>>:
  match xs:
    case Nil{}:
      Some{Nil{}}
    case Con{+x, t}:
      segs_cons(mk_seg(x), mk_segs(t))
def path_of_segs(m: Maybe<&2, List<&2, Seg>>) -> Maybe<&2, Path>:
  match m:
    case None{}:
      None{}
    case Some{+xs}:
      mk_path(xs)
# "/" is the empty path; otherwise "/a/b" splits into ["a", "b"].
def path_rest(e: Bool, +s: String) -> Maybe<&2, Path>:
  match e:
    case True{}:
      mk_path(Nil{})
    case False{}:
      path_of_segs(mk_segs(String.split(s, '/')))
def path_slash(b: Bool, +t: String) -> Maybe<&2, Path>:
  match b:
    case True{}:
      path_rest(String.is_empty(t), t)
    case False{}:
      None{}
def path_parse(s: String) -> Maybe<&2, Path>:
  match s:
    case SNil{}:
      None{}
    case SCon{+c, +t}:
      path_slash(Char.is_eq(c, '/'), t)
def query_parse(m: Maybe<&2, String>) -> Maybe<&2, Query>:
  match m:
    case None{}:
      mk_query("")
    case Some{+q}:
      mk_query(q)
def target_join(p: Maybe<&2, Path>, q: Maybe<&2, Query>) -> Maybe<&2, Target>:
  match p q:
    case Some{x} Some{y}:
      Some{Target{x, y}}
    case _ _:
      None{}
def target_split(r: Split) -> Maybe<&2, Target>:
  match r:
    case Split{p, q}:
      target_join(path_parse(p), query_parse(q))
def target_parse(+s: String) -> Maybe<&2, Target>:
  target_split(split_at(s, '?'))
def rline_join(m: Maybe<&2, Method>, t: Maybe<&2, Target>, v: Bool) -> Result<&2, &2, U32, RLine>:
  match m t v:
    case Some{x} Some{y} True{}:
      Done{RLine{x, y}}
    case None{} _ _:
      Fail{501}
    case _ None{} _:
      Fail{400}
    case _ _ False{}:
      Fail{505}
def rline_ver(+m: String, +tgt: String, v: Maybe<&2, String>) -> Result<&2, &2, U32, RLine>:
  match v:
    case None{}:
      Fail{400}
    case Some{+ver}:
      rline_join(method_of(m), target_parse(tgt), String.eq(ver, "HTTP/1.1"))
def rline_parts2(+m: String, r: Split) -> Result<&2, &2, U32, RLine>:
  match r:
    case Split{+tgt, v}:
      rline_ver(m, tgt, v)
def rline_rest(+m: String, rest: Maybe<&2, String>) -> Result<&2, &2, U32, RLine>:
  match rest:
    case None{}:
      Fail{400}
    case Some{+r2}:
      rline_parts2(m, split_at(r2, ' '))
def rline_parts(r: Split) -> Result<&2, &2, U32, RLine>:
  match r:
    case Split{+m, rest}:
      rline_rest(m, rest)
def rline_parse(+line: String) -> Result<&2, &2, U32, RLine>:
  rline_parts(split_at(line, ' '))
# HEADERS
# -------
# RFC 9110 tchar: ! # $ % & ' * + - . ^ _ ` | ~ DIGIT ALPHA
def tchar(+c: Char) -> Bool:
  +x = Char.to_u32(c)
  Bool.or(Spec.is_alnum(x), Bool.or(U32.is_eq(x, 33), Bool.or(Spec.in_range(x, 35, 39), Bool.or(U32.is_eq(x, 42), Bool.or(U32.is_eq(x, 43), Bool.or(U32.is_eq(x, 45), Bool.or(U32.is_eq(x, 46), Bool.or(Spec.in_range(x, 94, 96), Bool.or(U32.is_eq(x, 124), U32.is_eq(x, 126))))))))))
def all_tchar(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{+h, t}:
      Bool.and(tchar(h), all_tchar(t))
def name_ok(+s: String) -> Bool:
  Bool.and(Bool.not(String.is_empty(s)), Bool.and(Nat.is_le(String.length(s), 64n), all_tchar(s)))
def is_ows(+c: Char) -> Bool:
  Bool.or(Char.is_eq(c, ' '), Char.is_eq(c, '\t'))
# c is the current character and ws whether it is whitespace.
def trim_go(t: String, +c: Char, ws: Bool) -> String:
  match t:
    case SNil{}:
      match ws:
        case True{}:
          SNil{}
        case False{}:
          SCon{c, SNil{}}
    case SCon{+d, t2}:
      match ws:
        case True{}:
          trim_go(t2, d, is_ows(d))
        case False{}:
          SCon{c, SCon{d, t2}}
def trim_start(s: String) -> String:
  match s:
    case SNil{}:
      SNil{}
    case SCon{+c, t}:
      trim_go(t, c, is_ows(c))
def trim_ows(+s: String) -> String:
  String.reverse(trim_start(String.reverse(trim_start(s))))
def digit_step(b: Bool, +c: Char, r: Maybe<&2, U32>) -> Maybe<&2, U32>:
  match b:
    case True{}:
      r
    case False{}:
      None{}
# 1..7 decimal digits (at most 9,999,999, so a U32 never overflows).
def digits_go(s: String, +acc: U32) -> Maybe<&2, U32>:
  match s:
    case SNil{}:
      Some{acc}
    case SCon{+c, t}:
      digit_step(Char.is_digit(c), c, digits_go(t, ((acc * 10) + (Char.to_u32(c) - 48) : U32)))
def clen_of(m: Maybe<&2, U32>) -> Maybe<&2, Clen>:
  match m:
    case None{}:
      None{}
    case Some{+n}:
      mk_clen(n)
def clen_parse.go(b: Bool, +s: String) -> Maybe<&2, Clen>:
  match b:
    case True{}:
      clen_of(digits_go(s, 0))
    case False{}:
      None{}
def clen_parse(+s: String) -> Maybe<&2, Clen>:
  clen_parse.go(Bool.and(Bool.not(String.is_empty(s)), Nat.is_le(String.length(s), 7n)), s)
# Which header: 0 other, 1 host, 2 cookie, 3 content-length, 4 content-type,
# 5 origin, 6 sec-fetch-site, 7 datastar-request, 8 transfer-encoding.
def header_id(+n: String) -> Nat:
  U32.to_nat((Bool.to_u32(String.eq(n, "host")) + (2 * Bool.to_u32(String.eq(n, "cookie"))) + (3 * Bool.to_u32(String.eq(n, "content-length"))) + (4 * Bool.to_u32(String.eq(n, "content-type"))) + (5 * Bool.to_u32(String.eq(n, "origin"))) + (6 * Bool.to_u32(String.eq(n, "sec-fetch-site"))) + (7 * Bool.to_u32(String.eq(n, "datastar-request"))) + (8 * Bool.to_u32(String.eq(n, "transfer-encoding"))) : U32))
# Set a field that must not already be present.
def set_once(-A: Data, old: Maybe<&2, A>, new: Maybe<&2, A>) -> Result<&2, &2, U32, Maybe<&2, A>>:
  match old new:
    case None{} Some{v}:
      Done{Some{v}}
    case _ _:
      Fail{400}
def hdrs_put_host(r: Result<&2, &2, U32, Maybe<&2, Hval>>, cookie: Maybe<&2, Hval>, clen: Maybe<&2, Clen>, ctype: Maybe<&2, Hval>, origin: Maybe<&2, Hval>, site: Maybe<&2, Hval>, ds: Maybe<&2, Hval>) -> Result<&2, &2, U32, Hdrs>:
  match r:
    case Fail{code}:
      Fail{code}
    case Done{x}:
      Done{Hdrs{x, cookie, clen, ctype, origin, site, ds}}
def hdrs_put_cookie(r: Result<&2, &2, U32, Maybe<&2, Hval>>, host: Maybe<&2, Hval>, clen: Maybe<&2, Clen>, ctype: Maybe<&2, Hval>, origin: Maybe<&2, Hval>, site: Maybe<&2, Hval>, ds: Maybe<&2, Hval>) -> Result<&2, &2, U32, Hdrs>:
  match r:
    case Fail{code}:
      Fail{code}
    case Done{x}:
      Done{Hdrs{host, x, clen, ctype, origin, site, ds}}
def hdrs_put_clen(r: Result<&2, &2, U32, Maybe<&2, Clen>>, host: Maybe<&2, Hval>, cookie: Maybe<&2, Hval>, ctype: Maybe<&2, Hval>, origin: Maybe<&2, Hval>, site: Maybe<&2, Hval>, ds: Maybe<&2, Hval>) -> Result<&2, &2, U32, Hdrs>:
  match r:
    case Fail{code}:
      Fail{code}
    case Done{x}:
      Done{Hdrs{host, cookie, x, ctype, origin, site, ds}}
def hdrs_put_ctype(r: Result<&2, &2, U32, Maybe<&2, Hval>>, host: Maybe<&2, Hval>, cookie: Maybe<&2, Hval>, clen: Maybe<&2, Clen>, origin: Maybe<&2, Hval>, site: Maybe<&2, Hval>, ds: Maybe<&2, Hval>) -> Result<&2, &2, U32, Hdrs>:
  match r:
    case Fail{code}:
      Fail{code}
    case Done{x}:
      Done{Hdrs{host, cookie, clen, x, origin, site, ds}}
def hdrs_put_origin(r: Result<&2, &2, U32, Maybe<&2, Hval>>, host: Maybe<&2, Hval>, cookie: Maybe<&2, Hval>, clen: Maybe<&2, Clen>, ctype: Maybe<&2, Hval>, site: Maybe<&2, Hval>, ds: Maybe<&2, Hval>) -> Result<&2, &2, U32, Hdrs>:
  match r:
    case Fail{code}:
      Fail{code}
    case Done{x}:
      Done{Hdrs{host, cookie, clen, ctype, x, site, ds}}
def hdrs_put_site(r: Result<&2, &2, U32, Maybe<&2, Hval>>, host: Maybe<&2, Hval>, cookie: Maybe<&2, Hval>, clen: Maybe<&2, Clen>, ctype: Maybe<&2, Hval>, origin: Maybe<&2, Hval>, ds: Maybe<&2, Hval>) -> Result<&2, &2, U32, Hdrs>:
  match r:
    case Fail{code}:
      Fail{code}
    case Done{x}:
      Done{Hdrs{host, cookie, clen, ctype, origin, x, ds}}
def hdrs_put_ds(r: Result<&2, &2, U32, Maybe<&2, Hval>>, host: Maybe<&2, Hval>, cookie: Maybe<&2, Hval>, clen: Maybe<&2, Clen>, ctype: Maybe<&2, Hval>, origin: Maybe<&2, Hval>, site: Maybe<&2, Hval>) -> Result<&2, &2, U32, Hdrs>:
  match r:
    case Fail{code}:
      Fail{code}
    case Done{x}:
      Done{Hdrs{host, cookie, clen, ctype, origin, site, x}}
def hdrs_set(h: Hdrs, k: Nat, +v: Hval, +raw: String) -> Result<&2, &2, U32, Hdrs>:
  match h:
    case Hdrs{host, cookie, clen, ctype, origin, site, ds}:
      match k:
        case 0n:
          Done{Hdrs{host, cookie, clen, ctype, origin, site, ds}}
        case 1n:
          hdrs_put_host(set_once(Hval, host, Some{v}), cookie, clen, ctype, origin, site, ds)
        case 2n:
          hdrs_put_cookie(set_once(Hval, cookie, Some{v}), host, clen, ctype, origin, site, ds)
        case 3n:
          hdrs_put_clen(set_once(Clen, clen, clen_parse(raw)), host, cookie, ctype, origin, site, ds)
        case 4n:
          hdrs_put_ctype(set_once(Hval, ctype, Some{v}), host, cookie, clen, origin, site, ds)
        case 5n:
          hdrs_put_origin(set_once(Hval, origin, Some{v}), host, cookie, clen, ctype, site, ds)
        case 6n:
          hdrs_put_site(set_once(Hval, site, Some{v}), host, cookie, clen, ctype, origin, ds)
        case 7n:
          hdrs_put_ds(set_once(Hval, ds, Some{v}), host, cookie, clen, ctype, origin, site)
        case _:
          Fail{501}
def header_val(h: Hdrs, +name: String, v: Maybe<&2, Hval>, +raw: String) -> Result<&2, &2, U32, Hdrs>:
  match v:
    case None{}:
      Fail{400}
    case Some{+hv}:
      hdrs_set(h, header_id(String.to_lower(name)), hv, raw)
def header_named(b: Bool, h: Hdrs, +name: String, +raw: String) -> Result<&2, &2, U32, Hdrs>:
  match b:
    case True{}:
      header_val(h, name, mk_hval(raw), raw)
    case False{}:
      Fail{400}
def header_after(h: Hdrs, +name: String, v: Maybe<&2, String>) -> Result<&2, &2, U32, Hdrs>:
  match v:
    case None{}:
      Fail{400}
    case Some{raw}:
      header_named(name_ok(name), h, name, trim_ows(raw))
def header_split(h: Hdrs, r: Split) -> Result<&2, &2, U32, Hdrs>:
  match r:
    case Split{+name, v}:
      header_after(h, name, v)
def header_add(h: Hdrs, +line: String) -> Result<&2, &2, U32, Hdrs>:
  header_split(h, split_at(line, ':'))
# HEAD
# ----
# Header lines until the blank line. n bounds how many header lines remain.
# `acc` carries the headers so far (or the failure), `lr` the next line.
def headers_go(n: Nat, acc: Result<&2, &2, U32, Hdrs>, lr: Line) -> Result<&2, &2, U32, HB>:
  match n:
    case 0n:
      Fail{431}
    case 1n+p:
      match acc:
        case Fail{code}:
          Fail{code}
        case Done{h}:
          match lr:
            case LMore{}:
              Fail{0}
            case LBad{}:
              Fail{400}
            case LLine{l, rest}:
              match l:
                case SNil{}:
                  Done{HB{h, rest}}
                case SCon{c, lt}:
                  headers_go(p, header_add(h, SCon{c, lt}), take_line(rest))
# Status 0 is the internal "need more bytes".
def head_fail(k: Nat, +code: U32) -> Parse:
  match k:
    case 0n:
      PMore{}
    case _:
      PBad{code}
def head_join(r: RLine, hs: Result<&2, &2, U32, HB>) -> Parse:
  match r:
    case RLine{m, t}:
      match t:
        case Target{p, q}:
          match hs:
            case Fail{+code}:
              head_fail(U32.to_nat(code), code)
            case Done{hb}:
              match hb:
                case HB{h, body}:
                  PDone{Head{m, p, q, h}, body}
def head_rline(r: Result<&2, &2, U32, RLine>, rest: String) -> Parse:
  match r:
    case Fail{code}:
      PBad{code}
    case Done{rl}:
      head_join(rl, headers_go(Nat.add(Spec.lim_headers(), 1n), Done{Hdrs.empty()}, take_line(rest)))
def head_line(lr: Line) -> Parse:
  match lr:
    case LMore{}:
      PMore{}
    case LBad{}:
      PBad{400}
    case LLine{l, rest}:
      head_rline(rline_parse(l), rest)
# Parse the request head from the bytes received so far.
def parse(buf: String) -> Parse:
  head_line(take_line(buf))
