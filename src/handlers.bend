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
    r : Socket & Result<&1, &1, U32 & String, Unit> <- Db.page_cache_put(s, key, ctype, one(text), Nil{})
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

# Results are cached like feeds (the key is the sanitized query; a long one
# is simply not cached).
# SEARCH: /search?q=... (not cached: queries vary). An empty or wordless
# query shows the box only.
def form(+body: String) -> List<&2, Text.Field>:
  Maybe.default(&2, List<&2, Text.Field>, Text.form_parse(body), Nil{})

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

# A signed-out visitor's post page is the same for all of them: cached
# under p0:<id> (dropped by each write to the post, its likes or comments,
# and by blog-wide changes: see src/effects/db.c app_post_gen).
def h_post5(anon: Bool, s: Socket, +token: String, +pid: U32, +pg: Pages.Page) -> IO(Unit):
  match anon:
    case True{}:
      do IO<Unit>:
        x : Socket & Result<&1, &1, U32 & String, Unit> <- Db.page_cache_put(s, "p0:" ++ U32.show(pid), 0, Pages.page_texts(pg), Pages.page_bodies(pg))
        done(x)
    case False{}:
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
        last : List<&2, List<&2, String>> <- Db.query(Db.q_last_comment(), pid, 0, "", token)
        comments : List<&2, List<&2, String>> <- Db.query(Db.q_comments(), pid, 0, "", token)
        h_post5(Bool.not(signed(who)), s, token, pid, Pages.page_of(Con{Pages.T{Pages.layout_top(Pages.col(r, 1n), signed(who)) ++ Pages.post_before(r, U32.show(pid), can_edit, Bool.and(can_edit, notice))}, Con{Pages.B{pid}, Con{Pages.T{Pages.post_after(r, Pages.tag_chips(tags) ++ Pages.social_bar(signed(who), U32.show(pid), first_row(social)))}, List.append(&2, Pages.Seg, Pages.comments_section(signed(who), can_edit, U32.show(pid), first_col(social, 2n), first_col(last, 0n), comments), Con{Pages.T{Pages.layout_bottom()}, Nil{}})}}}, ""))

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

def upload_status.go(k: Nat) -> U32:
  match k:
    case 1n:
      409
    case 2n:
      403
    case 3n:
      400
    case _:
      500

def upload_status(+code: U32) -> U32:
  upload_status.go(U32.to_nat(code))

# IMAGES: POST /upload/<post> with the image's bytes as the body (from
# the editor's script, which resizes to fit the 1 MiB request limit).
# Answers the image's path as text.
def uploaded(s: Socket, +token: String, r: Result<&1, &1, U32 & String, String>) -> IO(Unit):
  match r:
    case Done{+key}:
      send_text(s, token, 200, "/img/" ++ key)
    case Fail{err}:
      (+code, msg) = err
      send_text(s, token, upload_status(code), "The image was not stored: not a JPEG, PNG, GIF or WebP, too large, or too many.\n")

def h_upload2(s: Socket, +token: String, +who: U32, +body: String, m: Maybe<&2, Authz.Permit>) -> IO(Unit):
  match m:
    case None{}:
      send_text(s, token, 403, "not allowed\n")
    case Some{p}:
      do IO<Unit>:
        r : Result<&1, &1, U32 & String, String> <- Db.upload(token, p, body)
        uploaded(s, token, r)

def h_upload(s: Socket, +token: String, +who: U32, +pid: U32, +body: String) -> IO(Unit):
  do IO<Unit>:
    f : Spec.Facts <- Db.facts(who, 0, pid)
    h_upload2(s, token, who, body, Authz.authorize(f, Spec.UploadImage{pid}))

def form_num(+xs: List<&2, Text.Field>, +key: String) -> U32:
  Maybe.default(&2, U32, U32.read(Maybe.default(&2, String, Text.form_raw(xs, key), "")), 0)

# DATASTAR RESPONSES
# ------------------
# ?frag=1 (from Datastar): answer with patches (content type 2: a stream of
# Datastar events, src/effects/db.c page_sse) instead of a page or a
# redirect.
def wants_frag(+xs: List<&2, Text.Field>) -> Bool:
  String.eq(Maybe.default(&2, String, Text.form_raw(xs, "frag"), ""), "1")

def frag_of(+query: String, +body: String) -> Bool:
  Bool.or(wants_frag(form(query)), wants_frag(form(body)))

def stream(s: Socket, +token: String, +pg: Pages.Page) -> IO(Unit):
  do IO<Unit>:
    x : Socket & Result<&1, &1, U32 & String, Unit> <- Db.page(s, 200, 2, Pages.page_texts(pg), Pages.page_bodies(pg), token, "", "")
    done(x)

def stream1(s: Socket, +token: String, +text: String) -> IO(Unit):
  stream(s, token, Pages.Page{Con{text, Nil{}}, Nil{}})

# LIVE COMMENTS: GET /live/<post>?after=N&n=K (Datastar, from the #live
# element) opens an event stream that stays open. Each round waits up to
# 25 s for a comment newer than N: new ones are pushed (appended under
# their parents, with fresh counts); otherwise a keep-alive line, which
# also finds out that the reader has gone (the write fails, the loop ends,
# its place is freed). After 24 rounds (~10 min), or when too many readers
# are waiting, the stream ends by patching #live with the next request,
# which Datastar makes (after a pause if busy). Readers of the post only.
def live_chunk(new: Bool, +rows: List<&2, List<&2, String>>, +social: List<&2, List<&2, String>>, +signed: Bool, +can_mod: Bool, +pid: U32) -> Pages.Page:
  match new:
    case True{}:
      Pages.page_of(List.append(&2, Pages.Seg, Pages.live_segs(rows, signed, can_mod), Con{Pages.T{Pages.patch("", "outer", Pages.social_bar(signed, U32.show(pid), first_row(social)))}, Nil{}}), "")
    case False{}:
      Pages.Page{Con{": ping\n\n", Nil{}}, Nil{}}

def live_end(s: Socket, +token: String, +pid: U32, +after: U32, +n: U32, +busy: Bool) -> IO(Unit):
  do IO<Unit>:
    r : Socket & Result<&1, &1, U32 & String, Unit> <- Db.stream_send(s, 0, Con{Pages.patch("", "outer", Pages.live_div(U32.show(pid), U32.show(after), U32.show((n + 1 : U32)), busy)), Nil{}}, Nil{}, token)
    done(r)

def last_id(rows: List<&2, List<&2, String>>, +d: String) -> String:
  match rows:
    case Nil{}:
      d
    case Con{+r, t}:
      match t:
        case Nil{}:
          Pages.col(r, 0n)
        case Con{r2, t2}:
          last_id(Con{r2, t2}, d)

# One round per k: the stream ends when the reader has gone (a failed
# write) or the rounds run out.
def live_loop(k: Nat, r: Socket & Result<&1, &1, U32 & String, Unit>, +token: String, +who: U32, +pid: U32, +can_mod: Bool, +after: U32, +n: U32, +busy: Bool) -> IO(Unit):
  match k:
    case 0n:
      (s, x) = r
      match x:
        case Fail{err}:
          Socket.close(s)
        case Done{u}:
          live_end(s, token, pid, after, n, busy)
    case 1n+rest:
      (s, x) = r
      match x:
        case Fail{err}:
          Socket.close(s)
        case Done{u}:
          match busy:
            case True{}:
              live_end(s, token, pid, after, n, True{})
            case False{}:
              do IO<Unit>:
                +code : U32 <- Db.comment_wait(pid, after, 25000)
                +rows : List<&2, List<&2, String>> <- Db.query(Db.q_comments_after(), pid, after, "", token)
                +social : List<&2, List<&2, String>> <- Db.query(Db.q_post_social(), pid, 0, "", token)
                +pg : Pages.Page = live_chunk(U32.is_eq(code, 1), rows, social, signed(who), can_mod, pid)
                r2 : Socket & Result<&1, &1, U32 & String, Unit> <- Db.stream_send(s, Bool.to_u32(U32.is_ne(code, 1)), Pages.page_texts(pg), Pages.page_bodies(pg), token)
                live_loop(rest, r2, token, who, pid, can_mod, num(last_id(rows, U32.show(after))), n, U32.is_eq(code, 2))

def h_live3(s: Socket, +token: String, +who: U32, +pid: U32, +can_mod: Bool, +after: U32, +n: U32, m: Maybe<&2, Authz.Permit>) -> IO(Unit):
  match m:
    case None{}:
      send_text(s, token, 404, "not found\n")
    case Some{p}:
      do IO<Unit>:
        r : Socket & Result<&1, &1, U32 & String, Unit> <- Db.stream_open(s)
        live_loop(24n, r, token, who, pid, can_mod, after, n, False{})

def h_live(s: Socket, +token: String, +who: U32, +pid: U32, +query: String) -> IO(Unit):
  do IO<Unit>:
    +f : Spec.Facts <- Db.facts(who, 0, pid)
    h_live3(s, token, who, pid, is_some_permit(Authz.authorize(f, Spec.EditPost{pid})), form_num(form(query), "after"), form_num(form(query), "n"), Authz.authorize(f, Spec.ReadPost{pid}))

# LIKES AND COMMENTS
# ------------------
# Without Datastar each ends on the post's page (at an anchor); the post's
# address comes from the database.
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

# With Datastar: the new like button (morphed into #social by its id).
def liked(frag: Bool, s: Socket, +token: String, +who: U32, +pid: U32, r: Result<&1, &1, U32 & String, U32>) -> IO(Unit):
  match frag:
    case False{}:
      engage_done(s, token, who, pid, "#social", r)
    case True{}:
      do IO<Unit>:
        social : List<&2, List<&2, String>> <- Db.query(Db.q_post_social(), pid, 0, "", token)
        send(s, token, 200, Pages.social_bar(True{}, U32.show(pid), first_row(social)))

def h_like2(frag: Bool, s: Socket, +token: String, +who: U32, +pid: U32, +on: U32, m: Maybe<&2, Authz.Permit>) -> IO(Unit):
  match m:
    case None{}:
      fail(s, token, who, 403)
    case Some{p}:
      do IO<Unit>:
        r : Result<&1, &1, U32 & String, U32> <- Db.apply(token, p, on, Db.no_data())
        liked(frag, s, token, who, pid, r)

def h_like.go(signed: Bool, frag: Bool, s: Socket, +token: String, +who: U32, +pid: U32, +on: U32) -> IO(Unit):
  match signed:
    case False{}:
      redirect(s, token, "/login", "")
    case True{}:
      do IO<Unit>:
        f : Spec.Facts <- Db.facts(who, 0, pid)
        h_like2(frag, s, token, who, pid, on, Authz.authorize(f, Spec.LikePost{pid}))

# POST /like/<post>: on=1 likes, on=0 unlikes.
def h_like(s: Socket, +token: String, +who: U32, +pid: U32, +body: String, +query: String) -> IO(Unit):
  h_like.go(signed(who), frag_of(query, body), s, token, who, pid, Bool.to_u32(String.eq(Maybe.default(&2, String, Text.form_raw(form(body), "on"), ""), "1")))

def box_id.go(top: Bool, +parent: U32) -> String:
  match top:
    case True{}:
      "cform"
    case False{}:
      "rff" ++ U32.show(parent)

# The comment box a comment came from: #cform, or the reply form #rff<parent>.
def box_id(+parent: U32) -> String:
  box_id.go(U32.is_eq(parent, 0), parent)

# With Datastar a sent comment empties its box (a fresh #cform, or the
# reply form removed); the live update brings the comment itself.
def comment_sent(top: Bool, s: Socket, +token: String, +pid: U32, +parent: U32) -> IO(Unit):
  match top:
    case True{}:
      stream1(s, token, Pages.patch("", "replace", Pages.comment_box(U32.show(pid), "0", "cform", "3", "Write a comment", "")))
    case False{}:
      stream1(s, token, Pages.patch("#rff" ++ U32.show(parent), "remove", ""))

def comment_ok(frag: Bool, s: Socket, +token: String, +pid: U32, +parent: U32, +id: U32) -> IO(Unit):
  match frag:
    case True{}:
      comment_sent(U32.is_eq(parent, 0), s, token, pid, parent)
    case False{}:
      to_post(s, token, pid, "#c" ++ U32.show(id))

# Blank, too long, or not text: 400 (with Datastar, a note by the box).
def comment_bad(frag: Bool, s: Socket, +token: String, +who: U32, +parent: U32) -> IO(Unit):
  match frag:
    case True{}:
      stream1(s, token, Pages.patch("#" ++ (box_id(parent) ++ "-note"), "inner", "Write something first (at most 10000 characters)."))
    case False{}:
      fail(s, token, who, 400)

def comment_fail_text(slow: Bool) -> String:
  match slow:
    case True{}:
      "That is a lot of comments in a minute. Wait a moment and send it again."
    case False{}:
      "That did not work. Try again."

def comment_fail.page(slow: Bool, s: Socket, +token: String, +who: U32, +code: U32) -> IO(Unit):
  match slow:
    case True{}:
      fail(s, token, who, 429)
    case False{}:
      fail(s, token, who, apply_status(code))

def comment_fail(frag: Bool, slow: Bool, s: Socket, +token: String, +who: U32, +parent: U32, +code: U32) -> IO(Unit):
  match frag:
    case True{}:
      stream1(s, token, Pages.patch("#" ++ (box_id(parent) ++ "-note"), "inner", comment_fail_text(slow)))
    case False{}:
      comment_fail.page(slow, s, token, who, code)

def comment_done(frag: Bool, s: Socket, +token: String, +who: U32, +pid: U32, +parent: U32, r: Result<&1, &1, U32 & String, U32>) -> IO(Unit):
  match r:
    case Done{+id}:
      comment_ok(frag, s, token, pid, parent, id)
    case Fail{err}:
      (+code, msg) = err
      comment_fail(frag, U32.is_eq(code, 3), s, token, who, parent, code)

def h_comment3(frag: Bool, s: Socket, +token: String, +who: U32, +pid: U32, +parent: U32, +b: Text.Body, m: Maybe<&2, Authz.Permit>) -> IO(Unit):
  match m:
    case None{}:
      fail(s, token, who, 403)
    case Some{p}:
      do IO<Unit>:
        r : Result<&1, &1, U32 & String, U32> <- Db.apply(token, p, parent, Db.comment_data(b))
        comment_done(frag, s, token, who, pid, parent, r)

def h_comment2(frag: Bool, s: Socket, +token: String, +who: U32, +pid: U32, +parent: U32, m: Maybe<&2, Text.Body>) -> IO(Unit):
  match m:
    case None{}:
      comment_bad(frag, s, token, who, parent)
    case Some{+b}:
      do IO<Unit>:
        f : Spec.Facts <- Db.facts(who, 0, pid)
        h_comment3(frag, s, token, who, pid, parent, b, Authz.authorize(f, Spec.CommentPost{pid}))

def h_comment.go(signed: Bool, frag: Bool, s: Socket, +token: String, +who: U32, +pid: U32, +xs: List<&2, Text.Field>) -> IO(Unit):
  match signed:
    case False{}:
      redirect(s, token, "/login", "")
    case True{}:
      h_comment2(frag, s, token, who, pid, form_num(xs, "parent"), Text.form_comment(xs, "body"))

# POST /comment/<post>: body, and parent (a comment id) for a reply.
def h_comment(s: Socket, +token: String, +who: U32, +pid: U32, +body: String, +query: String) -> IO(Unit):
  h_comment.go(signed(who), frag_of(query, body), s, token, who, pid, form(body))

# With Datastar a deleted comment's text becomes "[deleted]" in place.
def deleted(frag: Bool, s: Socket, +token: String, +who: U32, +pid: U32, +cid: U32, r: Result<&1, &1, U32 & String, U32>) -> IO(Unit):
  match frag:
    case False{}:
      engage_done(s, token, who, pid, "#comments", r)
    case True{}:
      stream1(s, token, Pages.patch("#cb" ++ U32.show(cid), "inner", "<p class=\"muted\">[deleted]</p>") ++ Pages.patch("#ca" ++ U32.show(cid), "remove", ""))

def h_delete_comment3(frag: Bool, s: Socket, +token: String, +who: U32, +pid: U32, +cid: U32, m: Maybe<&2, Authz.Permit>) -> IO(Unit):
  match m:
    case None{}:
      fail(s, token, who, 403)
    case Some{p}:
      do IO<Unit>:
        r : Result<&1, &1, U32 & String, U32> <- Db.apply(token, p, 0, Db.no_data())
        deleted(frag, s, token, who, pid, cid, r)

def h_delete_comment2(frag: Bool, s: Socket, +token: String, +who: U32, +cid: U32, +info: List<&2, List<&2, String>>) -> IO(Unit):
  match info:
    case Nil{}:
      fail(s, token, who, 404)
    case Con{+r, t}:
      do IO<Unit>:
        f : Spec.Facts <- Db.facts(who, 0, num(Pages.col(r, 0n)))
        h_delete_comment3(frag, s, token, who, num(Pages.col(r, 0n)), cid, Authz.authorize(f, Spec.DeleteComment{num(Pages.col(r, 0n)), cid, num(Pages.col(r, 1n))}))

# POST /comment/<id>/delete: by its author, or a member of the blog. The
# author is as loaded here; the write only matches a comment by them.
def h_delete_comment(s: Socket, +token: String, +who: U32, +cid: U32, +query: String) -> IO(Unit):
  do IO<Unit>:
    info : List<&2, List<&2, String>> <- Db.query(Db.q_comment_info(), cid, 0, "", token)
    h_delete_comment2(wants_frag(form(query)), s, token, who, cid, info)

def h_reply3(s: Socket, +token: String, +who: U32, +cid: U32, +info: List<&2, String>, +view: List<&2, List<&2, String>>) -> IO(Unit):
  do IO<Unit>:
    x : Socket & Result<&1, &1, U32 & String, Unit> <- Db.page(s, 200, 0, two(Pages.layout_top("Reply", True{}) ++ Pages.reply_before(info, "/b/" ++ (first_col(view, 3n) ++ ("/" ++ (first_col(view, 0n) ++ ("#c" ++ U32.show(cid)))))), Pages.reply_after(info, U32.show(cid), "/b/" ++ (first_col(view, 3n) ++ ("/" ++ (first_col(view, 0n) ++ ("#c" ++ U32.show(cid)))))) ++ Pages.layout_bottom()), Con{Db.comment_body(cid), Nil{}}, token, "", "")
    done(x)

def h_reply2.go(frag: Bool, s: Socket, +token: String, +who: U32, +cid: U32, +r: List<&2, String>) -> IO(Unit):
  match frag:
    case True{}:
      stream1(s, token, Pages.patch("#rf" ++ U32.show(cid), "inner", Pages.reply_box(Pages.col(r, 0n), U32.show(cid))))
    case False{}:
      do IO<Unit>:
        view : List<&2, List<&2, String>> <- Db.query(Db.q_post_view(), num(Pages.col(r, 0n)), 0, "", token)
        h_reply3(s, token, who, cid, r, view)

# With Datastar: the reply form, inline under the comment (#rf<id>).
def h_reply2(frag: Bool, s: Socket, +token: String, +who: U32, +cid: U32, +info: List<&2, List<&2, String>>) -> IO(Unit):
  match info:
    case Nil{}:
      fail(s, token, who, 404)
    case Con{+r, t}:
      h_reply2.go(frag, s, token, who, cid, r)

def h_reply.go(signed: Bool, frag: Bool, s: Socket, +token: String, +who: U32, +cid: U32) -> IO(Unit):
  match signed:
    case False{}:
      redirect(s, token, "/login", "")
    case True{}:
      do IO<Unit>:
        info : List<&2, List<&2, String>> <- Db.query(Db.q_comment_info(), cid, 0, "", token)
        h_reply2(frag, s, token, who, cid, info)

# GET /reply/<comment>: the comment, and a form to answer it.
def h_reply(s: Socket, +token: String, +who: U32, +cid: U32, +query: String) -> IO(Unit):
  h_reply.go(signed(who), wants_frag(form(query)), s, token, who, cid)

# ?published=1: the editor just published it (a notice, for members only).
def just_published(+query: String) -> Bool:
  String.eq(Maybe.default(&2, String, Text.form_raw(form(query), "published"), ""), "1")

def h_post.anon(anon: Bool, s: Socket, +token: String, +who: U32, +pid: U32, +notice: Bool) -> IO(Unit):
  match anon:
    case True{}:
      do IO<Unit>:
        r : Socket & Result<&1, &1, U32 & String, Unit> <- Db.cached(s, "p0:" ++ U32.show(pid))
        cached_or(r, s2 => h_post2(s2, token, who, pid, notice))
    case False{}:
      h_post2(s, token, who, pid, notice)

def h_post(s: Socket, +token: String, +who: U32, +bslug: String, +pslug: String, +query: String) -> IO(Unit):
  do IO<Unit>:
    blog : List<&2, List<&2, String>> <- blog_rows(token, bslug)
    +ids : List<&2, List<&2, String>> <- Db.query(Db.q_post_id(), num(first_col(blog, 0n)), 0, pslug, token)
    h_post.anon(Bool.and(Bool.not(signed(who)), U32.is_ne(num(first_col(ids, 0n)), 0)), s, token, who, num(first_col(ids, 0n)), just_published(query))

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

def h_dash_blog3(s: Socket, +token: String, +who: U32, +blog: U32, +slug: String, +title: String, +main: String, +failed: Bool, +f: Spec.Facts, m: Maybe<&2, Authz.Permit>) -> IO(Unit):
  match m:
    case None{}:
      fail(s, token, who, 404)
    case Some{p}:
      do IO<Unit>:
        posts : List<&2, List<&2, String>> <- Db.query(Db.q_posts_member(), blog, 0, "", token)
        authors : List<&2, List<&2, String>> <- Db.query(Db.q_authors(), blog, 0, "", token)
        dom : List<&2, List<&2, String>> <- Db.query(Db.q_blog_domain(), blog, 0, "", token)
        send(s, token, 200, Pages.layout_wide(title, True{}, Pages.dash_blog(slug, title, Spec.is_owner(facts_role(f)), posts, authors, first_row(dom), main, failed)))

def h_dash_blog2.go(s: Socket, +token: String, +who: U32, +slug: String, +id: U32, +title: String, +main: String, +failed: Bool) -> IO(Unit):
  do IO<Unit>:
    +f : Spec.Facts <- Db.facts(who, id, 0)
    h_dash_blog3(s, token, who, id, slug, title, main, failed, f, Authz.authorize(f, Spec.ReadBlogAdmin{id}))

def h_dash_blog2(s: Socket, +token: String, +who: U32, +slug: String, +main: String, +failed: Bool, +blog: List<&2, List<&2, String>>) -> IO(Unit):
  +id = num(first_col(blog, 0n))
  h_dash_blog2.go(s, token, who, slug, id, first_col(blog, 1n), main, failed)

# ?dns=0: a domain verification just found no TXT record.
def h_dash_blog(s: Socket, +token: String, +who: U32, +slug: String, +query: String, +main: String) -> IO(Unit):
  do IO<Unit>:
    blog : List<&2, List<&2, String>> <- blog_rows(token, slug)
    h_dash_blog2(s, token, who, slug, main, String.eq(Maybe.default(&2, String, Text.form_raw(form(query), "dns"), ""), "0"), blog)

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

# CUSTOM DOMAINS (the blog's owner: EditBlog). action=set with a domain
# (not this site's own host or a name under it), verify (the DNS TXT
# record _slopstack.<domain> must read slopstack-verify=<token>), remove.
def h_domain_write(s: Socket, +token: String, +who: U32, +slug: String, m: Maybe<&2, Authz.Permit>, +flag: U32, d: Db.WData) -> IO(Unit):
  write(s, token, who, m, flag, d, "/dash/" ++ (slug ++ "#domain"))

def h_domain_set2(ours: Bool, s: Socket, +token: String, +who: U32, +slug: String, m: Maybe<&2, Authz.Permit>, +domain: String) -> IO(Unit):
  match ours:
    case True{}:
      fail(s, token, who, 400)
    case False{}:
      do IO<Unit>:
        +hex : String <- Auth.random_hex(12)
        h_domain_write(s, token, who, slug, m, 1, Db.domain_data(domain, hex))

def h_domain_set(s: Socket, +token: String, +who: U32, +slug: String, +main: String, m: Maybe<&2, Authz.Permit>, d: Maybe<&2, Text.Domain>) -> IO(Unit):
  match d:
    case None{}:
      fail(s, token, who, 400)
    case Some{+x}:
      h_domain_set2(Bool.or(String.eq(Text.Domain.text(x), main), String.ends_with(Text.Domain.text(x), "." ++ main)), s, token, who, slug, m, Text.Domain.text(x))

def h_domain_verified(found: Bool, s: Socket, +token: String, +who: U32, +slug: String, m: Maybe<&2, Authz.Permit>, +dom: List<&2, String>) -> IO(Unit):
  match found:
    case True{}:
      h_domain_write(s, token, who, slug, m, 2, Db.domain_data(Pages.col(dom, 0n), Pages.col(dom, 1n)))
    case False{}:
      redirect(s, token, "/dash/" ++ (slug ++ "?dns=0#domain"), "")

def h_domain_verify2(s: Socket, +token: String, +who: U32, +slug: String, m: Maybe<&2, Authz.Permit>, +dom: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    found : Bool <- Db.dns_txt_has("_slopstack." ++ Pages.col(dom, 0n), "slopstack-verify=" ++ Pages.col(dom, 1n))
    h_domain_verified(Bool.and(found, Bool.not(String.is_empty(Pages.col(dom, 0n)))), s, token, who, slug, m, dom)

def h_domain_verify(s: Socket, +token: String, +who: U32, +slug: String, +blog: U32, m: Maybe<&2, Authz.Permit>) -> IO(Unit):
  match m:
    case None{}:
      fail(s, token, who, 403)
    case Some{+p}:
      do IO<Unit>:
        dom : List<&2, List<&2, String>> <- Db.query(Db.q_blog_domain(), blog, 0, "", token)
        h_domain_verify2(s, token, who, slug, Some{p}, first_row(dom))

def h_domain3(k: Nat, s: Socket, +token: String, +who: U32, +slug: String, +blog: U32, +main: String, +xs: List<&2, Text.Field>, m: Maybe<&2, Authz.Permit>) -> IO(Unit):
  match k:
    case 1n:
      h_domain_set(s, token, who, slug, main, m, Text.form_domain(xs, "domain"))
    case 2n:
      h_domain_verify(s, token, who, slug, blog, m)
    case 3n:
      h_domain_write(s, token, who, slug, m, 3, Db.no_data())
    case _:
      fail(s, token, who, 400)

def save_mode.go_domain(+a: String) -> U32:
  (Bool.to_u32(String.eq(a, "set")) + ((2 * Bool.to_u32(String.eq(a, "verify"))) + (3 * Bool.to_u32(String.eq(a, "remove")))) : U32)

def h_domain2(s: Socket, +token: String, +who: U32, +slug: String, +main: String, +xs: List<&2, Text.Field>, +blog: U32) -> IO(Unit):
  do IO<Unit>:
    f : Spec.Facts <- Db.facts(who, blog, 0)
    h_domain3(U32.to_nat(save_mode.go_domain(Maybe.default(&2, String, Text.form_raw(xs, "action"), ""))), s, token, who, slug, blog, main, xs, Authz.authorize(f, Spec.EditBlog{blog}))

def h_domain(s: Socket, +token: String, +who: U32, +slug: String, +body: String, +main: String) -> IO(Unit):
  do IO<Unit>:
    blog : List<&2, List<&2, String>> <- blog_rows(token, slug)
    h_domain2(s, token, who, slug, main, form(body), num(first_col(blog, 0n)))

# GET /_domain?domain=X: Caddy asks before getting a certificate for a
# host (on-demand TLS); only verified custom domains are allowed.
def h_domain_ask2(s: Socket, +token: String, +rows: List<&2, List<&2, String>>) -> IO(Unit):
  match rows:
    case Nil{}:
      send_text(s, token, 404, "unknown domain\n")
    case Con{r, t}:
      send_text(s, token, 200, "ok\n")

def h_domain_ask(s: Socket, +token: String, +query: String) -> IO(Unit):
  do IO<Unit>:
    rows : List<&2, List<&2, String>> <- Db.query(Db.q_blog_by_domain(), 0, 0, Maybe.default(&2, String, Text.decode_of(Text.form_get(form(query), "domain")), ""), token)
    h_domain_ask2(s, token, rows)

# The site's host (its origin without the scheme).
def main_host(+origin: String) -> String:
  String.drop(origin, U32.to_nat(((Bool.to_u32(String.starts_with(origin, "https://")) * 8) + (Bool.to_u32(String.starts_with(origin, "http://")) * 7) : U32)))

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

def scheduled_fail(bad_time: Bool, s: Socket, +token: String, +who: U32, +code: U32) -> IO(Unit):
  match bad_time:
    case True{}:
      fail(s, token, who, 400)
    case False{}:
      fail(s, token, who, apply_status(code))

# SCHEDULING: flag 2 sets when (and the address it will take, from its
# title), flag 3 cancels. A time not in the future is refused (400).
def scheduled_done(s: Socket, +token: String, +who: U32, +pid: U32, r: Result<&1, &1, U32 & String, U32>) -> IO(Unit):
  match r:
    case Done{id}:
      redirect(s, token, "/edit/" ++ U32.show(pid), "")
    case Fail{err}:
      (+code, msg) = err
      scheduled_fail(U32.is_eq(code, 3), s, token, who, code)

def schedule_data.go(m: Maybe<&2, Text.Slug>, +minutes: U32) -> Db.WData:
  match m:
    case None{}:
      Db.no_data()
    case Some{sl}:
      Db.schedule_data(sl, minutes)

def h_schedule2(s: Socket, +token: String, +who: U32, +pid: U32, +flag: U32, +minutes: U32, m: Maybe<&2, Authz.Permit>) -> IO(Unit):
  match m:
    case None{}:
      fail(s, token, who, 403)
    case Some{p}:
      do IO<Unit>:
        md : List<&2, List<&2, String>> <- Db.query(Db.q_post_md(), pid, 0, "", token)
        r : Result<&1, &1, U32 & String, U32> <- Db.apply(token, p, flag, schedule_data.go(Text.mk_slug(Text.slugify(first_col(md, 1n))), minutes))
        scheduled_done(s, token, who, pid, r)

def h_schedule(s: Socket, +token: String, +who: U32, +pid: U32, +flag: U32, +minutes: U32) -> IO(Unit):
  do IO<Unit>:
    f : Spec.Facts <- Db.facts(who, 0, pid)
    h_schedule2(s, token, who, pid, flag, minutes, Authz.authorize(f, Spec.PublishPost{pid}))

def h_after_save(k: Nat, s: Socket, +token: String, +who: U32, +pid: U32, +minutes: U32) -> IO(Unit):
  match k:
    case 1n:
      h_publish(s, token, who, pid, 1)
    case 2n:
      h_schedule(s, token, who, pid, 2, minutes)
    case 3n:
      h_schedule(s, token, who, pid, 3, 0)
    case _:
      redirect(s, token, "/edit/" ++ U32.show(pid), "")

# After saving: publish too if that is what the button said. Publishing
# needs its own Permit (PublishPost), checked on fresh facts.
# After saving, by the button pressed (mode): 0 save, 1 publish, 2
# schedule (at minutes since 1970), 3 cancel the schedule. Each of 1-3
# needs its own PublishPost permit, on fresh facts.
def h_save3(+mode: U32, s: Socket, +token: String, +who: U32, +pid: U32, +minutes: U32, r: Result<&1, &1, U32 & String, U32>) -> IO(Unit):
  match r:
    case Done{id}:
      h_after_save(U32.to_nat(mode), s, token, who, pid, minutes)
    case Fail{err}:
      (code, msg) = err
      fail(s, token, who, apply_status(code))

def h_save.run(+mode: U32, +minutes: U32, s: Socket, +token: String, +who: U32, +pid: U32, m: Maybe<&2, Authz.Permit>, +flag: U32, d: Db.WData) -> IO(Unit):
  match m:
    case None{}:
      fail(s, token, who, 403)
    case Some{p}:
      do IO<Unit>:
        r : Result<&1, &1, U32 & String, U32> <- Db.apply(token, p, flag, d)
        h_save3(mode, s, token, who, pid, minutes, r)

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

def h_save2(+mode: U32, +minutes: U32, s: Socket, +token: String, +who: U32, +pid: U32, title: Maybe<&2, Text.Title>, body: Maybe<&2, Text.Body>, +tags: Maybe<&2, String>) -> IO(Unit):
  match title body:
    case Some{ti} Some{+bo}:
      do IO<Unit>:
        f : Spec.Facts <- Db.facts(who, 0, pid)
        h_save.run(mode, minutes, s, token, who, pid, Authz.authorize(f, Spec.EditPost{pid}), save_flag(tags), save_data(ti, bo, tags))
    case _ _:
      fail(s, token, who, 400)

def ops_text(m: Maybe<&2, List<&2, Crdt.Op>>) -> String:
  match m:
    case None{}:
      ""
    case Some{+xs}:
      Crdt.text(xs)

# The editor's button: 1 publish, 2 schedule, 3 unschedule, 0 save.
def save_mode.go(+a: String) -> U32:
  (Bool.to_u32(String.eq(a, "publish")) + ((2 * Bool.to_u32(String.eq(a, "schedule"))) + (3 * Bool.to_u32(String.eq(a, "unschedule")))) : U32)

def save_mode(+xs: List<&2, Text.Field>) -> U32:
  save_mode.go(Maybe.default(&2, String, Text.form_raw(xs, "action"), ""))

def schedule_minutes.pick(js: Bool, +at: U32, +xs: List<&2, Text.Field>) -> U32:
  match js:
    case True{}:
      at
    case False{}:
      Text.minutes_of(Maybe.default(&2, String, Text.decode_of(Text.form_get(xs, "at_local")), ""))

# When to publish: "at" (minutes since 1970, set by the editor's script
# from the local time), else "at_local" read as UTC (without JavaScript).
def schedule_minutes.go(+at: U32, +xs: List<&2, Text.Field>) -> U32:
  schedule_minutes.pick(U32.is_ne(at, 0), at, xs)

def schedule_minutes(+xs: List<&2, Text.Field>) -> U32:
  schedule_minutes.go(form_num(xs, "at"), xs)

def h_save.pick(none: Bool, s: Socket, +token: String, +who: U32, +pid: U32, +xs: List<&2, Text.Field>, +wire: String) -> IO(Unit):
  match none:
    case True{}:
      h_save2(save_mode(xs), schedule_minutes(xs), s, token, who, pid, Text.form_title(xs, "title"), Text.form_body(xs, "body"), Text.decode_of(Text.form_get(xs, "tags")))
    case False{}:
      h_save2(save_mode(xs), schedule_minutes(xs), s, token, who, pid, Text.form_title(xs, "title"), Text.body_of(Some{ops_text(Crdt.decode(wire))}), Text.decode_of(Text.form_get(xs, "tags")))

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

# CO-AUTHORS: without Datastar back to the blog's page; with it the list
# is patched in place, and a refusal is said next to the form.
def author_note(frag: Bool, s: Socket, +token: String, +who: U32, +status: U32, +msg: String) -> IO(Unit):
  match frag:
    case True{}:
      stream1(s, token, Pages.patch("#add-author-note", "inner", msg))
    case False{}:
      fail(s, token, who, status)

def authors_patch(s: Socket, +token: String, +bslug: String, +blog: U32) -> IO(Unit):
  do IO<Unit>:
    rows : List<&2, List<&2, String>> <- Db.query(Db.q_authors(), blog, 0, "", token)
    stream1(s, token, Pages.patch("", "outer", Pages.people_list(bslug, True{}, rows)) ++ Pages.patch("", "replace", Pages.owner_tools(True{}, bslug)))

def authors_done.ok(frag: Bool, s: Socket, +token: String, +bslug: String, +blog: U32) -> IO(Unit):
  match frag:
    case True{}:
      authors_patch(s, token, bslug, blog)
    case False{}:
      redirect(s, token, "/dash/" ++ bslug, "")

def authors_done(frag: Bool, s: Socket, +token: String, +who: U32, +bslug: String, +blog: U32, r: Result<&1, &1, U32 & String, U32>) -> IO(Unit):
  match r:
    case Done{id}:
      authors_done.ok(frag, s, token, bslug, blog)
    case Fail{err}:
      (+code, msg) = err
      author_note(frag, s, token, who, apply_status(code), "That did not work (only the blog's owner manages its authors, and they cannot be added twice).")

def authors_write(frag: Bool, s: Socket, +token: String, +who: U32, +bslug: String, +blog: U32, m: Maybe<&2, Authz.Permit>) -> IO(Unit):
  match m:
    case None{}:
      author_note(frag, s, token, who, 403, "Only the blog's owner manages its authors.")
    case Some{p}:
      do IO<Unit>:
        r : Result<&1, &1, U32 & String, U32> <- Db.apply(token, p, 0, Db.no_data())
        authors_done(frag, s, token, who, bslug, blog, r)

def h_add_author4(none: Bool, frag: Bool, s: Socket, +token: String, +who: U32, +blog: U32, +bslug: String, +uid: U32) -> IO(Unit):
  match none:
    case True{}:
      author_note(frag, s, token, who, 400, "No account uses that email yet: they need to sign up first.")
    case False{}:
      do IO<Unit>:
        f : Spec.Facts <- Db.facts(who, blog, 0)
        authors_write(frag, s, token, who, bslug, blog, Authz.authorize(f, Spec.AddAuthor{blog, uid}))

def h_add_author3(frag: Bool, s: Socket, +token: String, +who: U32, +blog: U32, +bslug: String, +users: List<&2, List<&2, String>>) -> IO(Unit):
  +uid = num(first_col(users, 0n))
  h_add_author4(U32.is_eq(uid, 0), frag, s, token, who, blog, bslug, uid)

def h_add_author2(frag: Bool, s: Socket, +token: String, +who: U32, +bslug: String, +blog: U32, email: Maybe<&2, Text.Title>) -> IO(Unit):
  match email:
    case None{}:
      author_note(frag, s, token, who, 400, "Enter their email address.")
    case Some{em}:
      do IO<Unit>:
        users : List<&2, List<&2, String>> <- Db.query(Db.q_user_by_email(), 0, 0, Text.Title.text(em), token)
        h_add_author3(frag, s, token, who, blog, bslug, users)

def h_add_author.go(frag: Bool, s: Socket, +token: String, +who: U32, +bslug: String, +xs: List<&2, Text.Field>) -> IO(Unit):
  do IO<Unit>:
    blog : List<&2, List<&2, String>> <- blog_rows(token, bslug)
    h_add_author2(frag, s, token, who, bslug, num(first_col(blog, 0n)), Text.form_title(xs, "email"))

def h_add_author(s: Socket, +token: String, +who: U32, +bslug: String, +body: String, +query: String) -> IO(Unit):
  +xs = form(body)
  h_add_author.go(frag_of(query, body), s, token, who, bslug, xs)

def h_remove_author(s: Socket, +token: String, +who: U32, +bslug: String, +uid: U32, +query: String) -> IO(Unit):
  do IO<Unit>:
    blog : List<&2, List<&2, String>> <- blog_rows(token, bslug)
    +id : U32 = num(first_col(blog, 0n))
    f : Spec.Facts <- Db.facts(who, id, 0)
    authors_write(wants_frag(form(query)), s, token, who, bslug, id, Authz.authorize(f, Spec.RemoveAuthor{id, uid}))

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

def page_num.clamp(+n: U32) -> U32:
  (U32.max(1, U32.min(n, 1000)) : U32)

# FEED PAGES (cached): a blog, a tag, an author. 30 posts a page
# (?page=N, at most 1000); the query fetches 31 to know if there are more.
def page_num(+query: String) -> U32:
  page_num.clamp(form_num(form(query), "page"))

def page_key(+page: U32) -> String:
  "?" ++ U32.show(page)

def page_offset(+page: U32) -> U32:
  ((page - 1) * 30 : U32)

# FEEDS, SEARCH (cached; Datastar's ?frag=1 answers are cached apart)
# ---------------------------------------------------------------------
# Each feed page: a page of 30, or with frag the next 30 appended and the
# pager moved on (Pages.feed_more). Keys: kind, signed in or not, the
# thing, the page, and "&f" for fragments.
def frag_key(+frag: Bool) -> String:
  match frag:
    case True{}:
      "&f"
    case False{}:
      ""

# page and more are functions, so only the one sent is rendered (Bend is
# strict); page renders the body in front of the text it is given, so the
# rows are never copied by an append.
def feed_send(frag: Bool, s: Socket, +key: String, +title: String, +who: U32, page: String -> String, more: Unit -> String) -> IO(Unit):
  match frag:
    case True{}:
      cache_send_t(s, key, 2, more(Unit{}))
    case False{}:
      cache_send(s, key, Pages.layout_top(title, signed(who)) ++ page(Pages.layout_bottom()))

def h_home2(s: Socket, +token: String, +who: U32, +page: U32, +frag: Bool) -> IO(Unit):
  do IO<Unit>:
    +rows : List<&2, List<&2, String>> <- Db.query(Db.q_recent_public(), 0, page_offset(page), "", token)
    feed_send(frag, s, cache_key("h", who, page_key(page) ++ frag_key(frag)), "Home", who, k => Pages.home_page(rows, signed(who), page, k), u => Pages.feed_more("/", page, rows, j => Pages.recent_items(Pages.rows_take(rows, 30n), j)))

def h_home(s: Socket, +token: String, +who: U32, +query: String) -> IO(Unit):
  do IO<Unit>:
    r : Socket & Result<&1, &1, U32 & String, Unit> <- Db.cached(s, cache_key("h", who, page_key(page_num(query)) ++ frag_key(wants_frag(form(query)))))
    cached_or(r, s2 => h_home2(s2, token, who, page_num(query), wants_frag(form(query))))

def h_blog2(s: Socket, +token: String, +who: U32, +page: U32, +frag: Bool, +blog: List<&2, List<&2, String>>) -> IO(Unit):
  match blog:
    case Nil{}:
      fail(s, token, who, 404)
    case Con{+r, t}:
      do IO<Unit>:
        +rows : List<&2, List<&2, String>> <- Db.query(Db.q_posts_public(), num(Pages.col(r, 0n)), page_offset(page), "", token)
        feed_send(frag, s, cache_key("b", who, Pages.col(r, 2n) ++ (page_key(page) ++ frag_key(frag))), Pages.col(r, 1n), who, k => Pages.blog_page(Pages.col(r, 2n), Pages.col(r, 1n), Pages.col(r, 3n), page, rows, k), u => Pages.feed_more("/b/" ++ Pages.col(r, 2n), page, rows, j => Pages.post_items(Pages.col(r, 2n), Pages.rows_take(rows, 30n), j)))

def h_blog3(s: Socket, +token: String, +who: U32, +slug: String, +page: U32, +frag: Bool) -> IO(Unit):
  do IO<Unit>:
    blog : List<&2, List<&2, String>> <- blog_rows(token, slug)
    h_blog2(s, token, who, page, frag, blog)

def h_blog(s: Socket, +token: String, +who: U32, +slug: String, +query: String) -> IO(Unit):
  do IO<Unit>:
    r : Socket & Result<&1, &1, U32 & String, Unit> <- Db.cached(s, cache_key("b", who, slug ++ (page_key(page_num(query)) ++ frag_key(wants_frag(form(query))))))
    cached_or(r, s2 => h_blog3(s2, token, who, slug, page_num(query), wants_frag(form(query))))

def h_tag2(s: Socket, +token: String, +who: U32, +tag: String, +page: U32, +frag: Bool) -> IO(Unit):
  do IO<Unit>:
    +rows : List<&2, List<&2, String>> <- Db.query(Db.q_posts_by_tag(), 0, page_offset(page), tag, token)
    feed_send(frag, s, cache_key("t", who, tag ++ (page_key(page) ++ frag_key(frag))), "#" ++ tag, who, k => Pages.tag_page(tag, page, rows, k), u => Pages.feed_more("/t/" ++ tag, page, rows, j => Pages.recent_items(Pages.rows_take(rows, 30n), j)))

def h_tag(s: Socket, +token: String, +who: U32, +tag: String, +query: String) -> IO(Unit):
  do IO<Unit>:
    r : Socket & Result<&1, &1, U32 & String, Unit> <- Db.cached(s, cache_key("t", who, tag ++ (page_key(page_num(query)) ++ frag_key(wants_frag(form(query))))))
    cached_or(r, s2 => h_tag2(s2, token, who, tag, page_num(query), wants_frag(form(query))))

def h_author3(s: Socket, +token: String, +who: U32, +uid: U32, +page: U32, +frag: Bool, +name: List<&2, List<&2, String>>) -> IO(Unit):
  match name:
    case Nil{}:
      fail(s, token, who, 404)
    case Con{+r, t}:
      do IO<Unit>:
        +rows : List<&2, List<&2, String>> <- Db.query(Db.q_posts_by_author(), uid, page_offset(page), "", token)
        feed_send(frag, s, cache_key("u", who, U32.show(uid) ++ (page_key(page) ++ frag_key(frag))), Pages.col(r, 0n), who, k => Pages.author_page(U32.show(uid), Pages.col(r, 0n), Pages.col(r, 1n), page, rows, k), u => Pages.feed_more("/u/" ++ U32.show(uid), page, rows, j => Pages.recent_items(Pages.rows_take(rows, 30n), j)))

def h_author2(s: Socket, +token: String, +who: U32, +uid: U32, +page: U32, +frag: Bool) -> IO(Unit):
  do IO<Unit>:
    name : List<&2, List<&2, String>> <- Db.query(Db.q_author_public(), uid, 0, "", token)
    h_author3(s, token, who, uid, page, frag, name)

def h_author(s: Socket, +token: String, +who: U32, +uid: U32, +query: String) -> IO(Unit):
  do IO<Unit>:
    r : Socket & Result<&1, &1, U32 & String, Unit> <- Db.cached(s, cache_key("u", who, U32.show(uid) ++ (page_key(page_num(query)) ++ frag_key(wants_frag(form(query))))))
    cached_or(r, s2 => h_author2(s2, token, who, uid, page_num(query), wants_frag(form(query))))

# SEARCH: /search?q=... Results are cached like feeds (the key is the
# sanitized query; a long one is simply not cached). With frag (as you
# type): just #results.
def search_send(frag: Bool, s: Socket, +key: String, +who: U32, +q: String, +rows: List<&2, List<&2, String>>) -> IO(Unit):
  match frag:
    case True{}:
      cache_send_t(s, key, 2, Pages.patch("", "outer", Pages.results_div(q, rows)))
    case False{}:
      cache_send(s, key, Pages.layout("Search: " ++ q, signed(who), Pages.search_page(q, rows)))

def h_search3(s: Socket, +token: String, +who: U32, +q: String, +fq: String, +frag: Bool) -> IO(Unit):
  do IO<Unit>:
    +rows : List<&2, List<&2, String>> <- Db.query(Db.q_search(), 0, 0, fq, token)
    search_send(frag, s, cache_key("s", who, fq ++ frag_key(frag)), who, q, rows)

def h_search_empty(frag: Bool, s: Socket, +token: String, +who: U32, +q: String) -> IO(Unit):
  match frag:
    case True{}:
      stream1(s, token, Pages.patch("", "outer", Pages.results_div("", Nil{})))
    case False{}:
      send(s, token, 200, Pages.layout("Search", signed(who), Pages.search_page(q, Nil{})))

def h_search2(empty: Bool, s: Socket, +token: String, +who: U32, +q: String, +fq: String, +frag: Bool) -> IO(Unit):
  match empty:
    case True{}:
      h_search_empty(frag, s, token, who, q)
    case False{}:
      do IO<Unit>:
        r : Socket & Result<&1, &1, U32 & String, Unit> <- Db.cached(s, cache_key("s", who, fq ++ frag_key(frag)))
        cached_or(r, s2 => h_search3(s2, token, who, q, fq, frag))

def h_search.go(s: Socket, +token: String, +who: U32, +q: String, +frag: Bool) -> IO(Unit):
  +fq = Text.fts_query(q)
  h_search2(String.is_empty(fq), s, token, who, q, fq, frag)

def h_search(s: Socket, +token: String, +who: U32, +query: String) -> IO(Unit):
  h_search.go(s, token, who, String.take(Maybe.default(&2, String, Text.decode_of(Text.form_get(form(query), "q")), ""), 200n), wants_frag(form(query)))

# USERNAME CHECK (sign-up, as you type): GET /handle?h=... answers a note
# for #handle-note. Handles are public, so saying one is taken reveals
# nothing an author page would not.
def handle_note(k: Nat, +h: String) -> String:
  match k:
    case 1n:
      "<span class=\"ok\">@" ++ (Pages.e(h) ++ " is free</span>")
    case 2n:
      "<span class=\"bad\">@" ++ (Pages.e(h) ++ " is taken</span>")
    case _:
      "3 to 30 of a-z, 0-9 and _, starting with a letter"

def h_handle3(s: Socket, +token: String, +h: String, +rows: List<&2, List<&2, String>>) -> IO(Unit):
  match rows:
    case Nil{}:
      stream1(s, token, Pages.patch("#handle-note", "inner", handle_note(1n, h)))
    case Con{r, t}:
      stream1(s, token, Pages.patch("#handle-note", "inner", handle_note(2n, h)))

def h_handle2(s: Socket, +token: String, m: Maybe<&2, Text.Handle>) -> IO(Unit):
  match m:
    case None{}:
      stream1(s, token, Pages.patch("#handle-note", "inner", handle_note(0n, "")))
    case Some{+x}:
      do IO<Unit>:
        rows : List<&2, List<&2, String>> <- Db.query(Db.q_handle_taken(), 0, 0, Text.Handle.text(x), token)
        h_handle3(s, token, Text.Handle.text(x), rows)

def h_handle(s: Socket, +token: String, +query: String) -> IO(Unit):
  h_handle2(s, token, Text.form_handle(form(query), "h"))

# DISPATCH
# --------
def read(s: Socket, r: Route.Route, +token: String, +who: U32, +query: String, +origin: String) -> IO(Unit):
  match r:
    case Route.RFeed{}:
      h_feed(s, token, origin)
    case Route.RDomainAsk{}:
      h_domain_ask(s, token, query)
    case Route.RToMain{+p}:
      redirect(s, token, origin ++ p, "")
    case Route.RSearch{}:
      h_search(s, token, who, query)
    case Route.RHandle{}:
      h_handle(s, token, query)
    case Route.RReply{+id}:
      h_reply(s, token, who, id, query)
    case Route.RLive{+id}:
      h_live(s, token, who, id, query)
    case Route.RTag{+t}:
      h_tag(s, token, who, t, query)
    case Route.RImage{+k}:
      do IO<Unit>:
        r : Socket & Result<&1, &1, U32 & String, Unit> <- Db.image(s, k)
        done(r)
    case Route.RBlogFeed{+b}:
      h_blog_feed(s, token, origin, b)
    case Route.RHome{}:
      h_home(s, token, who, query)
    case Route.RHealth{}:
      send_text(s, token, 200, "ok\n")
    case Route.RBlog{+slug}:
      h_blog(s, token, who, slug, query)
    case Route.RPost{+b, +p}:
      h_post(s, token, who, b, p, query)
    case Route.RAuthor{+id}:
      h_author(s, token, who, id, query)
    case Route.RDash{}:
      h_dash(s, token, who)
    case Route.RDashBlog{+slug}:
      h_dash_blog(s, token, who, slug, query, main_host(origin))
    case Route.REdit{+id}:
      h_edit(s, token, who, id)
    case Route.RStatic{+name}:
      h_static(U32.to_nat((Bool.to_u32(String.eq(name, "editor.js")) + ((2 * Bool.to_u32(String.eq(name, "app.css"))) + ((3 * Bool.to_u32(String.eq(name, "passkey.js"))) + (4 * Bool.to_u32(String.eq(name, "datastar.js"))))) : U32)), s, token, who)
    case Route.RSignupPage{}:
      Auth.h_signup_page(s, token, who)
    case Route.RLoginPage{}:
      Auth.h_login_page(s, token, who)
    case Route.RVerify{}:
      Auth.h_verify(s, token, query)
    case _:
      fail(s, token, who, 404)

def write_route(s: Socket, r: Route.Route, +c: Auth.Conf, +token: String, +who: U32, +body: String, +query: String) -> IO(Unit):
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
      h_add_author(s, token, who, b, body, query)
    case Route.RRemoveAuthor{+b, +u}:
      h_remove_author(s, token, who, b, u, query)
    case Route.RLogout{}:
      h_logout(s, token)
    case Route.RWrite{}:
      h_write(s, token, who)
    case Route.RLike{+id}:
      h_like(s, token, who, id, body, query)
    case Route.RUpload{+id}:
      h_upload(s, token, who, id, body)
    case Route.RBlogDomain{+b}:
      h_domain(s, token, who, b, body, main_host(Auth.origin(c)))
    case Route.RComment{+id}:
      h_comment(s, token, who, id, body, query)
    case Route.RDeleteComment{+id}:
      h_delete_comment(s, token, who, id, query)
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
      write_route(s, r, c, token, who, body, query)
    case Route.Deny{+status}:
      fail(s, token, who, status)
