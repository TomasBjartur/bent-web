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
def h_home(s: Socket, +token: String, +who: U32) -> IO(Unit):
  do IO<Unit>:
    rows : List<&2, List<&2, String>> <- Db.query(Db.q_recent_public(), 0, 0, "", token)
    send(s, token, 200, Pages.layout("Home", signed(who), Pages.home_page(rows, signed(who))))

def h_blog2(s: Socket, +token: String, +who: U32, +blog: List<&2, List<&2, String>>) -> IO(Unit):
  match blog:
    case Nil{}:
      fail(s, token, who, 404)
    case Con{+r, t}:
      do IO<Unit>:
        rows : List<&2, List<&2, String>> <- Db.query(Db.q_posts_public(), num(Pages.col(r, 0n)), 0, "", token)
        send(s, token, 200, Pages.layout(Pages.col(r, 1n), signed(who), Pages.blog_page(Pages.col(r, 2n), Pages.col(r, 1n), Pages.col(r, 3n), rows)))

def h_blog(s: Socket, +token: String, +who: U32, +slug: String) -> IO(Unit):
  do IO<Unit>:
    blog : List<&2, List<&2, String>> <- blog_rows(token, slug)
    h_blog2(s, token, who, blog)

def is_some_permit(m: Maybe<&2, Authz.Permit>) -> Bool:
  match m:
    case None{}:
      False{}
    case Some{p}:
      True{}

# The post page: the stored body is spliced in by C (with its own floor).
# Members see an Edit link (only if they could open the editor).
def h_post4(s: Socket, +token: String, +who: U32, +pid: U32, +can_edit: Bool, +view: List<&2, List<&2, String>>) -> IO(Unit):
  match view:
    case Nil{}:
      fail(s, token, who, 404)
    case Con{+r, t}:
      do IO<Unit>:
        x : Socket & Result<&1, &1, U32 & String, Unit> <- Db.page(s, 200, 0, two(Pages.layout_top(Pages.col(r, 1n), signed(who)) ++ Pages.post_before(r, U32.show(pid), can_edit), Pages.post_after(r) ++ Pages.layout_bottom()), Con{pid, Nil{}}, token, "", "")
        done(x)

def h_post3(s: Socket, +token: String, +who: U32, +pid: U32, +can_edit: Bool, m: Maybe<&2, Authz.Permit>) -> IO(Unit):
  match m:
    case None{}:
      fail(s, token, who, 404)
    case Some{p}:
      do IO<Unit>:
        view : List<&2, List<&2, String>> <- Db.query(Db.q_post_view(), pid, 0, "", token)
        h_post4(s, token, who, pid, can_edit, view)

def h_post2(s: Socket, +token: String, +who: U32, +pid: U32) -> IO(Unit):
  do IO<Unit>:
    +f : Spec.Facts <- Db.facts(who, 0, pid)
    h_post3(s, token, who, pid, is_some_permit(Authz.authorize(f, Spec.EditPost{pid})), Authz.authorize(f, Spec.ReadPost{pid}))

def h_post(s: Socket, +token: String, +who: U32, +bslug: String, +pslug: String) -> IO(Unit):
  do IO<Unit>:
    blog : List<&2, List<&2, String>> <- blog_rows(token, bslug)
    ids : List<&2, List<&2, String>> <- Db.query(Db.q_post_id(), num(first_col(blog, 0n)), 0, pslug, token)
    h_post2(s, token, who, num(first_col(ids, 0n)))

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
        send(s, token, 200, Pages.edit_page(U32.show(pid), U32.show(rep_of(rh)), r))

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

def form(+body: String) -> List<&2, Text.Field>:
  Maybe.default(&2, List<&2, Text.Field>, Text.form_parse(body), Nil{})

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

def h_create_post.go(s: Socket, +token: String, +who: U32, +bslug: String, +xs: List<&2, Text.Field>) -> IO(Unit):
  do IO<Unit>:
    blog : List<&2, List<&2, String>> <- blog_rows(token, bslug)
    h_create_post2(s, token, who, num(first_col(blog, 0n)), Text.form_slug_or(xs, "slug", "title"), Text.form_title(xs, "title"))

def h_create_post(s: Socket, +token: String, +who: U32, +bslug: String, +body: String) -> IO(Unit):
  +xs = form(body)
  h_create_post.go(s, token, who, bslug, xs)

def h_publish(s: Socket, +token: String, +who: U32, +pid: U32, +flag: U32) -> IO(Unit):
  do IO<Unit>:
    f : Spec.Facts <- Db.facts(who, 0, pid)
    write(s, token, who, Authz.authorize(f, Spec.PublishPost{pid}), flag, Db.no_data(), "/edit/" ++ U32.show(pid))

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

def h_save.run(publish: Bool, s: Socket, +token: String, +who: U32, +pid: U32, m: Maybe<&2, Authz.Permit>, d: Db.WData) -> IO(Unit):
  match m:
    case None{}:
      fail(s, token, who, 403)
    case Some{p}:
      do IO<Unit>:
        r : Result<&1, &1, U32 & String, U32> <- Db.apply(token, p, 0, d)
        h_save3(publish, s, token, who, pid, r)

def h_save2(publish: Bool, s: Socket, +token: String, +who: U32, +pid: U32, title: Maybe<&2, Text.Title>, body: Maybe<&2, Text.Body>) -> IO(Unit):
  match title body:
    case Some{ti} Some{+bo}:
      do IO<Unit>:
        f : Spec.Facts <- Db.facts(who, 0, pid)
        h_save.run(publish, s, token, who, pid, Authz.authorize(f, Spec.EditPost{pid}), Db.post_data(ti, bo))
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
      h_save2(wants_publish(xs), s, token, who, pid, Text.form_title(xs, "title"), Text.form_body(xs, "body"))
    case False{}:
      h_save2(wants_publish(xs), s, token, who, pid, Text.form_title(xs, "title"), Text.body_of(Some{ops_text(Crdt.decode(wire))}))

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

# COLLABORATIVE EDITING
# ---------------------
def form_num(+xs: List<&2, Text.Field>, +key: String) -> U32:
  Maybe.default(&2, U32, U32.read(Maybe.default(&2, String, Text.form_raw(xs, key), "")), 0)

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
def read(s: Socket, r: Route.Route, +token: String, +who: U32, +query: String) -> IO(Unit):
  match r:
    case Route.RHome{}:
      h_home(s, token, who)
    case Route.RHealth{}:
      send_text(s, token, 200, "ok\n")
    case Route.RBlog{+slug}:
      h_blog(s, token, who, slug)
    case Route.RPost{+b, +p}:
      h_post(s, token, who, b, p)
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
      read(s, r, token, who, query)
    case Route.Write{r}:
      write_route(s, r, c, token, who, body)
    case Route.Deny{+status}:
      fail(s, token, who, status)
