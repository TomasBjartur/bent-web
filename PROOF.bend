# Proofs of LAWS.bend.
import Base
import ./src/html.bend as Html
import ./spec/html.bend as HtmlSpec
import ./src/http.bend as Http
import ./proof/lemmas.bend as L
import ./spec/authz.bend as AuthzSpec
import ./src/authz.bend as Authz
import ./src/text.bend as Text
import ./spec/csrf.bend as CsrfSpec
import ./src/route.bend as Route
import ./spec/webauthn.bend as WSpec
import ./src/webauthn.bend as WA
import ./src/markdown.bend as Md
import ./src/crdt.bend as Crdt
import ./proof/crdt_lemmas.bend as CL
import ./LAWS.bend as Laws

# Each encoding branch emits a fixed entity (whose characters compute to
# safe) in front of x, or just x.
def enc_apos_ok(b: Bool, -x: String, hx: {HtmlSpec.safe_str(x) == True{} : Bool}) -> {HtmlSpec.safe_str(HtmlSpec.enc_apos(b, x)) == True{} : Bool}:
  match b:
    case True{}:
      hx
    case False{}:
      hx

def enc_quot_ok(b: Bool, +h: Char, -x: String, hx: {HtmlSpec.safe_str(x) == True{} : Bool}) -> {HtmlSpec.safe_str(HtmlSpec.enc_quot(b, h, x)) == True{} : Bool}:
  match b:
    case True{}:
      hx
    case False{}:
      enc_apos_ok(Char.is_eq(h, '\''), x, hx)

def enc_amp_ok(b: Bool, +h: Char, -x: String, hx: {HtmlSpec.safe_str(x) == True{} : Bool}) -> {HtmlSpec.safe_str(HtmlSpec.enc_amp(b, h, x)) == True{} : Bool}:
  match b:
    case True{}:
      hx
    case False{}:
      enc_quot_ok(Char.is_eq(h, '"'), h, x, hx)

def enc_gt_ok(b: Bool, +h: Char, -x: String, hx: {HtmlSpec.safe_str(x) == True{} : Bool}) -> {HtmlSpec.safe_str(HtmlSpec.enc_gt(b, h, x)) == True{} : Bool}:
  match b:
    case True{}:
      hx
    case False{}:
      enc_amp_ok(Char.is_eq(h, '&'), h, x, hx)

def enc_lt_ok(b: Bool, +h: Char, -x: String, hx: {HtmlSpec.safe_str(x) == True{} : Bool}) -> {HtmlSpec.safe_str(HtmlSpec.enc_lt(b, h, x)) == True{} : Bool}:
  match b:
    case True{}:
      hx
    case False{}:
      enc_gt_ok(Char.is_eq(h, '>'), h, x, hx)

# One character: a plain one is copied, and plain means the implementation's
# base_ok holds, which must match the spec's safe_char; any other is encoded.
def pick_ok(b: Bool, +h: Char, -x: String, e: {HtmlSpec.plain(h) == b : Bool}, hx: {HtmlSpec.safe_str(x) == True{} : Bool}) -> {HtmlSpec.safe_str(HtmlSpec.pick(b, h, x)) == True{} : Bool}:
  match b:
    case True{}:
      hb = L.and_left(HtmlSpec.base_ok(h), U32.is_ne(Char.to_u32(h), 38), e)
      %Equal.sym(Bool, HtmlSpec.base_ok(h), True{}, hb) : {Bool.and(_, HtmlSpec.safe_str(x)) == True{} : Bool}
      hx
    case False{}:
      enc_lt_ok(Char.is_eq(h, '<'), h, x, hx)

def Laws.html_esc_safe(s, rest, hr):
  match s:
    case SNil{}:
      hr
    case SCon{+h, t}:
      pick_ok(HtmlSpec.plain(h), h, HtmlSpec.esc(t, rest), {==}, Laws.html_esc_safe(t, rest, hr))

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
      no_dup_absurd(L.false_ne_true(e), Http.Hdrs{None{}, cookie, clen, ctype, origin, site, ds}, 1n, v, raw)
    case Some{x}:
      {==}

def dup_cookie(-host: Maybe<&2, Http.Hval>, cookie: Maybe<&2, Http.Hval>, -clen: Maybe<&2, Http.Clen>, -ctype: Maybe<&2, Http.Hval>, -origin: Maybe<&2, Http.Hval>, -site: Maybe<&2, Http.Hval>, -ds: Maybe<&2, Http.Hval>, -v: Http.Hval, -raw: String, e: {Maybe.is_some(&2, Http.Hval, cookie) == True{} : Bool}) -> {Laws.is_fail(Http.Hdrs, Http.hdrs_set(Http.Hdrs{host, cookie, clen, ctype, origin, site, ds}, 2n, v, raw)) == True{} : Bool}:
  match cookie:
    case None{}:
      no_dup_absurd(L.false_ne_true(e), Http.Hdrs{host, None{}, clen, ctype, origin, site, ds}, 2n, v, raw)
    case Some{x}:
      {==}

def dup_clen(-host: Maybe<&2, Http.Hval>, -cookie: Maybe<&2, Http.Hval>, clen: Maybe<&2, Http.Clen>, -ctype: Maybe<&2, Http.Hval>, -origin: Maybe<&2, Http.Hval>, -site: Maybe<&2, Http.Hval>, -ds: Maybe<&2, Http.Hval>, -v: Http.Hval, -raw: String, e: {Maybe.is_some(&2, Http.Clen, clen) == True{} : Bool}) -> {Laws.is_fail(Http.Hdrs, Http.hdrs_set(Http.Hdrs{host, cookie, clen, ctype, origin, site, ds}, 3n, v, raw)) == True{} : Bool}:
  match clen:
    case None{}:
      no_dup_absurd(L.false_ne_true(e), Http.Hdrs{host, cookie, None{}, ctype, origin, site, ds}, 3n, v, raw)
    case Some{x}:
      {==}

def dup_ctype(-host: Maybe<&2, Http.Hval>, -cookie: Maybe<&2, Http.Hval>, -clen: Maybe<&2, Http.Clen>, ctype: Maybe<&2, Http.Hval>, -origin: Maybe<&2, Http.Hval>, -site: Maybe<&2, Http.Hval>, -ds: Maybe<&2, Http.Hval>, -v: Http.Hval, -raw: String, e: {Maybe.is_some(&2, Http.Hval, ctype) == True{} : Bool}) -> {Laws.is_fail(Http.Hdrs, Http.hdrs_set(Http.Hdrs{host, cookie, clen, ctype, origin, site, ds}, 4n, v, raw)) == True{} : Bool}:
  match ctype:
    case None{}:
      no_dup_absurd(L.false_ne_true(e), Http.Hdrs{host, cookie, clen, None{}, origin, site, ds}, 4n, v, raw)
    case Some{x}:
      {==}

def dup_origin(-host: Maybe<&2, Http.Hval>, -cookie: Maybe<&2, Http.Hval>, -clen: Maybe<&2, Http.Clen>, -ctype: Maybe<&2, Http.Hval>, origin: Maybe<&2, Http.Hval>, -site: Maybe<&2, Http.Hval>, -ds: Maybe<&2, Http.Hval>, -v: Http.Hval, -raw: String, e: {Maybe.is_some(&2, Http.Hval, origin) == True{} : Bool}) -> {Laws.is_fail(Http.Hdrs, Http.hdrs_set(Http.Hdrs{host, cookie, clen, ctype, origin, site, ds}, 5n, v, raw)) == True{} : Bool}:
  match origin:
    case None{}:
      no_dup_absurd(L.false_ne_true(e), Http.Hdrs{host, cookie, clen, ctype, None{}, site, ds}, 5n, v, raw)
    case Some{x}:
      {==}

def dup_site(-host: Maybe<&2, Http.Hval>, -cookie: Maybe<&2, Http.Hval>, -clen: Maybe<&2, Http.Clen>, -ctype: Maybe<&2, Http.Hval>, -origin: Maybe<&2, Http.Hval>, site: Maybe<&2, Http.Hval>, -ds: Maybe<&2, Http.Hval>, -v: Http.Hval, -raw: String, e: {Maybe.is_some(&2, Http.Hval, site) == True{} : Bool}) -> {Laws.is_fail(Http.Hdrs, Http.hdrs_set(Http.Hdrs{host, cookie, clen, ctype, origin, site, ds}, 6n, v, raw)) == True{} : Bool}:
  match site:
    case None{}:
      no_dup_absurd(L.false_ne_true(e), Http.Hdrs{host, cookie, clen, ctype, origin, None{}, ds}, 6n, v, raw)
    case Some{x}:
      {==}

def dup_ds(-host: Maybe<&2, Http.Hval>, -cookie: Maybe<&2, Http.Hval>, -clen: Maybe<&2, Http.Clen>, -ctype: Maybe<&2, Http.Hval>, -origin: Maybe<&2, Http.Hval>, -site: Maybe<&2, Http.Hval>, ds: Maybe<&2, Http.Hval>, -v: Http.Hval, -raw: String, e: {Maybe.is_some(&2, Http.Hval, ds) == True{} : Bool}) -> {Laws.is_fail(Http.Hdrs, Http.hdrs_set(Http.Hdrs{host, cookie, clen, ctype, origin, site, ds}, 7n, v, raw)) == True{} : Bool}:
  match ds:
    case None{}:
      no_dup_absurd(L.false_ne_true(e), Http.Hdrs{host, cookie, clen, ctype, origin, site, None{}}, 7n, v, raw)
    case Some{x}:
      {==}

def Laws.http_no_dup(h, k, v, raw, e):
  match h:
    case Http.Hdrs{host, cookie, clen, ctype, origin, site, ds}:
      match k:
        case 0n:
          no_dup_absurd(L.false_ne_true(e), Http.Hdrs{host, cookie, clen, ctype, origin, site, ds}, 0n, v, raw)
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
          no_dup_absurd(L.false_ne_true(e), Http.Hdrs{host, cookie, clen, ctype, origin, site, ds}, 8n+q, v, raw)

# AUTHORIZATION

def Laws.authz_permit_ok(p):
  match p:
    case Authz.Permit{f, a, pf}:
      pf

# Anonymous: every non-read action's policy reduces to False (is_user(Anon)
# comes first in each check), so e is {False == True}, which is exactly the
# goal is_read(a) == True for a non-read action.
def Laws.authz_anon_read_only(blog, role, post, a, e):
  match a:
    case AuthzSpec.CreateBlog{}:
      e
    case AuthzSpec.EditBlog{b}:
      e
    case AuthzSpec.DeleteBlog{b}:
      e
    case AuthzSpec.AddAuthor{b, u}:
      e
    case AuthzSpec.RemoveAuthor{b, u}:
      e
    case AuthzSpec.CreatePost{b}:
      e
    case AuthzSpec.EditPost{p}:
      e
    case AuthzSpec.PublishPost{p}:
      e
    case AuthzSpec.DeletePost{p}:
      e
    case AuthzSpec.ReadPost{p}:
      {==}
    case AuthzSpec.ReadBlogAdmin{b}:
      e

# can_write_post needs the post's blog to equal the facts' blog; it does not.
def cwp_cross(+who: AuthzSpec.Principal, +blog: U32, +role: Maybe<&2, AuthzSpec.Role>, +p: U32, +pb: U32, +pub: Bool, +q: U32, ne: {U32.is_eq(pb, blog) == False{} : Bool}) -> {AuthzSpec.can_write_post(AuthzSpec.Facts{who, blog, role, Some{AuthzSpec.PostInfo{p, pb, pub}}}, q) == False{} : Bool}:
  %Equal.sym(Bool, U32.is_eq(pb, blog), False{}, ne) : {Bool.and(AuthzSpec.member_of(AuthzSpec.Facts{who, blog, role, Some{AuthzSpec.PostInfo{p, pb, pub}}}, blog), Bool.and(U32.is_eq(p, q), _)) == False{} : Bool}
  %Equal.sym(Bool, Bool.and(U32.is_eq(p, q), False{}), False{}, L.and_false_r(U32.is_eq(p, q))) : {Bool.and(AuthzSpec.member_of(AuthzSpec.Facts{who, blog, role, Some{AuthzSpec.PostInfo{p, pb, pub}}}, blog), _) == False{} : Bool}
  L.and_false_r(AuthzSpec.member_of(AuthzSpec.Facts{who, blog, role, Some{AuthzSpec.PostInfo{p, pb, pub}}}, blog))

def Laws.authz_no_cross_blog(k, who, blog, role, p, pb, pub, q, ne):
  match k:
    case 0n:
      cwp_cross(who, blog, role, p, pb, pub, q, ne)
    case 1n:
      cwp_cross(who, blog, role, p, pb, pub, q, ne)
    case 2n+r:
      cwp_cross(who, blog, role, p, pb, pub, q, ne)

# owner_of(f, b) is is_user && (blog == b && is_owner(role)); peel it.
def owner_role(+who: AuthzSpec.Principal, +blog: U32, +role: Maybe<&2, AuthzSpec.Role>, +post: Maybe<&2, AuthzSpec.PostInfo>, +b: U32, e: {AuthzSpec.owner_of(AuthzSpec.Facts{who, blog, role, post}, b) == True{} : Bool}) -> {AuthzSpec.is_owner(role) == True{} : Bool}:
  L.and_right(U32.is_eq(blog, b), AuthzSpec.is_owner(role), L.and_right(AuthzSpec.is_user(who), Bool.and(U32.is_eq(blog, b), AuthzSpec.is_owner(role)), e))

def Laws.authz_owner_manages(k, who, blog, role, post, b, u, e):
  match k:
    case 0n:
      owner_role(who, blog, role, post, b, e)
    case 1n:
      owner_role(who, blog, role, post, b, e)
    case 2n:
      owner_role(who, blog, role, post, b, L.and_left(AuthzSpec.owner_of(AuthzSpec.Facts{who, blog, role, post}, b), U32.is_ne(u, 0), e))
    case 3n+r:
      owner_role(who, blog, role, post, b, L.and_left(AuthzSpec.owner_of(AuthzSpec.Facts{who, blog, role, post}, b), U32.is_ne(u, AuthzSpec.user_id(who)), e))

def Laws.authz_no_self_remove(id, blog, role, post, b):
  %Equal.sym(Bool, U32.is_ne(id, id), False{}, L.u32_ne_refl(id)) : {Bool.and(AuthzSpec.owner_of(AuthzSpec.Facts{AuthzSpec.User{id}, blog, role, post}, b), _) == False{} : Bool}
  L.and_false_r(AuthzSpec.owner_of(AuthzSpec.Facts{AuthzSpec.User{id}, blog, role, post}, b))

def Laws.authz_drafts_private(who, blog, p, pb, q):
  %Equal.sym(Bool, Bool.and(U32.is_eq(p, q), False{}), False{}, L.and_false_r(U32.is_eq(p, q))) : {Bool.or(_, AuthzSpec.can_write_post(AuthzSpec.Facts{who, blog, None{}, Some{AuthzSpec.PostInfo{p, pb, False{}}}}, q)) == False{} : Bool}
  %Equal.sym(Bool, Bool.and(U32.is_eq(blog, blog), False{}), False{}, L.and_false_r(U32.is_eq(blog, blog))) : {Bool.and(Bool.and(AuthzSpec.is_user(who), _), AuthzSpec.post_is(AuthzSpec.Facts{who, blog, None{}, Some{AuthzSpec.PostInfo{p, pb, False{}}}}, q)) == False{} : Bool}
  %Equal.sym(Bool, Bool.and(AuthzSpec.is_user(who), False{}), False{}, L.and_false_r(AuthzSpec.is_user(who))) : {Bool.and(_, AuthzSpec.post_is(AuthzSpec.Facts{who, blog, None{}, Some{AuthzSpec.PostInfo{p, pb, False{}}}}, q)) == False{} : Bool}
  {==}

# member_of(f, b) is is_user && (blog == b && is_member(role)); peel it.
def member_role(+who: AuthzSpec.Principal, +blog: U32, +role: Maybe<&2, AuthzSpec.Role>, +post: Maybe<&2, AuthzSpec.PostInfo>, +b: U32, e: {AuthzSpec.member_of(AuthzSpec.Facts{who, blog, role, post}, b) == True{} : Bool}) -> {AuthzSpec.is_member(role) == True{} : Bool}:
  L.and_right(U32.is_eq(blog, b), AuthzSpec.is_member(role), L.and_right(AuthzSpec.is_user(who), Bool.and(U32.is_eq(blog, b), AuthzSpec.is_member(role)), e))

# can_write_post(f, q) starts with member_of(f, blog).
def cwp_member(+who: AuthzSpec.Principal, +blog: U32, +role: Maybe<&2, AuthzSpec.Role>, +post: Maybe<&2, AuthzSpec.PostInfo>, +q: U32, e: {AuthzSpec.can_write_post(AuthzSpec.Facts{who, blog, role, post}, q) == True{} : Bool}) -> {AuthzSpec.is_member(role) == True{} : Bool}:
  member_role(who, blog, role, post, blog, L.and_left(AuthzSpec.member_of(AuthzSpec.Facts{who, blog, role, post}, blog), AuthzSpec.post_is(AuthzSpec.Facts{who, blog, role, post}, q), e))

def Laws.authz_members_write(k, who, blog, role, post, b, q, e):
  match k:
    case 0n:
      member_role(who, blog, role, post, b, e)
    case 1n:
      cwp_member(who, blog, role, post, q, e)
    case 2n:
      cwp_member(who, blog, role, post, q, e)
    case 3n+r:
      cwp_member(who, blog, role, post, q, e)

# USER TEXT: each refinement carries its proof.

def Laws.text_title_ok(t):
  match t:
    case Text.Title{s, p}:
      p

def Laws.text_body_ok(t):
  match t:
    case Text.Body{s, p}:
      p

def Laws.text_slug_ok(t):
  match t:
    case Text.Slug{s, p}:
      p

# CSRF AND PLANNING

def csrf_some(+t: String, -path: Http.Path, e: {CsrfSpec.csrf_ok(Some{t}) == False{} : Bool}) -> {Route.plan_post(CsrfSpec.csrf_ok(Some{t}), path) == Route.Deny{403} : Route.Plan}:
  %Equal.sym(Bool, CsrfSpec.csrf_ok(Some{t}), False{}, e) : {Route.plan_post(_, path) == Route.Deny{403} : Route.Plan}
  {==}

def Laws.route_csrf(path, q, host, cookie, clen, ctype, origin, site, ds, e):
  match site:
    case None{}:
      {==}
    case Some{v}:
      match v:
        case Http.Hval{+t, p}:
          csrf_some(t, path, e)

# Every non-POST method plans a Read or a Deny, so the hypothesis is
# {False == True}; refute it.
def plan_absurd(z: Empty, -m: Http.Method) -> {m == Http.POST{} : Http.Method}:
  match z:

def Laws.route_only_post_writes(m, path, q, h, e):
  match m:
    case Http.GET{}:
      plan_absurd(L.false_ne_true(e), Http.GET{})
    case Http.HEAD{}:
      plan_absurd(L.false_ne_true(e), Http.HEAD{})
    case Http.POST{}:
      {==}
    case Http.PUT{}:
      plan_absurd(L.false_ne_true(e), Http.PUT{})
    case Http.PATCH{}:
      plan_absurd(L.false_ne_true(e), Http.PATCH{})
    case Http.DELETE{}:
      plan_absurd(L.false_ne_true(e), Http.DELETE{})

# PASSKEYS

def Laws.webauthn_reg_ok(r):
  match r:
    case WA.RegOk{e, c, a, cred, pf}:
      pf

def Laws.webauthn_login_ok(l):
  match l:
    case WA.LoginOk{e, c, a, sig, stored, pf}:
      pf

# login_ok(..., False, ...) = C && (A && (False && N)) = C && (A && False).
def Laws.webauthn_no_sig_no_login(e, c, a, stored):
  %Equal.sym(Bool, Bool.and(WSpec.auth_ok(e, a), False{}), False{}, L.and_false_r(WSpec.auth_ok(e, a))) : {Bool.and(WSpec.client_ok(e, c, "webauthn.get"), _) == False{} : Bool}
  L.and_false_r(WSpec.client_ok(e, c, "webauthn.get"))

# client_ok with cross = True is k == kind && (o == origin && False).
def cross_client(+origin: String, +rp: String, +k: String, +ch: String, +o: String, +kind: String) -> {WSpec.client_ok(WSpec.Expect{origin, rp}, WSpec.Client{k, ch, o, True{}}, kind) == False{} : Bool}:
  %Equal.sym(Bool, Bool.and(String.eq(o, origin), False{}), False{}, L.and_false_r(String.eq(o, origin))) : {Bool.and(String.eq(k, kind), _) == False{} : Bool}
  L.and_false_r(String.eq(k, kind))

def Laws.webauthn_no_cross_origin_login(origin, rp, k, ch, o, a, sig, stored):
  %Equal.sym(Bool, WSpec.client_ok(WSpec.Expect{origin, rp}, WSpec.Client{k, ch, o, True{}}, "webauthn.get"), False{}, cross_client(origin, rp, k, ch, o, "webauthn.get")) : {Bool.and(_, Bool.and(WSpec.auth_ok(WSpec.Expect{origin, rp}, a), Bool.and(sig, WSpec.counter_ok(stored, WSpec.auth_count(a))))) == False{} : Bool}
  {==}

def Laws.webauthn_no_cross_origin_reg(origin, rp, k, ch, o, a):
  %Equal.sym(Bool, WSpec.client_ok(WSpec.Expect{origin, rp}, WSpec.Client{k, ch, o, True{}}, "webauthn.create"), False{}, cross_client(origin, rp, k, ch, o, "webauthn.create")) : {Bool.and(_, Bool.and(WSpec.auth_ok(WSpec.Expect{origin, rp}, a), WSpec.at(WSpec.auth_flags(a)))) == False{} : Bool}
  {==}

# POST BODIES

def Laws.markup_rendered(r):
  match r:
    case Md.Rendered{n, h, pf}:
      pf

# COLLABORATIVE EDITING

def Laws.crdt_union_fast(xs, ys):
  CL.union_fast(xs, ys)

# Through union == union_spec, then the laws about merge.
def Laws.crdt_merge_comm(xs, ys):
  Equal.trans(List<&2, Crdt.Op>, Crdt.union(xs, ys), Crdt.union_spec(xs, ys), Crdt.union(ys, xs), CL.union_fast(xs, ys), Equal.trans(List<&2, Crdt.Op>, Crdt.union_spec(xs, ys), Crdt.union_spec(ys, xs), Crdt.union(ys, xs), CL.merge_comm(xs, ys, Crdt.cmp(Crdt.hd(xs), Crdt.hd(ys)), {==}), Equal.sym(List<&2, Crdt.Op>, Crdt.union(ys, xs), Crdt.union_spec(ys, xs), CL.union_fast(ys, xs))))

def Laws.crdt_merge_idem(xs):
  Equal.trans(List<&2, Crdt.Op>, Crdt.union(xs, xs), Crdt.union_spec(xs, xs), xs, CL.union_fast(xs, xs), CL.merge_idem(xs))
