# The database, as Bend sees it (effects in src/effects/db.c).
#
# Writes go only through `apply`, which takes a Permit: the only way to
# write is to hold a proof that the policy allowed it. apply_raw must never
# be called from anywhere else (tools/lint.sh checks this). The C side
# re-checks the Permit's facts against the database before writing.
import Base
import ../spec/authz.bend as Spec
import ./authz.bend as Authz
import ./text.bend as Text

# EFFECTS
# -------

# The data a write carries besides its action.
type WData is Data:
  WData{slug: String, title: String, body_md: String, body_html: String}
# [kind, target, user, flag] for an action (flag: 1 publish; 0 otherwise).
type Act is Data:
  Act{kind: U32, target: U32, user: U32, flag: U32}
def db_open(path: String) -> IO(Result<&1, &1, U32 & String, Unit>):
  import "./effects/db.c"
# The user id of a session token (from the sid cookie), or 0.
def session_user(token: String) -> IO(U32):
  import "./effects/db.c"
# A new session for a user; answers its token (64 hex characters).
def session_new(user: U32) -> IO(Result<&1, &1, U32 & String, String>):
  import "./effects/db.c"
# [who, blog, role, has_post, post, post_blog, post_pub]
def load_facts(who: U32, blog: U32, post: U32) -> IO(List<&2, U32>):
  import "./effects/db.c"
def apply_raw(token: String, who: U32, blog: U32, role: U32, has_post: U32, post: U32, post_blog: U32, post_pub: U32, kind: U32, target: U32, user: U32, flag: U32, slug: String, title: String, body_md: String, body_html: String) -> IO(Result<&1, &1, U32 & String, U32>):
  import "./effects/db.c"
# Rows of a fixed read query (see Q_* in src/c/db_core.h).
def query(q: U32, a: U32, b: U32, text: String, token: String) -> IO(List<&2, List<&2, String>>):
  import "./effects/db.c"
# Sends texts[0] body[0] texts[1] ... texts[n]. Each body is a post id whose
# stored HTML C splices in only if published or the session is a member.
def page(sock: Socket, status: U32, ctype: U32, texts: List<&2, String>, bodies: List<&2, U32>, token: String, cookie: String, location: String) -> IO(Socket & Result<&1, &1, U32 & String, Unit>):
  import "./effects/db.c"
# QUERY IDS (src/c/db_core.h)
# ---------
def q_blog_by_slug() -> U32:
  0
def q_post_id() -> U32:
  1
def q_posts_public() -> U32:
  2
def q_recent_public() -> U32:
  3
def q_post_view() -> U32:
  4
def q_my_blogs() -> U32:
  5
def q_posts_member() -> U32:
  6
def q_post_md() -> U32:
  7
def q_user_by_email() -> U32:
  8
def q_authors() -> U32:
  9
def principal.go(anon: Bool, +who: U32) -> Spec.Principal:
  match anon:
    case True{}:
      Spec.Anon{}
    case False{}:
      Spec.User{who}
# FACTS
# -----
def principal(+who: U32) -> Spec.Principal:
  principal.go(U32.is_eq(who, 0), who)
def role_pick(k: Nat) -> Maybe<&2, Spec.Role>:
  match k:
    case 1n:
      Some{Spec.Owner{}}
    case 2n:
      Some{Spec.Author{}}
    case _:
      None{}
def role_of(+r: U32) -> Maybe<&2, Spec.Role>:
  role_pick(U32.to_nat(r))
def post_of.go(b: Bool, +id: U32, +pb: U32, +pub: U32) -> Maybe<&2, Spec.PostInfo>:
  match b:
    case True{}:
      Some{Spec.PostInfo{id, pb, U32.is_eq(pub, 1)}}
    case False{}:
      None{}
def post_of(+has: U32, +id: U32, +pb: U32, +pub: U32) -> Maybe<&2, Spec.PostInfo>:
  post_of.go(U32.is_eq(has, 1), id, pb, pub)
def nth(xs: List<&2, U32>, n: Nat) -> U32:
  match xs:
    case Nil{}:
      0
    case Con{x, t}:
      match n:
        case 0n:
          x
        case 1n+p:
          nth(t, p)
# Decodes load_facts' answer. Anything malformed decodes to facts that the
# policy denies everything but public reads on (and C re-checks writes).
def facts_of(+xs: List<&2, U32>) -> Spec.Facts:
  Spec.Facts{principal(nth(xs, 0n)), nth(xs, 1n), role_of(nth(xs, 2n)), post_of(nth(xs, 3n), nth(xs, 4n), nth(xs, 5n), nth(xs, 6n))}
# The facts, loaded.
def facts(who: U32, blog: U32, post: U32) -> IO(Spec.Facts):
  do IO<Spec.Facts>:
    xs : List<&2, U32> <- load_facts(who, blog, post)
    return facts_of(xs)
# WRITES
# ------
def role_code(r: Maybe<&2, Spec.Role>) -> U32:
  match r:
    case None{}:
      0
    case Some{x}:
      match x:
        case Spec.Owner{}:
          1
        case Spec.Author{}:
          2
def who_code(p: Spec.Principal) -> U32:
  match p:
    case Spec.Anon{}:
      0
    case Spec.User{id}:
      id
def no_data() -> WData:
  WData{"", "", "", ""}
def blog_data(s: Text.Slug, t: Text.Title) -> WData:
  WData{Text.Slug.text(s), Text.Title.text(t), "", ""}
def title_data(t: Text.Title) -> WData:
  WData{"", Text.Title.text(t), "", ""}
def post_data(t: Text.Title, b: Text.Body, html: String) -> WData:
  WData{"", Text.Title.text(t), Text.Body.text(b), html}
def act_of(a: Spec.Action, +flag: U32) -> Act:
  match a:
    case Spec.CreateBlog{}:
      Act{0, 0, 0, 0}
    case Spec.EditBlog{b}:
      Act{1, b, 0, 0}
    case Spec.DeleteBlog{b}:
      Act{2, b, 0, 0}
    case Spec.AddAuthor{b, u}:
      Act{3, b, u, 0}
    case Spec.RemoveAuthor{b, u}:
      Act{4, b, u, 0}
    case Spec.CreatePost{b}:
      Act{5, b, 0, 0}
    case Spec.EditPost{p}:
      Act{6, p, 0, 0}
    case Spec.PublishPost{p}:
      Act{7, p, 0, flag}
    case Spec.DeletePost{p}:
      Act{8, p, 0, 0}
    case Spec.ReadPost{p}:
      Act{99, p, 0, 0}
    case Spec.ReadBlogAdmin{b}:
      Act{99, b, 0, 0}
def apply_post(+token: String, +who: U32, +blog: U32, +role: U32, post: Maybe<&2, Spec.PostInfo>, +kind: U32, +target: U32, +user: U32, +flag: U32, slug: String, title: String, md: String, html: String) -> IO(Result<&1, &1, U32 & String, U32>):
  match post:
    case None{}:
      apply_raw(token, who, blog, role, 0, 0, 0, 0, kind, target, user, flag, slug, title, md, html)
    case Some{x}:
      match x:
        case Spec.PostInfo{id, pb, pub}:
          apply_raw(token, who, blog, role, 1, id, pb, Bool.to_u32(pub), kind, target, user, flag, slug, title, md, html)
def apply_go(+token: String, f: Spec.Facts, a: Act, d: WData) -> IO(Result<&1, &1, U32 & String, U32>):
  match f:
    case Spec.Facts{who, blog, role, post}:
      match a:
        case Act{kind, target, user, flag}:
          match d:
            case WData{slug, title, md, html}:
              apply_post(token, who_code(who), blog, role_code(role), post, kind, target, user, flag, slug, title, md, html)
# Performs the write a Permit allows. flag: 1 to publish, 0 to unpublish
# (only read for PublishPost). Answers the new id, or fails with a code:
# 1 stale facts, 2 denied, 3 conflict, 4 error.
def apply(+token: String, p: Authz.Permit, +flag: U32, d: WData) -> IO(Result<&1, &1, U32 & String, U32>):
  match p:
    case Authz.Permit{f, a, pf}:
      apply_go(token, f, act_of(a, flag), d)
