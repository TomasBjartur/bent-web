# HTML pages. Pure. Every dynamic string goes through Html.esc (proved safe:
# LAWS.bend html_esc_safe), including slugs and ids in attributes.
#
# Styles: src/web/app.css, served at /s/app.css?v=<asset version> with
# immutable caching. No inline styles or scripts (the CSP forbids them).
import Base
import ./html.bend as Html
import ./gen/version.bend as Ver

# A row from a query: its columns as strings.
def col(r: List<&2, String>, n: Nat) -> String:
  match r:
    case Nil{}:
      ""
    case Con{x, t}:
      match n:
        case 0n:
          x
        case 1n+p:
          col(t, p)

def e(s: String) -> String:
  Html.esc(s, "")

def asset(+name: String) -> String:
  "/s/" ++ (name ++ ("?v=" ++ Ver.asset_version()))

# LAYOUT
# ------

def nav(b: Bool) -> String:
  match b:
    case True{}:
      "<a href=\"/\" class=\"hide-sm\">Home</a><a href=\"/dash\">Your blogs</a><form method=\"post\" action=\"/logout\"><button class=\"link\">Log out</button></form><a class=\"btn primary\" href=\"/dash\">Write</a>"
    case False{}:
      "<a href=\"/login\">Log in</a><a class=\"btn primary\" href=\"/signup\">Start writing</a>"

def head(+title: String) -> String:
  "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><meta name=\"color-scheme\" content=\"light dark\"><title>" ++ (e(title) ++ (" · slopstack</title><link rel=\"stylesheet\" href=\"" ++ (asset("app.css") ++ "\"></head><body><a class=\"skip\" href=\"#main\">Skip to content</a>")))

def top(signed_in: Bool) -> String:
  "<header class=\"top\"><div class=\"wrap wide\"><a class=\"brand\" href=\"/\">slop<span>stack</span></a><nav>" ++ (nav(signed_in) ++ "</nav></div></header>")

def width(wide: Bool) -> String:
  match wide:
    case True{}:
      "wrap wide"
    case False{}:
      "wrap"

def layout_top_w(+title: String, signed_in: Bool, wide: Bool) -> String:
  head(title) ++ (top(signed_in) ++ ("<main id=\"main\"><div class=\"" ++ (width(wide) ++ "\">")))

def layout_top(+title: String, signed_in: Bool) -> String:
  layout_top_w(title, signed_in, False{})

def layout_bottom() -> String:
  "</div></main></body></html>\n"

def layout(+title: String, signed_in: Bool, body: String) -> String:
  layout_top(title, signed_in) ++ (body ++ layout_bottom())

def layout_wide(+title: String, signed_in: Bool, body: String) -> String:
  layout_top_w(title, signed_in, True{}) ++ (body ++ layout_bottom())

# DATES AND COUNTS
# ----------------

def month.go(k: Nat) -> String:
  match k:
    case 1n:
      "Jan"
    case 2n:
      "Feb"
    case 3n:
      "Mar"
    case 4n:
      "Apr"
    case 5n:
      "May"
    case 6n:
      "Jun"
    case 7n:
      "Jul"
    case 8n:
      "Aug"
    case 9n:
      "Sep"
    case 10n:
      "Oct"
    case 11n:
      "Nov"
    case 12n:
      "Dec"
    case _:
      ""

def num(+s: String) -> U32:
  Maybe.default(&2, U32, U32.read(s), 0)

def month(+m: String) -> String:
  month.go(U32.to_nat(num(m)))

# "2026-09-26" as "Sep 26, 2026". The input comes from SQLite's strftime.
def date(+d: String) -> String:
  month(String.take(String.drop(d, 5n), 2n)) ++ (" " ++ (U32.show(num(String.drop(d, 8n))) ++ (", " ++ e(String.take(d, 4n)))))

def minutes(+m: String) -> String:
  e(m) ++ " min read"

def plural.go(b: Bool, +n: String, one: String, many: String) -> String:
  match b:
    case True{}:
      e(n) ++ (" " ++ one)
    case False{}:
      e(n) ++ (" " ++ many)

def plural(+n: String, one: String, many: String) -> String:
  plural.go(String.eq(n, "1"), n, one, many)

# ERRORS
# ------

def error_kind(+status: U32) -> Nat:
  U32.to_nat((Bool.to_u32(U32.is_eq(status, 404)) + ((2 * Bool.to_u32(U32.is_eq(status, 403))) + ((3 * Bool.to_u32(U32.is_eq(status, 409))) + (4 * Bool.to_u32(U32.is_eq(status, 400))))) : U32))

def error_title.go(k: Nat) -> String:
  match k:
    case 1n:
      "Page not found"
    case 2n:
      "Not allowed"
    case 3n:
      "That did not work"
    case 4n:
      "Please check the form"
    case _:
      "Something went wrong"

def error_pick(k: Nat) -> String:
  match k:
    case 1n:
      "It may have been moved, unpublished, or never existed."
    case 2n:
      "You may need to log in, or this belongs to someone else."
    case 3n:
      "That address may be taken, or something changed in the meantime. Go back and try again."
    case 4n:
      "Something in it was missing or not allowed. Go back and check it."
    case _:
      "Please try again in a moment."

def error_title(+status: U32) -> String:
  error_title.go(error_kind(status))

def error_text(+status: U32) -> String:
  error_pick(error_kind(status))

def error_body(+status: U32) -> String:
  "<div class=\"center card\"><h1>" ++ (error_title(status) ++ ("</h1><p class=\"muted\">" ++ (error_text(status) ++ "</p><p><a class=\"btn\" href=\"/\">Go home</a></p></div>")))

# FEEDS
# -----

def meta3(+a: String, +b: String, +c: String) -> String:
  "<div class=\"meta\">" ++ (e(a) ++ ("<span class=\"dot\"></span>" ++ (date(b) ++ ("<span class=\"dot\"></span>" ++ (minutes(c) ++ "</div>")))))

# Recent posts: [blog slug, post slug, title, blog title, author, date,
# excerpt, minutes]. The excerpt is clipped to two lines by CSS.
def recent_items(rows: List<&2, List<&2, String>>) -> String:
  match rows:
    case Nil{}:
      ""
    case Con{+r, t}:
      "<li><a class=\"pub\" href=\"/b/" ++ (e(col(r, 0n)) ++ ("\">" ++ (e(col(r, 3n)) ++ ("</a><h3><a href=\"/b/" ++ (e(col(r, 0n)) ++ ("/" ++ (e(col(r, 1n)) ++ ("\">" ++ (e(col(r, 2n)) ++ ("</a></h3><p class=\"excerpt\">" ++ (e(col(r, 6n)) ++ ("</p>" ++ (meta3(col(r, 4n), col(r, 5n), col(r, 7n)) ++ ("</li>" ++ recent_items(t)))))))))))))))

def intro(signed: Bool) -> String:
  match signed:
    case True{}:
      ""
    case False{}:
      "<section class=\"masthead\"><h1>A quiet place to write</h1><p class=\"lede\">Fast pages, no trackers, no passwords: you sign in with a passkey. Write alone or with co-authors, even offline.</p><a class=\"btn primary big\" href=\"/signup\">Start writing</a></section>"

def feed_or_empty(rows: List<&2, List<&2, String>>, msg: String) -> String:
  match rows:
    case Nil{}:
      "<div class=\"empty\"><p>" ++ (msg ++ "</p></div>")
    case Con{r, t}:
      "<ul class=\"feed\">" ++ (recent_items(Con{r, t}) ++ "</ul>")

def home_page(rows: List<&2, List<&2, String>>, signed: Bool) -> String:
  intro(signed) ++ ("<h2>Recent posts</h2>" ++ feed_or_empty(rows, "Nothing published yet. Be the first!"))

# A blog's posts: [post slug, title, author, date, excerpt, minutes].
def post_items(+bslug: String, rows: List<&2, List<&2, String>>) -> String:
  match rows:
    case Nil{}:
      ""
    case Con{+r, t}:
      "<li><h3><a href=\"/b/" ++ (e(bslug) ++ ("/" ++ (e(col(r, 0n)) ++ ("\">" ++ (e(col(r, 1n)) ++ ("</a></h3><p class=\"excerpt\">" ++ (e(col(r, 4n)) ++ ("</p>" ++ (meta3(col(r, 2n), col(r, 3n), col(r, 5n)) ++ ("</li>" ++ post_items(bslug, t)))))))))))

def blog_feed(+slug: String, rows: List<&2, List<&2, String>>) -> String:
  match rows:
    case Nil{}:
      "<div class=\"empty\"><p>No posts yet.</p></div>"
    case Con{r, t}:
      "<ul class=\"feed\">" ++ (post_items(slug, Con{r, t}) ++ "</ul>")

def blog_page(+slug: String, title: String, owner: String, rows: List<&2, List<&2, String>>) -> String:
  "<header class=\"masthead\"><h1>" ++ (e(title) ++ ("</h1><p class=\"muted\">by " ++ (e(owner) ++ ("</p></header>" ++ blog_feed(slug, rows)))))

# POST (the stored body is spliced in between the two halves)
# ----

def draft_badge(b: Bool) -> String:
  match b:
    case True{}:
      "<span class=\"dot\"></span><span class=\"badge\">Draft: only authors can see this</span>"
    case False{}:
      ""

def edit_link(b: Bool, +id: String) -> String:
  match b:
    case True{}:
      "<span class=\"actions\"><a class=\"btn\" href=\"/edit/" ++ (e(id) ++ "\">Edit</a></span>")
    case False{}:
      ""

# view: [post slug, title, published, blog slug, blog title, author, date,
# minutes].
def post_before(+view: List<&2, String>, +id: String, can_edit: Bool) -> String:
  "<article class=\"article\"><header><a class=\"pub\" href=\"/b/" ++ (e(col(view, 3n)) ++ ("\">" ++ (e(col(view, 4n)) ++ ("</a><h1>" ++ (e(col(view, 1n)) ++ ("</h1><div class=\"byline\"><strong>" ++ (e(col(view, 5n)) ++ ("</strong><span class=\"dot\"></span>" ++ (date(col(view, 6n)) ++ ("<span class=\"dot\"></span>" ++ (minutes(col(view, 7n)) ++ (draft_badge(String.eq(col(view, 2n), "0")) ++ (edit_link(can_edit, id) ++ "</div></header><div class=\"body\">")))))))))))))

def post_after(+view: List<&2, String>) -> String:
  "</div><footer><a href=\"/b/" ++ (e(col(view, 3n)) ++ ("\">← More from " ++ (e(col(view, 4n)) ++ "</a><a href=\"/\">Recent posts</a></footer></article>")))

# DASHBOARD
# ---------

def role_name.go(b: Bool) -> String:
  match b:
    case True{}:
      "Owner"
    case False{}:
      "Author"

def role_name(+r: String) -> String:
  role_name.go(String.eq(r, "1"))

# My blogs: [id, slug, title, role, published count, draft count].
def blog_cards(rows: List<&2, List<&2, String>>) -> String:
  match rows:
    case Nil{}:
      ""
    case Con{+r, t}:
      "<div class=\"card blogcard\"><h3><a href=\"/dash/" ++ (e(col(r, 1n)) ++ ("\">" ++ (e(col(r, 2n)) ++ ("</a></h3><div class=\"meta\">" ++ (role_name(col(r, 3n)) ++ ("<span class=\"dot\"></span>" ++ (plural(col(r, 4n), "post", "posts") ++ ("<span class=\"dot\"></span>" ++ (plural(col(r, 5n), "draft", "drafts") ++ ("</div><div class=\"row\"><a class=\"btn primary\" href=\"/dash/" ++ (e(col(r, 1n)) ++ ("#new\">New post</a><a class=\"btn\" href=\"/dash/" ++ (e(col(r, 1n)) ++ ("\">Manage</a></div></div>" ++ blog_cards(t)))))))))))))))

def new_blog_form() -> String:
  "<form method=\"post\" action=\"/blogs\" class=\"card stack\"><h2>Start a new blog</h2><label>Name <input name=\"title\" required maxlength=\"200\" placeholder=\"The Weekly Thought\"></label><label>Address <span class=\"hint\">Optional: lowercase letters, digits and dashes. Made from the name if empty.</span><input name=\"slug\" maxlength=\"64\" pattern=\"[a-z0-9\\-]*\" placeholder=\"weekly-thought\"></label><div><button class=\"primary\">Create blog</button></div></form>"

def dash_page(rows: List<&2, List<&2, String>>) -> String:
  match rows:
    case Nil{}:
      "<div class=\"dash-head\"><h1>Your blogs</h1></div><div class=\"empty\"><p>You don't have a blog yet. Name it below and start writing.</p></div><div class=\"center\">" ++ (new_blog_form() ++ "</div>")
    case Con{r, t}:
      "<div class=\"dash-head\"><h1>Your blogs</h1></div><div class=\"grid\">" ++ (blog_cards(Con{r, t}) ++ ("</div><div class=\"center\">" ++ (new_blog_form() ++ "</div>")))

def state_badge.go(b: Bool) -> String:
  match b:
    case True{}:
      "<span class=\"badge live\">Published</span>"
    case False{}:
      "<span class=\"badge\">Draft</span>"

def state_badge(+p: String) -> String:
  state_badge.go(String.eq(p, "1"))

def view_link(b: Bool, +bslug: String, +pslug: String) -> String:
  match b:
    case True{}:
      "<a class=\"btn quiet view\" href=\"/b/" ++ (e(bslug) ++ ("/" ++ (e(pslug) ++ "\">View</a>")))
    case False{}:
      ""

# A blog's posts, for members: [id, slug, title, published, date, author].
def member_post_rows(+bslug: String, rows: List<&2, List<&2, String>>) -> String:
  match rows:
    case Nil{}:
      ""
    case Con{+r, t}:
      "<tr><td><a class=\"title\" href=\"/edit/" ++ (e(col(r, 0n)) ++ ("\">" ++ (e(col(r, 2n)) ++ ("</a><div class=\"meta\">" ++ (e(col(r, 5n)) ++ ("<span class=\"dot\"></span>edited " ++ (date(col(r, 4n)) ++ ("</div></td><td>" ++ (state_badge(col(r, 3n)) ++ ("</td><td>" ++ (view_link(String.eq(col(r, 3n), "1"), bslug, col(r, 1n)) ++ ("<a class=\"btn\" href=\"/edit/" ++ (e(col(r, 0n)) ++ ("\">Edit</a></td></tr>" ++ member_post_rows(bslug, t)))))))))))))))

def member_posts(+bslug: String, rows: List<&2, List<&2, String>>) -> String:
  match rows:
    case Nil{}:
      "<div class=\"empty\"><p>No posts yet. Start one below.</p></div>"
    case Con{r, t}:
      "<table class=\"table\">" ++ (member_post_rows(bslug, Con{r, t}) ++ "</table>")

def remove_button(b: Bool, +blog: String, uid: String) -> String:
  match b:
    case True{}:
      "<form method=\"post\" action=\"/dash/" ++ (e(blog) ++ ("/authors/" ++ (e(uid) ++ "/remove\"><button class=\"danger\">Remove</button></form>")))
    case False{}:
      ""

# Authors: [user id, name, email, role].
def author_items(+blog: String, +is_owner: Bool, rows: List<&2, List<&2, String>>) -> String:
  match rows:
    case Nil{}:
      ""
    case Con{+r, t}:
      "<li><span><strong>" ++ (e(col(r, 1n)) ++ ("</strong><br><span class=\"meta\">" ++ (role_name(col(r, 3n)) ++ ("<span class=\"dot\"></span>" ++ (e(col(r, 2n)) ++ ("</span></span>" ++ (remove_button(Bool.and(is_owner, Bool.not(String.eq(col(r, 3n), "1"))), blog, col(r, 0n)) ++ ("</li>" ++ author_items(blog, is_owner, t)))))))))

def owner_tools(b: Bool, +blog: String) -> String:
  match b:
    case True{}:
      "<form method=\"post\" action=\"/dash/" ++ (e(blog) ++ "/authors\" class=\"stack add-author\"><label>Add a co-author <span class=\"hint\">They need an account first.</span><input name=\"email\" type=\"email\" required placeholder=\"their@email.com\"></label><div><button>Add author</button></div></form>")
    case False{}:
      ""

def dash_blog(+slug: String, title: String, +is_owner: Bool, posts: List<&2, List<&2, String>>, authors: List<&2, List<&2, String>>) -> String:
  "<p class=\"meta crumb\"><a href=\"/dash\">← Your blogs</a></p><div class=\"dash-head\"><h1>" ++ (e(title) ++ ("</h1><a class=\"btn\" href=\"/b/" ++ (e(slug) ++ ("\">View blog</a></div><div class=\"cols\"><section>" ++ (member_posts(slug, posts) ++ ("<form id=\"new\" method=\"post\" action=\"/dash/" ++ (e(slug) ++ ("/posts\" class=\"card stack\"><h2>New post</h2><label>Title <input name=\"title\" required maxlength=\"200\" placeholder=\"Untitled\"></label><label>Address <span class=\"hint\">Optional. Made from the title if empty.</span><input name=\"slug\" maxlength=\"64\" pattern=\"[a-z0-9\\-]*\"></label><div><button class=\"primary\">Start writing</button></div></form></section><aside><h2>Authors</h2><ul class=\"people\">" ++ (author_items(slug, is_owner, authors) ++ ("</ul>" ++ (owner_tools(is_owner, slug) ++ "</aside></div>")))))))))))

# EDITOR
# ------

def publish_buttons(published: Bool) -> String:
  match published:
    case True{}:
      "<button form=\"post-form\" name=\"action\" value=\"publish\" class=\"primary\">Update</button>"
    case False{}:
      "<button form=\"post-form\" name=\"action\" value=\"save\" class=\"quiet hide-sm\">Save draft</button><button form=\"post-form\" name=\"action\" value=\"publish\" class=\"primary\">Publish</button>"

def unpublish(published: Bool, +id: String) -> String:
  match published:
    case True{}:
      "<form method=\"post\" action=\"/edit/" ++ (e(id) ++ "/unpublish\" data-confirm=\"Unpublish? Readers will no longer see this post.\"><button class=\"quiet\">Unpublish</button></form>")
    case False{}:
      ""

# md: [body markdown, title, published, blog slug, post slug]. The HTML
# parser drops one newline right after <textarea>, so one is put there for
# it to drop: a text that starts with a newline keeps it.
def edit_page(+id: String, +rep: String, +md: List<&2, String>) -> String:
  head("Editing: " ++ col(md, 1n)) ++ ("<header class=\"editor-bar\"><div class=\"wrap wide\"><a class=\"btn quiet\" href=\"/dash/" ++ (e(col(md, 3n)) ++ ("\" aria-label=\"Back to the blog\">←</a><span id=\"sync-status\" class=\"status\" role=\"status\">Saved</span>" ++ (view_link(String.eq(col(md, 2n), "1"), col(md, 3n), col(md, 4n)) ++ (unpublish(String.eq(col(md, 2n), "1"), id) ++ (publish_buttons(String.eq(col(md, 2n), "1")) ++ ("</div></header><main id=\"main\"><form id=\"post-form\" method=\"post\" action=\"/edit/" ++ (e(id) ++ ("\" class=\"wrap write editor\"><textarea class=\"title\" name=\"title\" rows=\"1\" required maxlength=\"200\" placeholder=\"Title\" aria-label=\"Title\">&#10;" ++ (e(col(md, 1n)) ++ ("</textarea><textarea id=\"editor\" class=\"text\" name=\"body\" placeholder=\"Tell your story…\" aria-label=\"Text\" data-post=\"" ++ (e(id) ++ ("\" data-rep=\"" ++ (e(rep) ++ ("\">&#10;" ++ (e(col(md, 0n)) ++ ("</textarea><p class=\"help\">Markdown: <code>## Heading</code> <code>**bold**</code> <code>*italic*</code> <code>[link](https://…)</code> <code>- list</code> <code>&gt; quote</code>. Your text syncs as you type; Ctrl+S or ⌘S renders it.</p></form><div class=\"wrap danger-zone\"><form method=\"post\" action=\"/edit/" ++ (e(id) ++ ("/delete\" data-confirm=\"Delete this post? This cannot be undone.\"><button class=\"danger\">Delete post</button></form></div></main><script type=\"module\" src=\"" ++ (asset("editor.js") ++ "\"></script></body></html>\n"))))))))))))))))))))
