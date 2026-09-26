# Request handlers: the IO layer between a Plan and the database.
#
# Pattern for everything private: load facts, `authorize`, and only with a
# Permit read or write. A denied read answers 404 (not 403), so drafts and
# admin pages do not reveal that they exist. Writes happen only via
# Db.apply, which takes the Permit.
import Base
import ../spec/authz.bend as Spec
import ./authz.bend as Authz
import ./db.bend as Db
import ./pages.bend as Pages
import ./route.bend as Route
import ./text.bend as Text
import ./auth.bend as Auth
import ./crdt.bend as Crdt
import ./bytes.bend as B

# RESPONSES
# ---------

def done(r: Socket & Result<&1, &1, U32 & String, Unit>) -> IO(Unit):
  (s, x) = r
  Socket.close(s)

def one(+x: String) -> List<&2, String>:
  Con{x, Nil{}}

def two(+x: String, +y: String) -> List<&2, String>:
  Con{x, Con{y, Nil{}}}

def send(s: Socket, +token: String, +status: U32, +html: String) -> IO(Unit):
  do IO<Unit>:
    r : Socket & Result<&1, &1, U32 & String, Unit> <- Db.page(s, status, 0, one(html), Nil{}, token, "", "")
    done(r)

def send_text(s: Socket, +token: String, +status: U32, +text: String) -> IO(Unit):
  do IO<Unit>:
    r : Socket & Result<&1, &1, U32 & String, Unit> <- Db.page(s, status, 1, one(text), Nil{}, token, "", "")
    done(r)

def redirect(s: Socket, +token: String, +path: String, +cookie: String) -> IO(Unit):
  do IO<Unit>:
    r : Socket & Result<&1, &1, U32 & String, Unit> <- Db.page(s, 303, 0, one(""), Nil{}, token, cookie, path)
    done(r)

def signed(+who: U32) -> Bool:
  U32.is_ne(who, 0)

def fail(s: Socket, +token: String, +who: U32, +status: U32) -> IO(Unit):
  send(s, token, status, Pages.layout("Error", signed(who), Pages.error_body(status)))

def apply_status.go(k: Nat) -> U32:
  match k:
    case 1n:
      409
    case 2n:
      403
    case 3n:
      409
    case _:
      500

# An apply failure code: 1 stale facts / 3 conflict -> 409, 2 denied -> 403.
def apply_status(+code: U32) -> U32:
  apply_status.go(U32.to_nat(code))

# ROWS
# ----
def num(+s: String) -> U32:
  Maybe.default(&2, U32, U32.read(s), 0)

def first_col(+rows: List<&2, List<&2, String>>, n: Nat) -> String:
  match rows:
    case Nil{}:
      ""
    case Con{r, t}:
      Pages.col(r, n)

# The blog with this slug: [id, title, slug], or no rows.
def blog_rows(+token: String, +slug: String) -> IO(List<&2, List<&2, String>>):
  Db.query(Db.q_blog_by_slug(), 0, 0, slug, token)

# READS
# -----
# Public feeds are cached (see Db.cached): the key holds everything the
# page depends on, which is the path and whether someone is signed in.
def cache_key(+kind: String, +who: U32, +rest: String) -> String:
  kind ++ (U32.show(Bool.to_u32(signed(who))) ++ (":" ++ rest))

def cache_send_t(s: Socket, +key: String, +ctype: U32, +text: String) -> IO(Unit):
  do IO<Unit>:
    r : Socket & Result<&1, &1, U32 & String, Unit> <- Db.page_cache_put(s, key, ctype, one(text))
    done(r)

def cache_send(s: Socket, +key: String, +html: String) -> IO(Unit):
  cache_send_t(s, key, 0, html)

# Serves the cached response for key, or runs render (which should store
# one with cache_send).
def cached_or(r: Socket & Result<&1, &1, U32 & String, Unit>, render: Socket -> IO(Unit)) -> IO(Unit):
  (s, x) = r
  match x:
    case Done{u}:
      Socket.close(s)
    case Fail{err}:
      render(s)

# SEARCH: /search?q=... (not cached: queries vary). An empty or wordless
# query shows the box only.
def h_search2(empty: Bool, s: Socket, +token: String, +who: U32, +q: String, +fq: String) -> IO(Unit):
  match empty:
    case True{}:
      send(s, token, 200, Pages.layout("Search", signed(who), Pages.search_page(q, Nil{})))
    case False{}:
      do IO<Unit>:
        rows : List<&2, List<&2, String>> <- Db.query(Db.q_search(), 0, 0, fq, token)
        send(s, token, 200, Pages.layout("Search: " ++ q, signed(who), Pages.search_page(q, rows)))

def h_search.go(s: Socket, +token: String, +who: U32, +q: String) -> IO(Unit):
  +fq = Text.fts_query(q)
  h_search2(String.is_empty(fq), s, token, who, q, fq)

def form(+body: String) -> List<&2, Text.Field>:
  Maybe.default(&2, List<&2, Text.Field>, Text.form_parse(body), Nil{})

def h_search(s: Socket, +token: String, +who: U32, +query: String) -> IO(Unit):
  h_search.go(s, token, who, String.take(Maybe.default(&2, String, Text.decode_of(Text.form_get(form(query), "q")), ""), 200n))

# RSS: the site's recent posts, and a blog's posts (content type 6).
def h_feed2(s: Socket, +token: String, +origin: String) -> IO(Unit):
  do IO<Unit>:
    rows : List<&2, List<&2, String>> <- Db.query(Db.q_recent_public(), 0, 0, "", token)
    cache_send_t(s, "rss:", 6, Pages.rss(origin, "slopstack", "/", "Recent posts on slopstack", Pages.rss_recent(origin, rows)))

def h_feed(s: Socket, +token: String, +origin: String) -> IO(Unit):
  do IO<Unit>:
    r : Socket & Result<&1, &1, U32 & String, Unit> <- Db.cached(s, "rss:")
    cached_or(r, s2 => h_feed2(s2, token, origin))

def h_blog_feed3(s: Socket, +token: String, +origin: String, +slug: String, +blog: List<&2, List<&2, String>>) -> IO(Unit):
  match blog:
    case Nil{}:
      fail(s, token, 0, 404)
    case Con{+r, t}:
      do IO<Unit>:
        rows : List<&2, List<&2, String>> <- Db.query(Db.q_posts_public(), num(Pages.col(r, 0n)), 0, "", token)
        cache_send_t(s, "rss:" ++ slug, 6, Pages.rss(origin, Pages.col(r, 1n), "/b/" ++ slug, Pages.col(r, 1n) ++ (" by " ++ Pages.col(r, 3n)), Pages.rss_blog(origin, slug, rows)))

def h_blog_feed2(s: Socket, +token: String, +origin: String, +slug: String) -> IO(Unit):
  do IO<Unit>:
    blog : List<&2, List<&2, String>> <- blog_rows(token, slug)
    h_blog_feed3(s, token, origin, slug, blog)

def h_blog_feed(s: Socket, +token: String, +origin: String, +slug: String) -> IO(Unit):
  do IO<Unit>:
    r : Socket & Result<&1, &1, U32 & String, Unit> <- Db.cached(s, "rss:" ++ slug)
    cached_or(r, s2 => h_blog_feed2(s2, token, origin, slug))

def h_home2(s: Socket, +token: String, +who: U32) -> IO(Unit):
  do IO<Unit>:
    rows : List<&2, List<&2, String>> <- Db.query(Db.q_recent_public(), 0, 0, "", token)
    cache_send(s, cache_key("h", who, ""), Pages.layout("Home", signed(who), Pages.home_page(rows, signed(who))))

def h_home.go(r: Socket & Result<&1, &1, U32 & String, Unit>, +token: String, +who: U32) -> IO(Unit):
  (s, x) = r
  match x:
    case Done{u}:
      Socket.close(s)
    case Fail{err}:
      h_home2(s, token, who)

def h_home(s: Socket, +token: String, +who: U32) -> IO(Unit):
  do IO<Unit>:
    r : Socket & Result<&1, &1, U32 & String, Unit> <- Db.cached(s, cache_key("h", who, ""))
    h_home.go(r, token, who)

def h_blog2(s: Socket, +token: String, +who: U32, +blog: List<&2, List<&2, String>>) -> IO(Unit):
  match blog:
    case Nil{}:
      fail(s, token, who, 404)
    case Con{+r, t}:
      do IO<Unit>:
        rows : List<&2, List<&2, String>> <- Db.query(Db.q_posts_public(), num(Pages.col(r, 0n)), 0, "", token)
        cache_send(s, cache_key("b", who, Pages.col(r, 2n)), Pages.layout(Pages.col(r, 1n), signed(who), Pages.blog_page(Pages.col(r, 2n), Pages.col(r, 1n), Pages.col(r, 3n), rows)))

def h_blog3(s: Socket, +token: String, +who: U32, +slug: String) -> IO(Unit):
  do IO<Unit>:
    blog : List<&2, List<&2, String>> <- blog_rows(token, slug)
    h_blog2(s, token, who, blog)

def h_blog.go(r: Socket & Result<&1, &1, U32 & String, Unit>, +token: String, +who: U32, +slug: String) -> IO(Unit):
  (s, x) = r
  match x:
    case Done{u}:
      Socket.close(s)
    case Fail{err}:
      h_blog3(s, token, who, slug)

def h_blog(s: Socket, +token: String, +who: U32, +slug: String) -> IO(Unit):
  do IO<Unit>:
    r : Socket & Result<&1, &1, U32 & String, Unit> <- Db.cached(s, cache_key("b", who, slug))
    h_blog.go(r, token, who, slug)

def is_some_permit(m: Maybe<&2, Authz.Permit>) -> Bool:
  match m:
    case None{}:
      False{}
    case Some{p}:
      True{}

def first_row(+rows: List<&2, List<&2, String>>) -> List<&2, String>:
  match rows:
    case Nil{}:
      Nil{}
    case Con{r, t}:
      r

def h_post5(s: Socket, +token: String, +pg: Pages.Page) -> IO(Unit):
  do IO<Unit>:
    x : Socket & Result<&1, &1, U32 & String, Unit> <- Db.page(s, 200, 0, Pages.page_texts(pg), Pages.page_bodies(pg), token, "", "")
    done(x)

# The post page: the stored body is spliced in by C (with its own floor).
# Members see an Edit link (only if they could open the editor).
def h_post4(s: Socket, +token: String, +who: U32, +pid: U32, +can_edit: Bool, +notice: Bool, +view: List<&2, List<&2, String>>) -> IO(Unit):
  match view:
    case Nil{}:
      fail(s, token, who, 404)
    case Con{+r, t}:
      do IO<Unit>:
        +social : List<&2, List<&2, String>> <- Db.query(Db.q_post_social(), pid, 0, "", token)
        tags : List<&2, List<&2, String>> <- Db.query(Db.q_post_tags(), pid, 0, "", token)
        comments : List<&2, List<&2, String>> <- Db.query(Db.q_comments(), pid, 0, "", token)
        h_post5(s, token, Pages.page_of(Con{Pages.T{Pages.layout_top(Pages.col(r, 1n), signed(who)) ++ Pages.post_before(r, U32.show(pid), can_edit, Bool.and(can_edit, notice))}, Con{Pages.B{pid}, Con{Pages.T{Pages.post_after(r, Pages.tag_chips(tags) ++ Pages.social_bar(signed(who), U32.show(pid), first_row(social)))}, List.append(&2, Pages.Seg, Pages.comments_section(signed(who), can_edit, U32.show(pid), first_col(social, 2n), comments), Con{Pages.T{Pages.layout_bottom()}, Nil{}})}}}, ""))

def h_post3(s: Socket, +token: String, +who: U32, +pid: U32, +can_edit: Bool, +notice: Bool, m: Maybe<&2, Authz.Permit>) -> IO(Unit):
  match m:
    case None{}:
      fail(s, token, who, 404)
    case Some{p}:
      do IO<Unit>:
        view : List<&2, List<&2, String>> <- Db.query(Db.q_post_view(), pid, 0, "", token)
        h_post4(s, token, who, pid, can_edit, notice, view)

def h_post2(s: Socket, +token: String, +who: U32, +pid: U32, +notice: Bool) -> IO(Unit):
  do IO<Unit>:
    +f : Spec.Facts <- Db.facts(who, 0, pid)
    h_post3(s, token, who, pid, is_some_permit(Authz.authorize(f, Spec.EditPost{pid})), notice, Authz.authorize(f, Spec.ReadPost{pid}))

# TAG PAGES (cached): /t/<tag>.
def h_tag2(s: Socket, +token: String, +who: U32, +tag: String) -> IO(Unit):
  do IO<Unit>:
    rows : List<&2, List<&2, String>> <- Db.query(Db.q_posts_by_tag(), 0, 0, tag, token)
    cache_send(s, cache_key("t", who, tag), Pages.layout("#" ++ tag, signed(who), Pages.tag_page(tag, rows)))

def h_tag(s: Socket, +token: String, +who: U32, +tag: String) -> IO(Unit):
  do IO<Unit>:
    r : Socket & Result<&1, &1, U32 & String, Unit> <- Db.cached(s, cache_key("t", who, tag))
    cached_or(r, s2 => h_tag2(s2, token, who, tag))

# LIKES AND COMMENTS
# ------------------
# Each ends on the post's page (at an anchor); the post's address comes
# from the database.
def to_post2(s: Socket, +token: String, +anchor: String, +view: List<&2, List<&2, String>>) -> IO(Unit):
  match view:
    case Nil{}:
      redirect(s, token, "/", "")
    case Con{+r, t}:
      redirect(s, token, "/b/" ++ (Pages.col(r, 3n) ++ ("/" ++ (Pages.col(r, 0n) ++ anchor))), "")

def to_post(s: Socket, +token: String, +pid: U32, +anchor: String) -> IO(Unit):
  do IO<Unit>:
    view : List<&2, List<&2, String>> <- Db.query(Db.q_post_view(), pid, 0, "", token)
    to_post2(s, token, anchor, view)

def engage_done(s: Socket, +token: String, +who: U32, +pid: U32, +anchor: String, r: Result<&1, &1, U32 & String, U32>) -> IO(Unit):
  match r:
    case Done{id}:
      to_post(s, token, pid, anchor)
    case Fail{err}:
      (code, msg) = err
      fail(s, token, who, apply_status(code))

def h_like2(s: Socket, +token: String, +who: U32, +pid: U32, +on: U32, m: Maybe<&2, Authz.Permit>) -> IO(Unit):
  match m:
    case None{}:
      fail(s, token, who, 403)
    case Some{p}:
      do IO<Unit>:
        r : Result<&1, &1, U32 & String, U32> <- Db.apply(token, p, on, Db.no_data())
        engage_done(s, token, who, pid, "#social", r)

def h_like.go(signed: Bool, s: Socket, +token: String, +who: U32, +pid: U32, +on: U32) -> IO(Unit):
  match signed:
    case False{}:
      redirect(s, token, "/login", "")
    case True{}:
      do IO<Unit>:
        f : Spec.Facts <- Db.facts(who, 0, pid)
        h_like2(s, token, who, pid, on, Authz.authorize(f, Spec.LikePost{pid}))

# POST /like/<post>: on=1 likes, on=0 unlikes.
def h_like(s: Socket, +token: String, +who: U32, +pid: U32, +body: String) -> IO(Unit):
  h_like.go(signed(who), s, token, who, pid, Bool.to_u32(String.eq(Maybe.default(&2, String, Text.form_raw(form(body), "on"), ""), "1")))

def comment_fail(slow: Bool, s: Socket, +token: String, +who: U32, +code: U32) -> IO(Unit):
  match slow:
    case True{}:
      fail(s, token, who, 429)
    case False{}:
      fail(s, token, who, apply_status(code))

# A new comment ends at its own anchor; too many too fast is 429.
def comment_done(s: Socket, +token: String, +who: U32, +pid: U32, r: Result<&1, &1, U32 & String, U32>) -> IO(Unit):
  match r:
    case Done{+id}:
      to_post(s, token, pid, "#c" ++ U32.show(id))
    case Fail{err}:
      (+code, msg) = err
      comment_fail(U32.is_eq(code, 3), s, token, who, code)

def h_comment3(s: Socket, +token: String, +who: U32, +pid: U32, +parent: U32, +b: Text.Body, m: Maybe<&2, Authz.Permit>) -> IO(Unit):
  match m:
    case None{}:
      fail(s, token, who, 403)
    case Some{p}:
      do IO<Unit>:
        r : Result<&1, &1, U32 & String, U32> <- Db.apply(token, p, parent, Db.comment_data(b))
        comment_done(s, token, who, pid, r)

def h_comment2(s: Socket, +token: String, +who: U32, +pid: U32, +parent: U32, m: Maybe<&2, Text.Body>) -> IO(Unit):
  match m:
    case None{}:
      fail(s, token, who, 400)
    case Some{+b}:
      do IO<Unit>:
        f : Spec.Facts <- Db.facts(who, 0, pid)
        h_comment3(s, token, who, pid, parent, b, Authz.authorize(f, Spec.CommentPost{pid}))

# COLLABORATIVE EDITING
# ---------------------
def form_num(+xs: List<&2, Text.Field>, +key: String) -> U32:
  Maybe.default(&2, U32, U32.read(Maybe.default(&2, String, Text.form_raw(xs, key), "")), 0)

def h_comment.go(signed: Bool, s: Socket, +token: String, +who: U32, +pid: U32, +xs: List<&2, Text.Field>) -> IO(Unit):
  match signed:
    case False{}:
      redirect(s, token, "/login", "")
    case True{}:
      h_comment2(s, token, who, pid, form_num(xs, "parent"), Text.form_comment(xs, "body"))

# POST /comment/<post>: body, and parent (a comment id) for a reply.
def h_comment(s: Socket, +token: String, +who: U32, +pid: U32, +body: String) -> IO(Unit):
  h_comment.go(signed(who), s, token, who, pid, form(body))

def h_delete_comment3(s: Socket, +token: String, +who: U32, +pid: U32, m: Maybe<&2, Authz.Permit>) -> IO(Unit):
  match m:
    case None{}:
      fail(s, token, who, 403)
    case Some{p}:
      do IO<Unit>:
        r : Result<&1, &1, U32 & String, U32> <- Db.apply(token, p, 0, Db.no_data())
        engage_done(s, token, who, pid, "#comments", r)

def h_delete_comment2(s: Socket, +token: String, +who: U32, +cid: U32, +info: List<&2, List<&2, String>>) -> IO(Unit):
  match info:
    case Nil{}:
      fail(s, token, who, 404)
    case Con{+r, t}:
      do IO<Unit>:
        f : Spec.Facts <- Db.facts(who, 0, num(Pages.col(r, 0n)))
        h_delete_comment3(s, token, who, num(Pages.col(r, 0n)), Authz.authorize(f, Spec.DeleteComment{num(Pages.col(r, 0n)), cid, num(Pages.col(r, 1n))}))

# POST /comment/<id>/delete: by its author, or a member of the blog. The
# author is as loaded here; the write only matches a comment by them.
def h_delete_comment(s: Socket, +token: String, +who: U32, +cid: U32) -> IO(Unit):
  do IO<Unit>:
    info : List<&2, List<&2, String>> <- Db.query(Db.q_comment_info(), cid, 0, "", token)
    h_delete_comment2(s, token, who, cid, info)

def h_reply3(s: Socket, +token: String, +who: U32, +cid: U32, +info: List<&2, String>, +view: List<&2, List<&2, String>>) -> IO(Unit):
  do IO<Unit>:
    x : Socket & Result<&1, &1, U32 & String, Unit> <- Db.page(s, 200, 0, two(Pages.layout_top("Reply", True{}) ++ Pages.reply_before(info, "/b/" ++ (first_col(view, 3n) ++ ("/" ++ (first_col(view, 0n) ++ ("#c" ++ U32.show(cid)))))), Pages.reply_after(info, U32.show(cid), "/b/" ++ (first_col(view, 3n) ++ ("/" ++ (first_col(view, 0n) ++ ("#c" ++ U32.show(cid)))))) ++ Pages.layout_bottom()), Con{Db.comment_body(cid), Nil{}}, token, "", "")
    done(x)

def h_reply2(s: Socket, +token: String, +who: U32, +cid: U32, +info: List<&2, List<&2, String>>) -> IO(Unit):
  match info:
    case Nil{}:
      fail(s, token, who, 404)
    case Con{+r, t}:
      do IO<Unit>:
        view : List<&2, List<&2, String>> <- Db.query(Db.q_post_view(), num(Pages.col(r, 0n)), 0, "", token)
        h_reply3(s, token, who, cid, r, view)

def h_reply.go(signed: Bool, s: Socket, +token: String, +who: U32, +cid: U32) -> IO(Unit):
  match signed:
    case False{}:
      redirect(s, token, "/login", "")
    case True{}:
      do IO<Unit>:
        info : List<&2, List<&2, String>> <- Db.query(Db.q_comment_info(), cid, 0, "", token)
        h_reply2(s, token, who, cid, info)

# GET /reply/<comment>: the comment, and a form to answer it.
def h_reply(s: Socket, +token: String, +who: U32, +cid: U32) -> IO(Unit):
  h_reply.go(signed(who), s, token, who, cid)

# ?published=1: the editor just published it (a notice, for members only).
def just_published(+query: String) -> Bool:
  String.eq(Maybe.default(&2, String, Text.form_raw(form(query), "published"), ""), "1")

def h_post(s: Socket, +token: String, +who: U32, +bslug: String, +pslug: String, +query: String) -> IO(Unit):
  do IO<Unit>:
    blog : List<&2, List<&2, String>> <- blog_rows(token, bslug)
    ids : List<&2, List<&2, String>> <- Db.query(Db.q_post_id(), num(first_col(blog, 0n)), 0, pslug, token)
    h_post2(s, token, who, num(first_col(ids, 0n)), just_published(query))

def h_dash2(b: Bool, s: Socket, +token: String, +who: U32) -> IO(Unit):
  match b:
    case True{}:
      do IO<Unit>:
        rows : List<&2, List<&2, String>> <- Db.query(Db.q_my_blogs(), 0, 0, "", token)
        send(s, token, 200, Pages.layout_wide("Your blogs", True{}, Pages.dash_page(rows)))
    case False{}:
      redirect(s, token, "/login", "")

def h_dash(s: Socket, +token: String, +who: U32) -> IO(Unit):
  h_dash2(signed(who), s, token, who)

def facts_role(f: Spec.Facts) -> Maybe<&2, Spec.Role>:
  match f:
    case Spec.Facts{who, blog, role, post}:
      role

def h_dash_blog3(s: Socket, +token: String, +who: U32, +blog: U32, +slug: String, +title: String, +f: Spec.Facts, m: Maybe<&2, Authz.Permit>) -> IO(Unit):
  match m:
    case None{}:
      fail(s, token, who, 404)
    case Some{p}:
      do IO<Unit>:
        posts : List<&2, List<&2, String>> <- Db.query(Db.q_posts_member(), blog, 0, "", token)
        authors : List<&2, List<&2, String>> <- Db.query(Db.q_authors(), blog, 0, "", token)
        send(s, token, 200, Pages.layout_wide(title, True{}, Pages.dash_blog(slug, title, Spec.is_owner(facts_role(f)), posts, authors)))

def h_dash_blog2.go(s: Socket, +token: String, +who: U32, +slug: String, +id: U32, +title: String) -> IO(Unit):
  do IO<Unit>:
    +f : Spec.Facts <- Db.facts(who, id, 0)
    h_dash_blog3(s, token, who, id, slug, title, f, Authz.authorize(f, Spec.ReadBlogAdmin{id}))

def h_dash_blog2(s: Socket, +token: String, +who: U32, +slug: String, +blog: List<&2, List<&2, String>>) -> IO(Unit):
  +id = num(first_col(blog, 0n))
  h_dash_blog2.go(s, token, who, slug, id, first_col(blog, 1n))

def h_dash_blog(s: Socket, +token: String, +who: U32, +slug: String) -> IO(Unit):
  do IO<Unit>:
    blog : List<&2, List<&2, String>> <- blog_rows(token, slug)
    h_dash_blog2(s, token, who, slug, blog)

# A replica id for this editor: random, >= 2 (1 is the seed replica).
def rep_of(+rh: String) -> U32:
  ((B.be32(Maybe.default(&2, String, B.unhex(rh), "")) % 268435456) + 2 : U32)

def h_edit3(s: Socket, +token: String, +who: U32, +pid: U32, +rows: List<&2, List<&2, String>>) -> IO(Unit):
  match rows:
    case Nil{}:
      fail(s, token, who, 404)
    case Con{+r, t}:
      do IO<Unit>:
        +rh : String <- Auth.random_hex(4)
        tags : List<&2, List<&2, String>> <- Db.query(Db.q_post_tags(), pid, 0, "", token)
        send(s, token, 200, Pages.edit_page(U32.show(pid), U32.show(rep_of(rh)), r, Pages.tag_list(tags)))

def h_edit2(s: Socket, +token: String, +who: U32, +pid: U32, m: Maybe<&2, Authz.Permit>) -> IO(Unit):
  match m:
    case None{}:
      fail(s, token, who, 404)
    case Some{p}:
      do IO<Unit>:
        rows : List<&2, List<&2, String>> <- Db.query(Db.q_post_md(), pid, 0, "", token)
        h_edit3(s, token, who, pid, rows)

def h_edit(s: Socket, +token: String, +who: U32, +pid: U32) -> IO(Unit):
  do IO<Unit>:
    f : Spec.Facts <- Db.facts(who, 0, pid)
    h_edit2(s, token, who, pid, Authz.authorize(f, Spec.EditPost{pid}))

# WRITES
# ------
# Runs a write the Permit allows, then redirects to `next` (or fails).
def write_done(s: Socket, +token: String, +who: U32, +next: String, r: Result<&1, &1, U32 & String, U32>) -> IO(Unit):
  match r:
    case Done{id}:
      redirect(s, token, next, "")
    case Fail{err}:
      (code, msg) = err
      fail(s, token, who, apply_status(code))

def write(s: Socket, +token: String, +who: U32, m: Maybe<&2, Authz.Permit>, +flag: U32, d: Db.WData, +next: String) -> IO(Unit):
  match m:
    case None{}:
      fail(s, token, who, 403)
    case Some{p}:
      do IO<Unit>:
        r : Result<&1, &1, U32 & String, U32> <- Db.apply(token, p, flag, d)
        write_done(s, token, who, next, r)

# Like write, but redirects to a path built from the new id.
def write_new_done(s: Socket, +token: String, +who: U32, +prefix: String, r: Result<&1, &1, U32 & String, U32>) -> IO(Unit):
  match r:
    case Done{+id}:
      redirect(s, token, prefix ++ U32.show(id), "")
    case Fail{err}:
      (code, msg) = err
      fail(s, token, who, apply_status(code))

def write_new(s: Socket, +token: String, +who: U32, m: Maybe<&2, Authz.Permit>, d: Db.WData, +prefix: String) -> IO(Unit):
  match m:
    case None{}:
      fail(s, token, who, 403)
    case Some{p}:
      do IO<Unit>:
        r : Result<&1, &1, U32 & String, U32> <- Db.apply(token, p, 0, d)
        write_new_done(s, token, who, prefix, r)

def h_create_blog2(s: Socket, +token: String, +who: U32, slug: Maybe<&2, Text.Slug>, title: Maybe<&2, Text.Title>) -> IO(Unit):
  match slug title:
    case Some{+sl} Some{ti}:
      do IO<Unit>:
        f : Spec.Facts <- Db.facts(who, 0, 0)
        write(s, token, who, Authz.authorize(f, Spec.CreateBlog{}), 0, Db.blog_data(sl, ti), "/dash/" ++ Text.Slug.text(sl))
    case _ _:
      fail(s, token, who, 400)

def h_create_blog(s: Socket, +token: String, +who: U32, +body: String) -> IO(Unit):
  +xs = form(body)
  h_create_blog2(s, token, who, Text.form_slug_or(xs, "slug", "title"), Text.form_title(xs, "title"))

def h_create_post2(s: Socket, +token: String, +who: U32, +blog: U32, slug: Maybe<&2, Text.Slug>, title: Maybe<&2, Text.Title>) -> IO(Unit):
  match slug title:
    case Some{sl} Some{ti}:
      do IO<Unit>:
        f : Spec.Facts <- Db.facts(who, blog, 0)
        write_new(s, token, who, Authz.authorize(f, Spec.CreatePost{blog}), Db.blog_data(sl, ti), "/edit/")
    case _ _:
      fail(s, token, who, 400)

# A new untitled draft with a placeholder address (draft-<random>), opened
# in the editor. Its real address comes from its title when first
# published.
def draft_data.go(sl: Maybe<&2, Text.Slug>, ti: Maybe<&2, Text.Title>) -> Maybe<&2, Db.WData>:
  match sl ti:
    case Some{x} Some{y}:
      Some{Db.blog_data(x, y)}
    case _ _:
      None{}

def draft_data(+hex: String) -> Maybe<&2, Db.WData>:
  draft_data.go(Text.mk_slug("draft-" ++ hex), Text.mk_title("Untitled"))

def h_new_draft2(s: Socket, +token: String, +who: U32, +blog: U32, d: Maybe<&2, Db.WData>) -> IO(Unit):
  match d:
    case None{}:
      fail(s, token, who, 500)
    case Some{x}:
      do IO<Unit>:
        f : Spec.Facts <- Db.facts(who, blog, 0)
        write_new(s, token, who, Authz.authorize(f, Spec.CreatePost{blog}), x, "/edit/")

def h_new_draft(s: Socket, +token: String, +who: U32, +blog: U32) -> IO(Unit):
  do IO<Unit>:
    +hex : String <- Auth.random_hex(4)
    h_new_draft2(s, token, who, blog, draft_data(hex))

def h_create_post.pick(draft: Bool, s: Socket, +token: String, +who: U32, +blog: U32, +xs: List<&2, Text.Field>) -> IO(Unit):
  match draft:
    case True{}:
      h_new_draft(s, token, who, blog)
    case False{}:
      h_create_post2(s, token, who, blog, Text.form_slug_or(xs, "slug", "title"), Text.form_title(xs, "title"))

# Without a title: a new draft. With one (and optionally an address): a
# post with those.
def h_create_post.go(s: Socket, +token: String, +who: U32, +bslug: String, +xs: List<&2, Text.Field>) -> IO(Unit):
  do IO<Unit>:
    blog : List<&2, List<&2, String>> <- blog_rows(token, bslug)
    h_create_post.pick(String.is_empty(Maybe.default(&2, String, Text.form_raw(xs, "title"), "")), s, token, who, num(first_col(blog, 0n)), xs)

# The Write button: a new draft in your blog. With no blog, or several, the
# dashboard (which asks for a name, or offers each blog's New post).
def h_write2(s: Socket, +token: String, +who: U32, +rows: List<&2, List<&2, String>>) -> IO(Unit):
  match rows:
    case Nil{}:
      redirect(s, token, "/dash", "")
    case Con{r, t}:
      match t:
        case Nil{}:
          h_new_draft(s, token, who, num(Pages.col(r, 0n)))
        case Con{r2, t2}:
          redirect(s, token, "/dash", "")

def h_write(s: Socket, +token: String, +who: U32) -> IO(Unit):
  do IO<Unit>:
    rows : List<&2, List<&2, String>> <- Db.query(Db.q_my_blogs(), 0, 0, "", token)
    h_write2(s, token, who, rows)

# AUTHOR PAGES (cached like the feeds)
def h_author3(s: Socket, +token: String, +who: U32, +uid: U32, +name: List<&2, List<&2, String>>) -> IO(Unit):
  match name:
    case Nil{}:
      fail(s, token, who, 404)
    case Con{+r, t}:
      do IO<Unit>:
        rows : List<&2, List<&2, String>> <- Db.query(Db.q_posts_by_author(), uid, 0, "", token)
        cache_send(s, cache_key("u", who, U32.show(uid)), Pages.layout(Pages.col(r, 0n), signed(who), Pages.author_page(Pages.col(r, 0n), rows)))

def h_author2(s: Socket, +token: String, +who: U32, +uid: U32) -> IO(Unit):
  do IO<Unit>:
    name : List<&2, List<&2, String>> <- Db.query(Db.q_author_public(), uid, 0, "", token)
    h_author3(s, token, who, uid, name)

def h_author.go(r: Socket & Result<&1, &1, U32 & String, Unit>, +token: String, +who: U32, +uid: U32) -> IO(Unit):
  (s, x) = r
  match x:
    case Done{u}:
      Socket.close(s)
    case Fail{err}:
      h_author2(s, token, who, uid)

def h_author(s: Socket, +token: String, +who: U32, +uid: U32) -> IO(Unit):
  do IO<Unit>:
    r : Socket & Result<&1, &1, U32 & String, Unit> <- Db.cached(s, cache_key("u", who, U32.show(uid)))
    h_author.go(r, token, who, uid)

def h_create_post(s: Socket, +token: String, +who: U32, +bslug: String, +body: String) -> IO(Unit):
  +xs = form(body)
  h_create_post.go(s, token, who, bslug, xs)

# Publishing lands on the live post with a notice; unpublishing returns to
# the editor. A never-published draft takes its address from its title
# (Db.slug_data; renamed in C, see db_publish_rename).
def publish_data.go(m: Maybe<&2, Text.Slug>) -> Db.WData:
  match m:
    case None{}:
      Db.no_data()
    case Some{sl}:
      Db.slug_data(sl)

def publish_data(+title: String) -> Db.WData:
  publish_data.go(Text.mk_slug(Text.slugify(title)))

def h_published(s: Socket, +token: String, +who: U32, +pid: U32, r: Result<&1, &1, U32 & String, U32>) -> IO(Unit):
  match r:
    case Done{id}:
      do IO<Unit>:
        +md : List<&2, List<&2, String>> <- Db.query(Db.q_post_md(), pid, 0, "", token)
        redirect(s, token, "/b/" ++ (first_col(md, 3n) ++ ("/" ++ (first_col(md, 4n) ++ "?published=1"))), "")
    case Fail{err}:
      (code, msg) = err
      fail(s, token, who, apply_status(code))

def h_publish2(s: Socket, +token: String, +who: U32, +pid: U32, m: Maybe<&2, Authz.Permit>) -> IO(Unit):
  match m:
    case None{}:
      fail(s, token, who, 403)
    case Some{p}:
      do IO<Unit>:
        +md : List<&2, List<&2, String>> <- Db.query(Db.q_post_md(), pid, 0, "", token)
        r : Result<&1, &1, U32 & String, U32> <- Db.apply(token, p, 1, publish_data(first_col(md, 1n)))
        h_published(s, token, who, pid, r)

def h_publish.go(one: Bool, s: Socket, +token: String, +who: U32, +pid: U32) -> IO(Unit):
  match one:
    case True{}:
      do IO<Unit>:
        f : Spec.Facts <- Db.facts(who, 0, pid)
        h_publish2(s, token, who, pid, Authz.authorize(f, Spec.PublishPost{pid}))
    case False{}:
      do IO<Unit>:
        f : Spec.Facts <- Db.facts(who, 0, pid)
        write(s, token, who, Authz.authorize(f, Spec.PublishPost{pid}), 0, Db.no_data(), "/edit/" ++ U32.show(pid))

def h_publish(s: Socket, +token: String, +who: U32, +pid: U32, +flag: U32) -> IO(Unit):
  h_publish.go(U32.is_ne(flag, 0), s, token, who, pid)

# After saving: publish too if that is what the button said. Publishing
# needs its own Permit (PublishPost), checked on fresh facts.
def h_save3(publish: Bool, s: Socket, +token: String, +who: U32, +pid: U32, r: Result<&1, &1, U32 & String, U32>) -> IO(Unit):
  match publish:
    case True{}:
      match r:
        case Done{id}:
          h_publish(s, token, who, pid, 1)
        case Fail{err}:
          (code, msg) = err
          fail(s, token, who, apply_status(code))
    case False{}:
      write_done(s, token, who, "/edit/" ++ U32.show(pid), r)

def h_save.run(publish: Bool, s: Socket, +token: String, +who: U32, +pid: U32, m: Maybe<&2, Authz.Permit>, +flag: U32, d: Db.WData) -> IO(Unit):
  match m:
    case None{}:
      fail(s, token, who, 403)
    case Some{p}:
      do IO<Unit>:
        r : Result<&1, &1, U32 & String, U32> <- Db.apply(token, p, flag, d)
        h_save3(publish, s, token, who, pid, r)

# With a tags field, the save also sets the post's tags (flag 1).
def save_flag(+tags: Maybe<&2, String>) -> U32:
  match tags:
    case None{}:
      0
    case Some{t}:
      1

def save_data(ti: Text.Title, +bo: Text.Body, +tags: Maybe<&2, String>) -> Db.WData:
  match tags:
    case None{}:
      Db.post_data(ti, bo)
    case Some{+t}:
      Db.post_tags_data(ti, bo, Text.tags_of(t))

def h_save2(publish: Bool, s: Socket, +token: String, +who: U32, +pid: U32, title: Maybe<&2, Text.Title>, body: Maybe<&2, Text.Body>, +tags: Maybe<&2, String>) -> IO(Unit):
  match title body:
    case Some{ti} Some{+bo}:
      do IO<Unit>:
        f : Spec.Facts <- Db.facts(who, 0, pid)
        h_save.run(publish, s, token, who, pid, Authz.authorize(f, Spec.EditPost{pid}), save_flag(tags), save_data(ti, bo, tags))
    case _ _:
      fail(s, token, who, 400)

def ops_text(m: Maybe<&2, List<&2, Crdt.Op>>) -> String:
  match m:
    case None{}:
      ""
    case Some{+xs}:
      Crdt.text(xs)

def wants_publish(+xs: List<&2, Text.Field>) -> Bool:
  String.eq(Maybe.default(&2, String, Text.form_raw(xs, "action"), ""), "publish")

def h_save.pick(none: Bool, s: Socket, +token: String, +who: U32, +pid: U32, +xs: List<&2, Text.Field>, +wire: String) -> IO(Unit):
  match none:
    case True{}:
      h_save2(wants_publish(xs), s, token, who, pid, Text.form_title(xs, "title"), Text.form_body(xs, "body"), Text.decode_of(Text.form_get(xs, "tags")))
    case False{}:
      h_save2(wants_publish(xs), s, token, who, pid, Text.form_title(xs, "title"), Text.body_of(Some{ops_text(Crdt.decode(wire))}), Text.decode_of(Text.form_get(xs, "tags")))

def h_save.go(s: Socket, +token: String, +who: U32, +pid: U32, +xs: List<&2, Text.Field>) -> IO(Unit):
  do IO<Unit>:
    +rows : List<&2, List<&2, String>> <- Db.query(Db.q_ops(), pid, 0, "", token)
    h_save.pick(String.is_empty(first_col(rows, 0n)), s, token, who, pid, xs, first_col(rows, 0n))

# Saving renders the post. If the post has collaborative operations, its
# text comes from them (never from what the client posts); otherwise from
# the form (editing without JavaScript).
def h_save(s: Socket, +token: String, +who: U32, +pid: U32, +body: String) -> IO(Unit):
  h_save.go(s, token, who, pid, form(body))

def h_delete(s: Socket, +token: String, +who: U32, +pid: U32) -> IO(Unit):
  do IO<Unit>:
    f : Spec.Facts <- Db.facts(who, 0, pid)
    write(s, token, who, Authz.authorize(f, Spec.DeletePost{pid}), 0, Db.no_data(), "/dash")

def h_add_author4(none: Bool, s: Socket, +token: String, +who: U32, +blog: U32, +bslug: String, +uid: U32) -> IO(Unit):
  match none:
    case True{}:
      fail(s, token, who, 400)
    case False{}:
      do IO<Unit>:
        f : Spec.Facts <- Db.facts(who, blog, 0)
        write(s, token, who, Authz.authorize(f, Spec.AddAuthor{blog, uid}), 0, Db.no_data(), "/dash/" ++ bslug)

def h_add_author3(s: Socket, +token: String, +who: U32, +blog: U32, +bslug: String, +users: List<&2, List<&2, String>>) -> IO(Unit):
  +uid = num(first_col(users, 0n))
  h_add_author4(U32.is_eq(uid, 0), s, token, who, blog, bslug, uid)

def h_add_author2(s: Socket, +token: String, +who: U32, +bslug: String, +blog: U32, email: Maybe<&2, Text.Title>) -> IO(Unit):
  match email:
    case None{}:
      fail(s, token, who, 400)
    case Some{em}:
      do IO<Unit>:
        users : List<&2, List<&2, String>> <- Db.query(Db.q_user_by_email(), 0, 0, Text.Title.text(em), token)
        h_add_author3(s, token, who, blog, bslug, users)

def h_add_author.go(s: Socket, +token: String, +who: U32, +bslug: String, +xs: List<&2, Text.Field>) -> IO(Unit):
  do IO<Unit>:
    blog : List<&2, List<&2, String>> <- blog_rows(token, bslug)
    h_add_author2(s, token, who, bslug, num(first_col(blog, 0n)), Text.form_title(xs, "email"))

def h_add_author(s: Socket, +token: String, +who: U32, +bslug: String, +body: String) -> IO(Unit):
  +xs = form(body)
  h_add_author.go(s, token, who, bslug, xs)

def h_remove_author(s: Socket, +token: String, +who: U32, +bslug: String, +uid: U32) -> IO(Unit):
  do IO<Unit>:
    blog : List<&2, List<&2, String>> <- blog_rows(token, bslug)
    +id : U32 = num(first_col(blog, 0n))
    f : Spec.Facts <- Db.facts(who, id, 0)
    write(s, token, who, Authz.authorize(f, Spec.RemoveAuthor{id, uid}), 0, Db.no_data(), "/dash/" ++ bslug)

def h_logout(s: Socket, +token: String) -> IO(Unit):
  do IO<Unit>:
    Db.session_end(token)
    redirect(s, token, "/", "-")

# Static assets are compiled into the server (src/effects/db.c): 0 the
# editor, 1 the stylesheet, 2 the passkey script.
def h_static(k: Nat, s: Socket, +token: String, +who: U32) -> IO(Unit):
  match k:
    case 0n:
      fail(s, token, who, 404)
    case 1n+id:
      do IO<Unit>:
        r : Socket & Result<&1, &1, U32 & String, Unit> <- Db.asset(s, U32.from_nat(id))
        done(r)

def h_sync3(s: Socket, +token: String, +who: U32, +ops: String, +since: U32, m: Maybe<&2, Authz.Permit>) -> IO(Unit):
  match m:
    case None{}:
      send_text(s, token, 403, "not allowed\n")
    case Some{p}:
      do IO<Unit>:
        r : Socket & Result<&1, &1, U32 & String, Unit> <- Db.sync(s, token, p, ops, since)
        done(r)

def h_sync2(ok: Bool, s: Socket, +token: String, +who: U32, +pid: U32, +ops: String, +since: U32) -> IO(Unit):
  match ok:
    case True{}:
      do IO<Unit>:
        f : Spec.Facts <- Db.facts(who, 0, pid)
        h_sync3(s, token, who, ops, since, Authz.authorize(f, Spec.EditPost{pid}))
    case False{}:
      send_text(s, token, 400, "bad operations\n")

def is_some_ops(m: Maybe<&2, List<&2, Crdt.Op>>) -> Bool:
  match m:
    case None{}:
      False{}
    case Some{x}:
      True{}

def h_sync.go(s: Socket, +token: String, +who: U32, +pid: U32, +ops: String, +since: U32) -> IO(Unit):
  h_sync2(is_some_ops(Crdt.decode(ops)), s, token, who, pid, ops, since)

# POST /edit/<id>/sync: since=<seq>&ops=<wire>. The operations are checked
# for meaning here (Crdt.decode) and for syntax and ranges in C.
def h_sync(s: Socket, +token: String, +who: U32, +pid: U32, +body: String) -> IO(Unit):
  +xs = form(body)
  h_sync.go(s, token, who, pid, Maybe.default(&2, String, Text.form_raw(xs, "ops"), ""), form_num(xs, "since"))

# DISPATCH
# --------
def read(s: Socket, r: Route.Route, +token: String, +who: U32, +query: String, +origin: String) -> IO(Unit):
  match r:
    case Route.RFeed{}:
      h_feed(s, token, origin)
    case Route.RSearch{}:
      h_search(s, token, who, query)
    case Route.RReply{+id}:
      h_reply(s, token, who, id)
    case Route.RTag{+t}:
      h_tag(s, token, who, t)
    case Route.RBlogFeed{+b}:
      h_blog_feed(s, token, origin, b)
    case Route.RHome{}:
      h_home(s, token, who)
    case Route.RHealth{}:
      send_text(s, token, 200, "ok\n")
    case Route.RBlog{+slug}:
      h_blog(s, token, who, slug)
    case Route.RPost{+b, +p}:
      h_post(s, token, who, b, p, query)
    case Route.RAuthor{+id}:
      h_author(s, token, who, id)
    case Route.RDash{}:
      h_dash(s, token, who)
    case Route.RDashBlog{+slug}:
      h_dash_blog(s, token, who, slug)
    case Route.REdit{+id}:
      h_edit(s, token, who, id)
    case Route.RStatic{+name}:
      h_static(U32.to_nat((Bool.to_u32(String.eq(name, "editor.js")) + ((2 * Bool.to_u32(String.eq(name, "app.css"))) + (3 * Bool.to_u32(String.eq(name, "passkey.js")))) : U32)), s, token, who)
    case Route.RSignupPage{}:
      Auth.h_signup_page(s, token, who)
    case Route.RLoginPage{}:
      Auth.h_login_page(s, token, who)
    case Route.RVerify{}:
      Auth.h_verify(s, token, query)
    case _:
      fail(s, token, who, 404)

def write_route(s: Socket, r: Route.Route, +c: Auth.Conf, +token: String, +who: U32, +body: String) -> IO(Unit):
  match r:
    case Route.RCreateBlog{}:
      h_create_blog(s, token, who, body)
    case Route.RCreatePost{+b}:
      h_create_post(s, token, who, b, body)
    case Route.RSavePost{+id}:
      h_save(s, token, who, id, body)
    case Route.RPublish{+id}:
      h_publish(s, token, who, id, 1)
    case Route.RUnpublish{+id}:
      h_publish(s, token, who, id, 0)
    case Route.RDeletePost{+id}:
      h_delete(s, token, who, id)
    case Route.RAddAuthor{+b}:
      h_add_author(s, token, who, b, body)
    case Route.RRemoveAuthor{+b, +u}:
      h_remove_author(s, token, who, b, u)
    case Route.RLogout{}:
      h_logout(s, token)
    case Route.RWrite{}:
      h_write(s, token, who)
    case Route.RLike{+id}:
      h_like(s, token, who, id, body)
    case Route.RComment{+id}:
      h_comment(s, token, who, id, body)
    case Route.RDeleteComment{+id}:
      h_delete_comment(s, token, who, id)
    case Route.RSync{+id}:
      h_sync(s, token, who, id, body)
    case Route.RSignup{}:
      Auth.h_signup(s, c, token, body)
    case Route.RRecover{}:
      Auth.h_recover(s, c, token, body)
    case Route.RRegOptions{}:
      Auth.h_reg_options(s, c, token, body)
    case Route.RRegister{}:
      Auth.h_register(s, c, token, body)
    case Route.RLoginOptions{}:
      Auth.h_login_options(s, c, token)
    case Route.RLogin{}:
      Auth.h_login(s, c, token, body)
    case _:
      fail(s, token, who, 404)

# Executes a plan. Only Write plans reach write_route.
def exec(s: Socket, p: Route.Plan, +c: Auth.Conf, +token: String, +who: U32, +body: String, +query: String) -> IO(Unit):
  match p:
    case Route.Read{r}:
      read(s, r, token, who, query, Auth.origin(c))
    case Route.Write{r}:
      write_route(s, r, c, token, who, body)
    case Route.Deny{+status}:
      fail(s, token, who, status)
