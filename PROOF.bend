# Proofs of LAWS.bend.
import Base
import ./src/html.bend as Html
import ./spec/html.bend as HtmlSpec
import ./src/http.bend as Http
import ./LAWS.bend as Laws

# If a && b is True, then a is True.
def and_left(a: Bool, -b: Bool, e: {Bool.and(a, b) == True{} : Bool}) -> {a == True{} : Bool}:
  match a:
    case True{}:
      {==}
    case False{}:
      e

# Each encoding branch emits a fixed entity (whose characters compute to
# safe) in front of x, or just x.
def enc_apos_ok(b: Bool, -x: String, hx: {HtmlSpec.safe_str(x) == True{} : Bool}) -> {HtmlSpec.safe_str(Html.enc_apos(b, x)) == True{} : Bool}:
  match b:
    case True{}:
      hx
    case False{}:
      hx

def enc_quot_ok(b: Bool, +h: Char, -x: String, hx: {HtmlSpec.safe_str(x) == True{} : Bool}) -> {HtmlSpec.safe_str(Html.enc_quot(b, h, x)) == True{} : Bool}:
  match b:
    case True{}:
      hx
    case False{}:
      enc_apos_ok(Char.is_eq(h, '\''), x, hx)

def enc_amp_ok(b: Bool, +h: Char, -x: String, hx: {HtmlSpec.safe_str(x) == True{} : Bool}) -> {HtmlSpec.safe_str(Html.enc_amp(b, h, x)) == True{} : Bool}:
  match b:
    case True{}:
      hx
    case False{}:
      enc_quot_ok(Char.is_eq(h, '"'), h, x, hx)

def enc_gt_ok(b: Bool, +h: Char, -x: String, hx: {HtmlSpec.safe_str(x) == True{} : Bool}) -> {HtmlSpec.safe_str(Html.enc_gt(b, h, x)) == True{} : Bool}:
  match b:
    case True{}:
      hx
    case False{}:
      enc_amp_ok(Char.is_eq(h, '&'), h, x, hx)

def enc_lt_ok(b: Bool, +h: Char, -x: String, hx: {HtmlSpec.safe_str(x) == True{} : Bool}) -> {HtmlSpec.safe_str(Html.enc_lt(b, h, x)) == True{} : Bool}:
  match b:
    case True{}:
      hx
    case False{}:
      enc_gt_ok(Char.is_eq(h, '>'), h, x, hx)

# One character: a plain one is copied, and plain means the implementation's
# base_ok holds, which must match the spec's safe_char; any other is encoded.
def pick_ok(b: Bool, +h: Char, -x: String, e: {Html.plain(h) == b : Bool}, hx: {HtmlSpec.safe_str(x) == True{} : Bool}) -> {HtmlSpec.safe_str(Html.pick(b, h, x)) == True{} : Bool}:
  match b:
    case True{}:
      hb = and_left(Html.base_ok(h), U32.is_ne(Char.to_u32(h), 38), e)
      %Equal.sym(Bool, Html.base_ok(h), True{}, hb) : {Bool.and(_, HtmlSpec.safe_str(x)) == True{} : Bool}
      hx
    case False{}:
      enc_lt_ok(Char.is_eq(h, '<'), h, x, hx)

def Laws.html_esc_safe(s, rest, hr):
  match s:
    case SNil{}:
      hr
    case SCon{+h, t}:
      pick_ok(Html.plain(h), h, Html.esc(t, rest), {==}, Laws.html_esc_safe(t, rest, hr))

def Laws.html_esc_safe_alone(s):
  Laws.html_esc_safe(s, "", {==})

# HTTP: each refinement type carries its proof; the laws read it back.
def Laws.http_seg_ok(g):
  match g:
    case Http.Seg{t, p}:
      p

def Laws.http_path_bounded(x):
  match x:
    case Http.Path{xs, p}:
      p

def Laws.http_query_ok(q):
  match q:
    case Http.Query{t, p}:
      p

def Laws.http_hval_ok(h):
  match h:
    case Http.Hval{t, p}:
      p

def Laws.http_clen_ok(c):
  match c:
    case Http.Clen{n, p}:
      p

# REQUEST SMUGGLING

# True means Empty, False means Unit: rewriting {False == True} through this
# turns a Unit into an Empty.
def bool_disc(b: Bool) -> Type:
  match b:
    case True{}:
      Empty
    case False{}:
      Unit

def false_ne_true(e: {False{} == True{} : Bool}) -> Empty:
  %e : bool_disc(_)
  Unit{}

# Transfer-Encoding: once the name is known to lower-case to
# "transfer-encoding", header_id computes 8, and hdrs_set fails on 8.
def te_set(h: Http.Hdrs, -v: Http.Hval, -t: String) -> {Laws.is_fail(Http.Hdrs, Http.hdrs_set(h, 8n, v, t)) == True{} : Bool}:
  match h:
    case Http.Hdrs{host, cookie, clen, ctype, origin, site, ds}:
      {==}

def te_val(m: Maybe<&2, Http.Hval>, h: Http.Hdrs, -name: String, -t: String, e: {String.to_lower(name) == "transfer-encoding" : String}) -> {Laws.is_fail(Http.Hdrs, Http.header_val(h, name, m, t)) == True{} : Bool}:
  match m:
    case None{}:
      {==}
    case Some{v}:
      %Equal.sym(String, String.to_lower(name), "transfer-encoding", e) : {Laws.is_fail(Http.Hdrs, Http.hdrs_set(h, Http.header_id(_), v, t)) == True{} : Bool}
      te_set(h, v, t)

def te_named(b: Bool, h: Http.Hdrs, -name: String, +t: String, e: {String.to_lower(name) == "transfer-encoding" : String}) -> {Laws.is_fail(Http.Hdrs, Http.header_named(b, h, name, t)) == True{} : Bool}:
  match b:
    case True{}:
      te_val(Http.mk_hval(t), h, name, t, e)
    case False{}:
      {==}

def Laws.http_te_rejected(h, name, raw, e):
  te_named(Http.name_ok(name), h, name, Http.trim_ows(raw), e)

# No duplicates: a present field makes set_once fail; an absent one makes
# the hypothesis {False == True}, which is impossible.
def no_dup_absurd(z: Empty, -h: Http.Hdrs, -k: Nat, -v: Http.Hval, -raw: String) -> {Laws.is_fail(Http.Hdrs, Http.hdrs_set(h, k, v, raw)) == True{} : Bool}:
  match z:

def dup_host(host: Maybe<&2, Http.Hval>, -cookie: Maybe<&2, Http.Hval>, -clen: Maybe<&2, Http.Clen>, -ctype: Maybe<&2, Http.Hval>, -origin: Maybe<&2, Http.Hval>, -site: Maybe<&2, Http.Hval>, -ds: Maybe<&2, Http.Hval>, -v: Http.Hval, -raw: String, e: {Maybe.is_some(&2, Http.Hval, host) == True{} : Bool}) -> {Laws.is_fail(Http.Hdrs, Http.hdrs_set(Http.Hdrs{host, cookie, clen, ctype, origin, site, ds}, 1n, v, raw)) == True{} : Bool}:
  match host:
    case None{}:
      no_dup_absurd(false_ne_true(e), Http.Hdrs{None{}, cookie, clen, ctype, origin, site, ds}, 1n, v, raw)
    case Some{x}:
      {==}

def dup_cookie(-host: Maybe<&2, Http.Hval>, cookie: Maybe<&2, Http.Hval>, -clen: Maybe<&2, Http.Clen>, -ctype: Maybe<&2, Http.Hval>, -origin: Maybe<&2, Http.Hval>, -site: Maybe<&2, Http.Hval>, -ds: Maybe<&2, Http.Hval>, -v: Http.Hval, -raw: String, e: {Maybe.is_some(&2, Http.Hval, cookie) == True{} : Bool}) -> {Laws.is_fail(Http.Hdrs, Http.hdrs_set(Http.Hdrs{host, cookie, clen, ctype, origin, site, ds}, 2n, v, raw)) == True{} : Bool}:
  match cookie:
    case None{}:
      no_dup_absurd(false_ne_true(e), Http.Hdrs{host, None{}, clen, ctype, origin, site, ds}, 2n, v, raw)
    case Some{x}:
      {==}

def dup_clen(-host: Maybe<&2, Http.Hval>, -cookie: Maybe<&2, Http.Hval>, clen: Maybe<&2, Http.Clen>, -ctype: Maybe<&2, Http.Hval>, -origin: Maybe<&2, Http.Hval>, -site: Maybe<&2, Http.Hval>, -ds: Maybe<&2, Http.Hval>, -v: Http.Hval, -raw: String, e: {Maybe.is_some(&2, Http.Clen, clen) == True{} : Bool}) -> {Laws.is_fail(Http.Hdrs, Http.hdrs_set(Http.Hdrs{host, cookie, clen, ctype, origin, site, ds}, 3n, v, raw)) == True{} : Bool}:
  match clen:
    case None{}:
      no_dup_absurd(false_ne_true(e), Http.Hdrs{host, cookie, None{}, ctype, origin, site, ds}, 3n, v, raw)
    case Some{x}:
      {==}

def dup_ctype(-host: Maybe<&2, Http.Hval>, -cookie: Maybe<&2, Http.Hval>, -clen: Maybe<&2, Http.Clen>, ctype: Maybe<&2, Http.Hval>, -origin: Maybe<&2, Http.Hval>, -site: Maybe<&2, Http.Hval>, -ds: Maybe<&2, Http.Hval>, -v: Http.Hval, -raw: String, e: {Maybe.is_some(&2, Http.Hval, ctype) == True{} : Bool}) -> {Laws.is_fail(Http.Hdrs, Http.hdrs_set(Http.Hdrs{host, cookie, clen, ctype, origin, site, ds}, 4n, v, raw)) == True{} : Bool}:
  match ctype:
    case None{}:
      no_dup_absurd(false_ne_true(e), Http.Hdrs{host, cookie, clen, None{}, origin, site, ds}, 4n, v, raw)
    case Some{x}:
      {==}

def dup_origin(-host: Maybe<&2, Http.Hval>, -cookie: Maybe<&2, Http.Hval>, -clen: Maybe<&2, Http.Clen>, -ctype: Maybe<&2, Http.Hval>, origin: Maybe<&2, Http.Hval>, -site: Maybe<&2, Http.Hval>, -ds: Maybe<&2, Http.Hval>, -v: Http.Hval, -raw: String, e: {Maybe.is_some(&2, Http.Hval, origin) == True{} : Bool}) -> {Laws.is_fail(Http.Hdrs, Http.hdrs_set(Http.Hdrs{host, cookie, clen, ctype, origin, site, ds}, 5n, v, raw)) == True{} : Bool}:
  match origin:
    case None{}:
      no_dup_absurd(false_ne_true(e), Http.Hdrs{host, cookie, clen, ctype, None{}, site, ds}, 5n, v, raw)
    case Some{x}:
      {==}

def dup_site(-host: Maybe<&2, Http.Hval>, -cookie: Maybe<&2, Http.Hval>, -clen: Maybe<&2, Http.Clen>, -ctype: Maybe<&2, Http.Hval>, -origin: Maybe<&2, Http.Hval>, site: Maybe<&2, Http.Hval>, -ds: Maybe<&2, Http.Hval>, -v: Http.Hval, -raw: String, e: {Maybe.is_some(&2, Http.Hval, site) == True{} : Bool}) -> {Laws.is_fail(Http.Hdrs, Http.hdrs_set(Http.Hdrs{host, cookie, clen, ctype, origin, site, ds}, 6n, v, raw)) == True{} : Bool}:
  match site:
    case None{}:
      no_dup_absurd(false_ne_true(e), Http.Hdrs{host, cookie, clen, ctype, origin, None{}, ds}, 6n, v, raw)
    case Some{x}:
      {==}

def dup_ds(-host: Maybe<&2, Http.Hval>, -cookie: Maybe<&2, Http.Hval>, -clen: Maybe<&2, Http.Clen>, -ctype: Maybe<&2, Http.Hval>, -origin: Maybe<&2, Http.Hval>, -site: Maybe<&2, Http.Hval>, ds: Maybe<&2, Http.Hval>, -v: Http.Hval, -raw: String, e: {Maybe.is_some(&2, Http.Hval, ds) == True{} : Bool}) -> {Laws.is_fail(Http.Hdrs, Http.hdrs_set(Http.Hdrs{host, cookie, clen, ctype, origin, site, ds}, 7n, v, raw)) == True{} : Bool}:
  match ds:
    case None{}:
      no_dup_absurd(false_ne_true(e), Http.Hdrs{host, cookie, clen, ctype, origin, site, None{}}, 7n, v, raw)
    case Some{x}:
      {==}

def Laws.http_no_dup(h, k, v, raw, e):
  match h:
    case Http.Hdrs{host, cookie, clen, ctype, origin, site, ds}:
      match k:
        case 0n:
          no_dup_absurd(false_ne_true(e), Http.Hdrs{host, cookie, clen, ctype, origin, site, ds}, 0n, v, raw)
        case 1n:
          dup_host(host, cookie, clen, ctype, origin, site, ds, v, raw, e)
        case 2n:
          dup_cookie(host, cookie, clen, ctype, origin, site, ds, v, raw, e)
        case 3n:
          dup_clen(host, cookie, clen, ctype, origin, site, ds, v, raw, e)
        case 4n:
          dup_ctype(host, cookie, clen, ctype, origin, site, ds, v, raw, e)
        case 5n:
          dup_origin(host, cookie, clen, ctype, origin, site, ds, v, raw, e)
        case 6n:
          dup_site(host, cookie, clen, ctype, origin, site, ds, v, raw, e)
        case 7n:
          dup_ds(host, cookie, clen, ctype, origin, site, ds, v, raw, e)
        case 8n+q:
          no_dup_absurd(false_ne_true(e), Http.Hdrs{host, cookie, clen, ctype, origin, site, ds}, 8n+q, v, raw)
