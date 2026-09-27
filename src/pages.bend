# HTML pages. Pure. Every dynamic string goes through Html.esc (proved safe:
# LAWS.bend html_esc_safe), including slugs and ids in attributes.
#
# Styles: src/web/app.css, served at /s/app.css?v=<asset version> with
# immutable caching. No inline styles or scripts (the CSP forbids them).
import Base
import ./html.bend as Html
import ./gen/version.bend as Ver

# LIKES AND COMMENTS
# ------------------
# A page is a sequence of text and stored bodies (spliced by C): Seg.
type Seg is Data:
  T{text: String}
  B{body: U32}

type Page is Data:
  Page{texts: List<&2, String>, bodies: List<&2, U32>}

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
      "<a href=\"/\" class=\"hide-sm\">Home</a><a href=\"/search\" class=\"hide-sm\">Search</a><a href=\"/dash\">Your blogs</a><form method=\"post\" action=\"/logout\"><button class=\"link\">Log out</button></form><form method=\"post\" action=\"/write\"><button class=\"primary\">Write</button></form>"
    case False{}:
      "<a href=\"/search\" class=\"hide-sm\">Search</a><a href=\"/login\">Log in</a><a class=\"btn primary\" href=\"/signup\">Start writing</a>"

# DATASTAR
# --------
# Datastar (vendor/datastar, CSP mode) makes pages interactive by patching
# HTML the server renders. It compiles every data-* attribute into a script
# with the page's nonce, so data-* attributes are code: only templates write
# them (tools/lint.sh), and user text can never make one (the escaper).
#
# The nonce: <html data-nonce> holds this mark (32 characters, starting and
# ending with byte 1, which the escaper never emits), and each response has
# a fresh random nonce written over it (src/effects/db.c page_nonce).
def nonce_mark() -> String:
  SCon{Char.from_u32(1), "NONCE-MARK-0000000000000000000" ++ SCon{Char.from_u32(1), SNil{}}}

# A patch in a Datastar stream (content type 2): the element(s) html put at
# selector by mode (outer: morph by id; inner, append, replace, ...). Bytes
# 31 and 30 separate fields and patches (src/effects/db.c page_sse): like
# the mark, no escaped text or stored HTML contains them.
def patch(+selector: String, +mode: String, +html: String) -> String:
  selector ++ (SCon{Char.from_u32(31), SNil{}} ++ (mode ++ (SCon{Char.from_u32(31), SNil{}} ++ (html ++ SCon{Char.from_u32(30), SNil{}}))))

def head(+title: String) -> String:
  "<!doctype html><html lang=\"en\" data-nonce=\"" ++ (nonce_mark() ++ "\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><meta name=\"color-scheme\" content=\"light dark\"><title>" ++ (Html.esc(title, " · slopstack</title><link rel=\"stylesheet\" href=\"" ++ (asset("app.css") ++ ("\"><link rel=\"alternate\" type=\"application/rss+xml\" title=\"slopstack\" href=\"/feed.xml\"><script type=\"module\" src=\"" ++ (asset("datastar.js") ++ ("\"></script><script type=\"module\" src=\"" ++ (asset("app.js") ++ "\"></script><script type=\"speculationrules\" nonce=\"" ++ (nonce_mark() ++ "\">{\"prefetch\":[{\"where\":{\"and\":[{\"href_matches\":\"/*\"},{\"not\":{\"href_matches\":\"/verify*\"}},{\"not\":{\"href_matches\":\"/edit/*\"}}]},\"eagerness\":\"moderate\"}]}</script></head><body><a class=\"skip\" href=\"#main\">Skip to content</a>")))))))))

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

# The post page's script (likes without a reload, live comments).
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
  Html.esc(m, " min read")

def plural.go(b: Bool, +n: String, one: String, many: String) -> String:
  match b:
    case True{}:
      Html.esc(n, " " ++ one)
    case False{}:
      Html.esc(n, " " ++ many)

def plural(+n: String, one: String, many: String) -> String:
  plural.go(String.eq(n, "1"), n, one, many)

# ERRORS
# ------
def error_kind(+status: U32) -> Nat:
  U32.to_nat((Bool.to_u32(U32.is_eq(status, 404)) + ((2 * Bool.to_u32(U32.is_eq(status, 403))) + ((3 * Bool.to_u32(U32.is_eq(status, 409))) + ((4 * Bool.to_u32(U32.is_eq(status, 400))) + (5 * Bool.to_u32(U32.is_eq(status, 429)))))) : U32))

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
    case 5n:
      "Slow down a little"
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
    case 5n:
      "That is a lot of comments in a minute. Wait a moment, then go back and send it again."
    case _:
      "Please try again in a moment."

def error_title(+status: U32) -> String:
  error_title.go(error_kind(status))

def error_text(+status: U32) -> String:
  error_pick(error_kind(status))

def error_body(+status: U32) -> String:
  "<div class=\"center card\"><h1>" ++ (error_title(status) ++ ("</h1><p class=\"muted\">" ++ (error_text(status) ++ "</p><p><a class=\"btn\" href=\"/\">Go home</a></p></div>")))

def handle_tag.go(none: Bool, +h: String) -> String:
  match none:
    case True{}:
      ""
    case False{}:
      " <span class=\"handle\">@" ++ (Html.esc(h, "</span>"))

# FEEDS
# -----
# "@handle" after a name (accounts from before handles may have none).
def handle_tag(+h: String) -> String:
  handle_tag.go(String.is_empty(h), h)

def author_link(+id: String, +name: String) -> String:
  "<a href=\"/u/" ++ (Html.esc(id, "\">" ++ (Html.esc(name, "</a>"))))

def meta3(+id: String, +a: String, +b: String, +c: String) -> String:
  "<div class=\"meta\">" ++ (author_link(id, a) ++ ("<span class=\"dot\"></span>" ++ (date(b) ++ ("<span class=\"dot\"></span>" ++ (minutes(c) ++ "</div>")))))

# Recent posts: [blog slug, post slug, title, blog title, author, date,
# excerpt, minutes]. The excerpt is clipped to two lines by CSS.
def recent_items(rows: List<&2, List<&2, String>>, rest: String) -> String:
  match rows:
    case Nil{}:
      rest
    case Con{+r, t}:
      "<li><a class=\"pub\" href=\"/b/" ++ (Html.esc(col(r, 0n), "\">" ++ (Html.esc(col(r, 3n), "</a><h3><a href=\"/b/" ++ (Html.esc(col(r, 0n), "/" ++ (Html.esc(col(r, 1n), "\">" ++ (Html.esc(col(r, 2n), "</a></h3><p class=\"excerpt\">" ++ (Html.esc(col(r, 6n), "</p>" ++ (meta3(col(r, 8n), col(r, 4n), col(r, 5n), col(r, 7n)) ++ ("</li>" ++ recent_items(t, rest)))))))))))))))

def intro(signed: Bool) -> String:
  match signed:
    case True{}:
      ""
    case False{}:
      "<section class=\"masthead\"><h1>A quiet place to write</h1><p class=\"lede\">Fast pages, no trackers, no passwords: you sign in with a passkey. Write alone or with co-authors, even offline.</p><a class=\"btn primary big\" href=\"/signup\">Start writing</a></section>"

def feed_or_empty(rows: List<&2, List<&2, String>>, msg: String, rest: String) -> String:
  match rows:
    case Nil{}:
      "<div class=\"empty\"><p>" ++ (msg ++ ("</p></div>" ++ rest))
    case Con{r, t}:
      "<ul class=\"feed\" id=\"feed\">" ++ recent_items(Con{r, t}, "</ul>" ++ rest)

# PAGES OF 30: rows holds up to 31 (one more means there are older ones).
def rows_take(rows: List<&2, List<&2, String>>, n: Nat) -> List<&2, List<&2, String>>:
  match rows:
    case Nil{}:
      Nil{}
    case Con{r, t}:
      match n:
        case 0n:
          Nil{}
        case 1n+k:
          Con{r, rows_take(t, k)}

def pager.newer(b: Bool, +base: String, +page: U32) -> String:
  match b:
    case True{}:
      "<a href=\"" ++ (Html.esc(base, "?page=" ++ (U32.show((page - 1 : U32)) ++ "\">← Newer</a>")))
    case False{}:
      "<span></span>"

def pager.older(b: Bool, +base: String, +page: U32) -> String:
  match b:
    case True{}:
      "<a href=\"" ++ (Html.esc(base, "?page=" ++ (U32.show((page + 1 : U32)) ++ ("\" data-on:click__prevent=\"@get('" ++ (Html.esc(base, "?page=" ++ (U32.show((page + 1 : U32)) ++ "&amp;frag=1')\" data-indicator:_loading data-attr:aria-busy=\"$_loading\">Older posts →</a>")))))))
    case False{}:
      ""

# With Datastar, "Older" loads the next page into this one (feed_more).
def pager(+base: String, +page: U32, +rows: List<&2, List<&2, String>>) -> String:
  "<nav class=\"pager\" id=\"pager\">" ++ (pager.newer(U32.is_gt(page, 1), base, page) ++ (pager.older(Nat.is_lt(30n, List.length(&2, List<&2, String>, rows)), base, page) ++ "</nav>"))

def home_page(+rows: List<&2, List<&2, String>>, signed: Bool, +page: U32, rest: String) -> String:
  intro(signed) ++ ("<div class=\"feed-head\"><h2>Recent posts</h2><a href=\"/search\">Search</a></div>" ++ feed_or_empty(rows_take(rows, 30n), "Nothing published yet. Be the first!", pager("/", page, rows) ++ rest))

# A blog's posts: [post slug, title, author, date, excerpt, minutes].
def post_items(+bslug: String, rows: List<&2, List<&2, String>>, rest: String) -> String:
  match rows:
    case Nil{}:
      rest
    case Con{+r, t}:
      "<li><h3><a href=\"/b/" ++ (Html.esc(bslug, "/" ++ (Html.esc(col(r, 0n), "\">" ++ (Html.esc(col(r, 1n), "</a></h3><p class=\"excerpt\">" ++ (Html.esc(col(r, 4n), "</p>" ++ (meta3(col(r, 6n), col(r, 2n), col(r, 3n), col(r, 5n)) ++ ("</li>" ++ post_items(bslug, t, rest)))))))))))

def blog_feed(+slug: String, rows: List<&2, List<&2, String>>, rest: String) -> String:
  match rows:
    case Nil{}:
      "<div class=\"empty\"><p>No posts yet.</p></div>" ++ rest
    case Con{r, t}:
      "<ul class=\"feed\" id=\"feed\">" ++ post_items(slug, Con{r, t}, "</ul>" ++ rest)

# The pager after loading more: only the way on.
def pager_more(+base: String, +page: U32, +rows: List<&2, List<&2, String>>) -> String:
  "<nav class=\"pager\" id=\"pager\"><span></span>" ++ (pager.older(Nat.is_lt(30n, List.length(&2, List<&2, String>, rows)), base, page) ++ "</nav>")

# Datastar's answer to "Older": the page's items appended to #feed, and the
# pager moved on. items renders the first 30 rows in front of the text it
# is given (a patch, spelled out so the items are never copied).
def feed_more(+base: String, +page: U32, +rows: List<&2, List<&2, String>>, items: String -> String) -> String:
  "#feed" ++ (SCon{Char.from_u32(31), SNil{}} ++ ("append" ++ (SCon{Char.from_u32(31), SNil{}} ++ items(SCon{Char.from_u32(30), SNil{}} ++ patch("", "outer", pager_more(base, page, rows))))))

def blog_page(+slug: String, title: String, owner: String, +page: U32, +rows: List<&2, List<&2, String>>, rest: String) -> String:
  "<header class=\"masthead\"><h1>" ++ (Html.esc(title, "</h1><p class=\"muted\">by " ++ (Html.esc(owner, "<span class=\"dot\"></span><a href=\"/b/" ++ (Html.esc(slug, "/feed.xml\">RSS</a></p></header>" ++ blog_feed(slug, rows_take(rows, 30n), pager("/b/" ++ slug, page, rows) ++ rest)))))))

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
      "<span class=\"actions\"><a class=\"btn\" href=\"/edit/" ++ (Html.esc(id, "\">Edit</a></span>"))
    case False{}:
      ""

def published_notice(b: Bool, +id: String) -> String:
  match b:
    case True{}:
      "<div class=\"notice live\" role=\"status\"><strong>Your post is live.</strong> This is its public page: share its address with your readers. <a href=\"/edit/" ++ (Html.esc(id, "\">Keep editing</a></div>"))
    case False{}:
      ""

# view: [post slug, title, published, blog slug, blog title, author, date,
# minutes, author id]. notice: just published by this member.
def post_before(+view: List<&2, String>, +id: String, can_edit: Bool, notice: Bool) -> String:
  published_notice(notice, id) ++ "<article class=\"article\"><header><a class=\"pub\" href=\"/b/" ++ (Html.esc(col(view, 3n), "\">" ++ (Html.esc(col(view, 4n), "</a><h1>" ++ (Html.esc(col(view, 1n), "</h1><div class=\"byline\"><strong>" ++ (author_link(col(view, 8n), col(view, 5n)) ++ ("</strong>" ++ (handle_tag(col(view, 9n)) ++ ("<span class=\"dot\"></span>" ++ (date(col(view, 6n)) ++ ("<span class=\"dot\"></span>" ++ (minutes(col(view, 7n)) ++ (draft_badge(String.eq(col(view, 2n), "0")) ++ (edit_link(can_edit, id) ++ "</div></header><div class=\"body\">")))))))))))))))

def post_after(+view: List<&2, String>, +social: String) -> String:
  "</div>" ++ social ++ "<footer><a href=\"/b/" ++ (Html.esc(col(view, 3n), "\">← More from " ++ (Html.esc(col(view, 4n), "</a><a href=\"/\">Recent posts</a></footer></article>"))))

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

# Creates an untitled draft and opens the editor.
def new_post_button(+slug: String, label: String) -> String:
  "<form method=\"post\" action=\"/dash/" ++ (Html.esc(slug, "/posts\"><button class=\"primary\">" ++ (label ++ "</button></form>")))

# My blogs: [id, slug, title, role, published count, draft count].
def blog_cards(rows: List<&2, List<&2, String>>) -> String:
  match rows:
    case Nil{}:
      ""
    case Con{+r, t}:
      "<div class=\"card blogcard\"><h3><a href=\"/dash/" ++ (Html.esc(col(r, 1n), "\">" ++ (Html.esc(col(r, 2n), "</a></h3><div class=\"meta\">" ++ (role_name(col(r, 3n)) ++ ("<span class=\"dot\"></span>" ++ (plural(col(r, 4n), "post", "posts") ++ ("<span class=\"dot\"></span>" ++ (plural(col(r, 5n), "draft", "drafts") ++ ("</div><div class=\"row\">" ++ (new_post_button(col(r, 1n), "New post") ++ ("<a class=\"btn\" href=\"/dash/" ++ (Html.esc(col(r, 1n), "\">Posts and authors</a></div></div>" ++ blog_cards(t)))))))))))))))

def welcome() -> String:
  "<div class=\"center card\"><h1>Welcome!</h1><p class=\"muted\">Name your blog, and you are ready to write. You can add co-authors later.</p><form method=\"post\" action=\"/blogs\" class=\"stack\"><label>Blog name <input name=\"title\" required maxlength=\"200\" placeholder=\"e.g. Field Notes\" autofocus></label><button class=\"primary big\">Create my blog</button></form></div>"

def new_blog_form() -> String:
  "<form method=\"post\" action=\"/blogs\" class=\"card stack\"><h2>Start a new blog</h2><label>Name <input name=\"title\" required maxlength=\"200\" placeholder=\"The Weekly Thought\"></label><label>Address <span class=\"hint\">Optional: lowercase letters, digits and dashes. Made from the name if empty.</span><input name=\"slug\" maxlength=\"64\" pattern=\"[a-z0-9\\-]*\" placeholder=\"weekly-thought\"></label><div><button class=\"primary\">Create blog</button></div></form>"

def dash_page(rows: List<&2, List<&2, String>>) -> String:
  match rows:
    case Nil{}:
      welcome()
    case Con{r, t}:
      "<div class=\"dash-head\"><h1>Your blogs</h1></div><div class=\"grid\">" ++ (blog_cards(Con{r, t}) ++ ("</div><details class=\"more\"><summary>Start another blog</summary><div class=\"center\">" ++ (new_blog_form() ++ "</div></details>")))

def state_badge.go(b: Bool) -> String:
  match b:
    case True{}:
      "<span class=\"badge live\">Published</span>"
    case False{}:
      "<span class=\"badge\">Draft</span>"

def state_badge.sched(none: Bool, +p: String, +at: String) -> String:
  match none:
    case True{}:
      state_badge.go(String.eq(p, "1"))
    case False{}:
      "<span class=\"badge sched\">Scheduled " ++ (date(at) ++ "</span>")

def state_badge(+p: String, +at: String) -> String:
  state_badge.sched(String.is_empty(at), p, at)

def preview_link(b: Bool, +bslug: String, +pslug: String) -> String:
  match b:
    case True{}:
      "<a class=\"btn quiet view\" href=\"/b/" ++ (Html.esc(bslug, "/" ++ (Html.esc(pslug, "\">View</a>"))))
    case False{}:
      "<a class=\"btn quiet view\" href=\"/b/" ++ (Html.esc(bslug, "/" ++ (Html.esc(pslug, "\" target=\"_blank\">Preview</a>"))))

def view_link(b: Bool, +bslug: String, +pslug: String) -> String:
  match b:
    case True{}:
      "<a class=\"btn quiet view\" href=\"/b/" ++ (Html.esc(bslug, "/" ++ (Html.esc(pslug, "\">View</a>"))))
    case False{}:
      ""

# A blog's posts, for members: [id, slug, title, published, date, author].
def member_post_rows(+bslug: String, rows: List<&2, List<&2, String>>) -> String:
  match rows:
    case Nil{}:
      ""
    case Con{+r, t}:
      "<tr><td><a class=\"title\" href=\"/edit/" ++ (Html.esc(col(r, 0n), "\">" ++ (Html.esc(col(r, 2n), "</a><div class=\"meta\">" ++ (Html.esc(col(r, 5n), "<span class=\"dot\"></span>edited " ++ (date(col(r, 4n)) ++ ("</div></td><td>" ++ (state_badge(col(r, 3n), col(r, 6n)) ++ ("</td><td>" ++ (view_link(String.eq(col(r, 3n), "1"), bslug, col(r, 1n)) ++ ("<a class=\"btn\" href=\"/edit/" ++ (Html.esc(col(r, 0n), "\">Edit</a></td></tr>" ++ member_post_rows(bslug, t)))))))))))))))

def member_posts(+bslug: String, rows: List<&2, List<&2, String>>) -> String:
  match rows:
    case Nil{}:
      "<div class=\"empty\"><p>Nothing here yet.</p>" ++ (new_post_button(bslug, "Write your first post") ++ "</div>")
    case Con{r, t}:
      "<table class=\"table\">" ++ (member_post_rows(bslug, Con{r, t}) ++ "</table>")

# Removing someone asks first (src/web/app.js).
def remove_button(b: Bool, +blog: String, +uid: String, +name: String) -> String:
  match b:
    case True{}:
      "<form method=\"post\" action=\"/dash/" ++ (Html.esc(blog, "/authors/" ++ (Html.esc(uid, "/remove\" data-confirm=\"Remove " ++ (Html.esc(name, " from this blog? They will no longer be able to write or edit here.\" data-ok=\"Remove\" data-on:submit=\"@post('/dash/" ++ (Html.esc(blog, "/authors/" ++ (Html.esc(uid, "/remove?frag=1', {contentType: 'form'})\"><button class=\"danger\">Remove</button></form>"))))))))))
    case False{}:
      ""

# Authors: [user id, name, email, role].
def author_items(+blog: String, +is_owner: Bool, rows: List<&2, List<&2, String>>) -> String:
  match rows:
    case Nil{}:
      ""
    case Con{+r, t}:
      "<li><span><strong>" ++ (Html.esc(col(r, 1n), "</strong><br><span class=\"meta\">" ++ (role_name(col(r, 3n)) ++ ("<span class=\"dot\"></span>" ++ (Html.esc(col(r, 2n), "</span></span>" ++ (remove_button(Bool.and(is_owner, Bool.not(String.eq(col(r, 3n), "1"))), blog, col(r, 0n), col(r, 1n)) ++ ("</li>" ++ author_items(blog, is_owner, t)))))))))

def people_list(+blog: String, +is_owner: Bool, rows: List<&2, List<&2, String>>) -> String:
  "<ul class=\"people\" id=\"people\">" ++ (author_items(blog, is_owner, rows) ++ "</ul>")

def owner_tools(b: Bool, +blog: String) -> String:
  match b:
    case True{}:
      "<form id=\"add-author\" method=\"post\" action=\"/dash/" ++ (Html.esc(blog, "/authors\" class=\"stack add-author\" data-on:submit=\"@post('/dash/" ++ (Html.esc(blog, "/authors?frag=1', {contentType: 'form'})\" data-indicator:_adding><label>Add a co-author <span class=\"hint\">They need an account first.</span><input name=\"email\" type=\"email\" required placeholder=\"their@email.com\"></label><p class=\"form-note meta\" id=\"add-author-note\" aria-live=\"polite\"></p><div><button data-attr:disabled=\"$_adding\">Add author</button></div></form>"))))
    case False{}:
      ""

# CUSTOM DOMAIN (owner only). dom: [domain, token, verified]; main: this
# site's host; failed: a verification just found no TXT record.
def dns_notice(failed: Bool) -> String:
  match failed:
    case True{}:
      "<p class=\"notice\">The TXT record was not found yet. DNS changes can take a few minutes (sometimes an hour) to appear.</p>"
    case False{}:
      ""

def domain_form(+slug: String, +action: String, +label: String, +cls: String) -> String:
  "<form method=\"post\" action=\"/dash/" ++ (Html.esc(slug, "/domain\"><input type=\"hidden\" name=\"action\" value=\"" ++ (Html.esc(action, "\"><button class=\"" ++ (Html.esc(cls, "\">" ++ (Html.esc(label, "</button></form>"))))))))

def domain_state(k: Nat, +slug: String, +dom: List<&2, String>, +main: String, failed: Bool) -> String:
  match k:
    case 0n:
      "<p class=\"muted\">Serve this blog at your own address, like blog.example.com.</p><form method=\"post\" action=\"/dash/" ++ (Html.esc(slug, "/domain\" class=\"stack\"><input type=\"hidden\" name=\"action\" value=\"set\"><label>Domain <input name=\"domain\" required maxlength=\"253\" placeholder=\"blog.example.com\"></label><div><button>Use this domain</button></div></form>"))
    case 1n:
      "<p>For <strong>" ++ (Html.esc(col(dom, 0n), "</strong>, at your DNS provider:</p><ol class=\"steps\"><li>Point it here: a <code>CNAME</code> record to <code>" ++ (Html.esc(main, "</code> (or the same <code>A</code> record).</li><li>Add a <code>TXT</code> record named <code>_slopstack." ++ (Html.esc(col(dom, 0n), "</code> with the value <code class=\"select\">slopstack-verify=" ++ (Html.esc(col(dom, 1n), "</code></li></ol>" ++ (dns_notice(failed) ++ ("<div class=\"row\">" ++ (domain_form(slug, "verify", "Verify", "primary") ++ (domain_form(slug, "remove", "Remove", "quiet") ++ "</div>"))))))))))))
    case _:
      "<p>Live at <a href=\"https://" ++ (Html.esc(col(dom, 0n), "/\">" ++ (Html.esc(col(dom, 0n), "</a>.</p>" ++ domain_form(slug, "remove", "Remove", "quiet")))))

def domain_section(b: Bool, +slug: String, +dom: List<&2, String>, +main: String, failed: Bool) -> String:
  match b:
    case True{}:
      "<section id=\"domain\" class=\"domain\"><h2>Custom domain</h2>" ++ (domain_state(Nat.add(U32.to_nat(Bool.to_u32(Bool.not(String.is_empty(col(dom, 0n))))), U32.to_nat(Bool.to_u32(String.eq(col(dom, 2n), "1")))), slug, dom, main, failed) ++ "</section>")
    case False{}:
      ""

def dash_blog(+slug: String, title: String, +is_owner: Bool, posts: List<&2, List<&2, String>>, authors: List<&2, List<&2, String>>, +dom: List<&2, String>, +main: String, failed: Bool) -> String:
  "<p class=\"meta crumb\"><a href=\"/dash\">← Your blogs</a></p><div class=\"dash-head\"><h1>" ++ (Html.esc(title, "</h1><div class=\"row\"><a class=\"btn\" href=\"/b/" ++ (Html.esc(slug, "\">View blog</a>" ++ (new_post_button(slug, "New post") ++ ("</div></div><div class=\"cols\"><section>" ++ (member_posts(slug, posts) ++ ("</section><aside><h2>Authors</h2>" ++ (people_list(slug, is_owner, authors) ++ ("" ++ (owner_tools(is_owner, slug) ++ (domain_section(is_owner, slug, dom, main, failed) ++ "</aside></div>"))))))))))))

def schedule_ui.go(none: Bool, +at: String) -> String:
  match none:
    case True{}:
      "<details class=\"schedule\"><summary class=\"btn quiet\">Schedule</summary><div class=\"pop\"><label>Publish at <input type=\"datetime-local\" name=\"at_local\" form=\"post-form\"></label><input type=\"hidden\" name=\"at\" form=\"post-form\"><button form=\"post-form\" name=\"action\" value=\"schedule\" class=\"primary\">Schedule</button></div></details>"
    case False{}:
      "<span class=\"scheduled\">Scheduled for <time datetime=\"" ++ (Html.esc(at, "\">" ++ (Html.esc(String.take(at, 10n), " " ++ (Html.esc(String.take(String.drop(at, 11n), 5n), " UTC</time></span><button form=\"post-form\" name=\"action\" value=\"unschedule\" class=\"quiet\">Cancel</button>"))))))

# EDITOR
# ------
# A draft can be scheduled; a scheduled draft shows when (UTC in the
# markup, local time once the editor's script runs) and can be cancelled.
def schedule_ui(+at: String) -> String:
  schedule_ui.go(String.is_empty(at), at)

def publish_buttons(published: Bool, +at: String) -> String:
  match published:
    case True{}:
      "<button form=\"post-form\" name=\"action\" value=\"publish\" class=\"primary\">Update</button>"
    case False{}:
      "<button form=\"post-form\" name=\"action\" value=\"save\" class=\"quiet hide-sm\">Save draft</button>" ++ (schedule_ui(at) ++ "<button form=\"post-form\" name=\"action\" value=\"publish\" class=\"primary\">Publish</button>")

def unpublish(published: Bool, +id: String) -> String:
  match published:
    case True{}:
      "<form method=\"post\" action=\"/edit/" ++ (Html.esc(id, "/unpublish\" data-confirm=\"Unpublish? Readers will no longer see this post.\"><button class=\"quiet\">Unpublish</button></form>"))
    case False{}:
      ""

# Tag rows as the editor's field text: "a, b, c".
def tag_list(rows: List<&2, List<&2, String>>) -> String:
  match rows:
    case Nil{}:
      ""
    case Con{r, t}:
      match t:
        case Nil{}:
          col(r, 0n)
        case Con{r2, t2}:
          col(r, 0n) ++ (", " ++ tag_list(Con{r2, t2}))

def tag_chip_items(rows: List<&2, List<&2, String>>) -> String:
  match rows:
    case Nil{}:
      ""
    case Con{+r, t}:
      "<a class=\"tag\" href=\"/t/" ++ (Html.esc(col(r, 0n), "\">#" ++ (Html.esc(col(r, 0n), "</a>" ++ tag_chip_items(t)))))

def tag_chips(rows: List<&2, List<&2, String>>) -> String:
  match rows:
    case Nil{}:
      ""
    case Con{r, t}:
      "<div class=\"tags\">" ++ (tag_chip_items(Con{r, t}) ++ "</div>")

def tag_page(+tag: String, +page: U32, +rows: List<&2, List<&2, String>>, rest: String) -> String:
  "<header class=\"masthead\"><h1>#" ++ (Html.esc(tag, "</h1><p class=\"muted\">Posts tagged " ++ (Html.esc(tag, "</p></header>" ++ feed_or_empty(rows_take(rows, 30n), "No posts with this tag yet.", pager("/t/" ++ tag, page, rows) ++ rest)))))

# md: [body markdown, title, published, blog slug, post slug]. The HTML
# parser drops one newline right after <textarea>, so one is put there for
# it to drop: a text that starts with a newline keeps it.
def edit_page(+id: String, +rep: String, +md: List<&2, String>, +tags: String) -> String:
  head("Editing: " ++ col(md, 1n)) ++ ("<header class=\"editor-bar\"><div class=\"wrap wide\"><a class=\"btn quiet\" href=\"/dash/" ++ (Html.esc(col(md, 3n), "\" aria-label=\"Back to the blog\">←</a><span id=\"sync-status\" class=\"status\" role=\"status\">Saved</span>" ++ (preview_link(String.eq(col(md, 2n), "1"), col(md, 3n), col(md, 4n)) ++ (unpublish(String.eq(col(md, 2n), "1"), id) ++ (publish_buttons(String.eq(col(md, 2n), "1"), col(md, 5n)) ++ ("</div></header><main id=\"main\"><form id=\"post-form\" method=\"post\" action=\"/edit/" ++ (Html.esc(id, "\" class=\"wrap write editor\"><textarea class=\"title\" name=\"title\" rows=\"1\" required maxlength=\"200\" placeholder=\"Title\" aria-label=\"Title\">&#10;" ++ (Html.esc(col(md, 1n), "</textarea><input class=\"tags\" name=\"tags\" maxlength=\"300\" placeholder=\"Tags, separated by commas\" aria-label=\"Tags\" value=\"" ++ (Html.esc(tags, "\"><div class=\"edit-tools\" id=\"edit-tools\"></div><textarea id=\"editor\" class=\"text\" name=\"body\" placeholder=\"Tell your story…\" aria-label=\"Text\" data-published=\"" ++ (Html.esc(col(md, 2n), "\" data-post=\"" ++ (Html.esc(id, "\" data-rep=\"" ++ (Html.esc(rep, "\">&#10;" ++ (Html.esc(col(md, 0n), "</textarea><p class=\"help\"><button type=\"button\" id=\"image-add\" class=\"link\">Add an image</button> (or paste or drop one). <input type=\"file\" id=\"image-pick\" accept=\"image/*\" hidden> Markdown: <code>## Heading</code> <code>**bold**</code> <code>*italic*</code> <code>[link](https://…)</code> <code>- list</code> <code>&gt; quote</code>. Your text syncs as you type; Ctrl+S or ⌘S renders it.</p></form><div class=\"wrap danger-zone\"><form method=\"post\" action=\"/edit/" ++ (Html.esc(id, "/delete\" data-confirm=\"Delete this post? This cannot be undone.\"><button class=\"danger\">Delete post</button></form></div></main><script type=\"module\" src=\"" ++ (asset("editor.js") ++ "\"></script></body></html>\n"))))))))))))))))))))))))

# AUTHOR PAGE
# -----------
# "@handle · Posts by Name", or "Posts by Name" (accounts from before handles).
def author_sub(none: Bool, +h: String, +name: String) -> String:
  match none:
    case True{}:
      "Posts by " ++ Html.esc(name, "")
    case False{}:
      "<span class=\"handle\">@" ++ Html.esc(h, "</span> · Posts by " ++ Html.esc(name, ""))
# rows: as recent_items.
def author_page(+uid: String, +name: String, +handle: String, +page: U32, +rows: List<&2, List<&2, String>>, rest: String) -> String:
  "<header class=\"masthead\"><h1>" ++ (Html.esc(name, "</h1><p class=\"muted\">" ++ (author_sub(String.is_empty(handle), handle, name) ++ ("</p></header>" ++ feed_or_empty(rows_take(rows, 30n), "Nothing published yet.", pager("/u/" ++ uid, page, rows) ++ rest)))))

# RSS
# ---
# RSS 2.0 with absolute links (origin: the configured site origin). Every
# text goes through the same escaper, whose entities are also valid XML.
def rss(+origin: String, +title: String, +path: String, +desc: String, items: String) -> String:
  "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<rss version=\"2.0\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><channel><title>" ++ (Html.esc(title, "</title><link>" ++ (Html.esc(origin ++ path, "</link><description>" ++ (Html.esc(desc, "</description>" ++ (items ++ "</channel></rss>\n")))))))

def rss_item(+origin: String, +bslug: String, +pslug: String, +title: String, +author: String, +excerpt: String, +date: String) -> String:
  "<item><title>" ++ (Html.esc(title, "</title><link>" ++ (Html.esc(origin, "/b/" ++ (Html.esc(bslug, "/" ++ (Html.esc(pslug, "</link><guid isPermaLink=\"true\">" ++ (Html.esc(origin, "/b/" ++ (Html.esc(bslug, "/" ++ (Html.esc(pslug, "</guid><dc:creator>" ++ (Html.esc(author, "</dc:creator><pubDate>" ++ (Html.esc(date, "</pubDate><description>" ++ (Html.esc(excerpt, "</description></item>"))))))))))))))))))))

# Recent rows (see recent_items), col 9: RFC 822 date.
def rss_recent(+origin: String, rows: List<&2, List<&2, String>>) -> String:
  match rows:
    case Nil{}:
      ""
    case Con{+r, t}:
      rss_item(origin, col(r, 0n), col(r, 1n), col(r, 2n), col(r, 4n), col(r, 6n), col(r, 9n)) ++ rss_recent(origin, t)

# A blog's rows (see post_items), col 7: RFC 822 date.
def rss_blog(+origin: String, +bslug: String, rows: List<&2, List<&2, String>>) -> String:
  match rows:
    case Nil{}:
      ""
    case Con{+r, t}:
      rss_item(origin, bslug, col(r, 0n), col(r, 1n), col(r, 2n), col(r, 4n), col(r, 7n)) ++ rss_blog(origin, bslug, t)

# SEARCH
# ------
# A snippet from SQLite: text with matches between bytes 1 and 2. Each
# character is escaped on its own (Html.esc), and only the two marker bytes
# (which the escaper would drop, and stored text never contains) become
# <mark> tags.
def hl.pick(k: Nat, +h: Char) -> String:
  match k:
    case 1n:
      "<mark>"
    case 2n:
      "</mark>"
    case _:
      Html.esc(SCon{h, SNil{}}, "")

def hl(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{+h, t}:
      hl.pick(U32.to_nat((Bool.to_u32(U32.is_eq(Char.to_u32(h), 1)) + (2 * Bool.to_u32(U32.is_eq(Char.to_u32(h), 2))) : U32)), h) ++ hl(t)

# Results: as recent_items, but col 6 is a marked snippet.
def search_items(rows: List<&2, List<&2, String>>) -> String:
  match rows:
    case Nil{}:
      ""
    case Con{+r, t}:
      "<li><a class=\"pub\" href=\"/b/" ++ (Html.esc(col(r, 0n), "\">" ++ (Html.esc(col(r, 3n), "</a><h3><a href=\"/b/" ++ (Html.esc(col(r, 0n), "/" ++ (Html.esc(col(r, 1n), "\">" ++ (Html.esc(col(r, 2n), "</a></h3><p class=\"excerpt snippet\">" ++ (hl(col(r, 6n)) ++ ("</p>" ++ (meta3(col(r, 8n), col(r, 4n), col(r, 5n), col(r, 7n)) ++ ("</li>" ++ search_items(t)))))))))))))))

def search_results(asked: Bool, rows: List<&2, List<&2, String>>) -> String:
  match asked:
    case False{}:
      ""
    case True{}:
      match rows:
        case Nil{}:
          "<div class=\"empty\"><p>No posts match. Try fewer or different words.</p></div>"
        case Con{r, t}:
          "<ul class=\"feed\">" ++ (search_items(Con{r, t}) ++ "</ul>")

def search_busy() -> String:
  "<div id=\"results\"><div class=\"empty\"><p>Search is busy right now. Try again in a moment.</p></div></div>"

def results_div(+q: String, rows: List<&2, List<&2, String>>) -> String:
  "<div id=\"results\">" ++ (search_results(Bool.not(String.is_empty(q)), rows) ++ "</div>")

# Results update as you type (Datastar: 250 ms after the last key, the
# address bar follows); the form works without it. The query goes in only
# as a signal ($_q, never sent as JSON: a leading _), percent-encoded
# including !'()*, which this server's query syntax does not allow bare.
def search_page(+q: String, rows: List<&2, List<&2, String>>) -> String:
  "<form method=\"get\" action=\"/search\" class=\"searchbar\" role=\"search\"><input name=\"q\" type=\"search\" maxlength=\"200\" placeholder=\"Search posts\" aria-label=\"Search posts\" autocomplete=\"off\" autofocus value=\"" ++ (Html.esc(q, "\" data-bind:_q data-computed:_qe=\"encodeURIComponent($_q).replace(/[!'()*]/g, c => '%' + c.charCodeAt(0).toString(16))\" data-on:input__debounce.250ms=\"history.replaceState(null, '', '/search?q=' + $_qe); @get('/search?frag=1&amp;q=' + $_qe)\" data-indicator:_searching><button class=\"primary\">Search</button></form>" ++ results_div(q, rows)))

def page_cons(+t: String, +b: U32, p: Page) -> Page:
  match p:
    case Page{ts, bs}:
      Page{Con{t, ts}, Con{b, bs}}

# Texts and bodies alternating, as Db.page takes them (texts[0] body[0]
# texts[1] ... texts[n]); consecutive texts are joined.
def page_of(segs: List<&2, Seg>, +acc: String) -> Page:
  match segs:
    case Nil{}:
      Page{Con{acc, Nil{}}, Nil{}}
    case Con{x, t}:
      match x:
        case T{+s}:
          page_of(t, acc ++ s)
        case B{+b}:
          page_cons(acc, b, page_of(t, ""))

def page_texts(p: Page) -> List<&2, String>:
  match p:
    case Page{ts, bs}:
      ts

def page_bodies(p: Page) -> List<&2, U32>:
  match p:
    case Page{ts, bs}:
      bs

# social: [likes, liked (0/1), comments].
def closes(n: Nat) -> String:
  match n:
    case 0n:
      ""
    case 1n+k:
      "</details></div>" ++ closes(k)

def depth_of(+s: String) -> Nat:
  U32.to_nat(num(s))

# A comment's body: its stored HTML, or a note if it was deleted.
def comment_body_seg(deleted: Bool, +id: String) -> Seg:
  match deleted:
    case True{}:
      T{"<p class=\"muted\">[deleted]</p>"}
    case False{}:
      B{(num(id) + 2147483648 : U32)}

def comment_open_count(+prev: Maybe<&2, Nat>) -> Nat:
  match prev:
    case None{}:
      0n
    case Some{d}:
      1n+d

def comment_close_before(+prev: Maybe<&2, Nat>, +d: Nat) -> Nat:
  match prev:
    case None{}:
      0n
    case Some{+p}:
      Nat.sub(1n+p, d)

# A comment's replies: a <details>, open unless the thread is collapsed
# (a top-level comment with replies, on a post with many comments). Live
# comments are added into it by the page's script.
# Comment rows (see Q_COMMENTS): [id, depth, author id, author, date,
# deleted, mine, parent, handle, replies], in thread order. Before a
# comment at depth d, the comments it does not reply to are closed:
# (previous depth - d + 1) of them, none for a reply to the previous one.
# many: collapse top-level threads.
# New comments for the live update (Q_COMMENTS_AFTER rows, depth 0): each
# complete, with its parent's id for the script to place it.
# The thread is in #thread; data-post and data-last let the page's script
# ask for newer comments.
# The reply page: the comment replied to (its body spliced after the first
# text), and a form. info: [post id, author id, author, date, deleted].
def reply_before(+info: List<&2, String>, +back: String) -> String:
  "<p class=\"meta crumb\"><a href=\"" ++ (Html.esc(back, "\">← Back to the post</a></p><h1>Reply</h1><div class=\"comment\"><div class=\"meta\">" ++ (author_link(col(info, 1n), col(info, 2n)) ++ ("<span class=\"dot\"></span>" ++ (date(col(info, 3n)) ++ "</div><div class=\"cbody\">")))))

def reply_after(+info: List<&2, String>, +cid: String, +back: String) -> String:
  "</div></div><form method=\"post\" action=\"/comment/" ++ (Html.esc(col(info, 0n), "\" class=\"stack cform\"><input type=\"hidden\" name=\"parent\" value=\"" ++ (Html.esc(cid, "\"><textarea name=\"body\" required maxlength=\"10000\" rows=\"4\" placeholder=\"Write a reply…\" aria-label=\"Reply\" autofocus></textarea><div class=\"row\"><button class=\"primary\">Reply</button><a class=\"btn quiet\" href=\"" ++ (Html.esc(back, "\">Cancel</a></div></form>"))))))

# INTERACTIVE POST PAGE (Datastar)
# --------------------------------
# Every form and link below also works without JavaScript (a normal post
# or page load); with Datastar the same URL with ?frag=1 answers a stream
# of patches instead. Expressions only ever contain numbers the server
# wrote (ids), never user text.
def like_js(liked: Bool) -> String:
  match liked:
    case True{}:
      "true"
    case False{}:
      "false"

def like_state(liked: Bool) -> String:
  match liked:
    case True{}:
      "0\"><button class=\"like on\" aria-pressed=\"true\" title=\"Unlike\" data-class:on=\"$_lk\" data-attr:aria-pressed=\"$_lk ? 'true' : 'false'\" data-attr:title=\"$_lk ? 'Unlike' : 'Like'\">♥ "
    case False{}:
      "1\"><button class=\"like\" aria-pressed=\"false\" title=\"Like\" data-class:on=\"$_lk\" data-attr:aria-pressed=\"$_lk ? 'true' : 'false'\" data-attr:title=\"$_lk ? 'Unlike' : 'Like'\">♥ "

# A like shows at once (Datastar signals: _lk liked, _ln the count), and the
# server's answer (the bar, patched) then says what is true. The form's
# "on" (the state wanted) is set before it is sent. A tap while one is
# being sent is ignored (not shown as a disabled, faded button: that
# flashed on every tap). Expressions hold only numbers the server wrote.
def like_button(signed: Bool, +pid: String, +likes: String, +liked: Bool) -> String:
  match signed:
    case True{}:
      "<form method=\"post\" action=\"/like/" ++ (Html.esc(pid, "\" data-signals=\"{_lk: " ++ (like_js(liked) ++ (", _ln: " ++ (Html.esc(likes, "}\" data-on:submit=\"$_liking || ($_lk = !$_lk, $_ln = $_ln + ($_lk ? 1 : -1), el.elements.on.value = $_lk ? '1' : '0', @post('/like/" ++ (Html.esc(pid, "?frag=1', {contentType: 'form'}))\" data-indicator:_liking><input type=\"hidden\" name=\"on\" value=\"" ++ (like_state(liked) ++ ("<span data-text=\"$_ln\">" ++ (Html.esc(likes, "</span></button></form>"))))))))))))
    case False{}:
      "<a class=\"btn like\" href=\"/login\" title=\"Log in to like\">♥ " ++ (Html.esc(likes, "</a>"))

# social: [likes, liked (0/1), comments].
def social_bar(signed: Bool, +pid: String, +social: List<&2, String>) -> String:
  "<div class=\"social\" id=\"social\">" ++ (like_button(signed, pid, col(social, 0n), String.eq(col(social, 1n), "1")) ++ ("<a class=\"btn quiet\" href=\"#comments\">" ++ (plural(col(social, 2n), "comment", "comments") ++ "</a></div>")))

# The comment box; parent 0 for a new thread, else a reply (shown inline).
def comment_box(+pid: String, +parent: String, +id: String, +rows: String, +label: String, +extra: String) -> String:
  "<form id=\"" ++ (Html.esc(id, "\" method=\"post\" action=\"/comment/" ++ (Html.esc(pid, "\" class=\"stack cform\" data-on:submit=\"@post('/comment/" ++ (Html.esc(pid, "?frag=1', {contentType: 'form'})\" data-indicator:_sending><input type=\"hidden\" name=\"parent\" value=\"" ++ (Html.esc(parent, "\"><textarea name=\"body\" required maxlength=\"10000\" rows=\"" ++ (Html.esc(rows, "\" placeholder=\"" ++ (Html.esc(label, "…\" aria-label=\"" ++ (Html.esc(label, "\"></textarea><p class=\"form-note meta\" id=\"" ++ (Html.esc(id, "-note\"></p><div class=\"row\"><button class=\"primary\" data-attr:disabled=\"$_sending\">Send</button>" ++ (extra ++ "</div></form>")))))))))))))))))

def comment_form(signed: Bool, +pid: String) -> String:
  match signed:
    case True{}:
      comment_box(pid, "0", "cform", "3", "Write a comment", "")
    case False{}:
      "<p class=\"muted\"><a href=\"/login\">Log in</a> or <a href=\"/signup\">sign up</a> to comment.</p>"

# Inline reply form, patched into #rf<id> by /reply/<id>?frag=1.
def reply_box(+pid: String, +cid: String) -> String:
  comment_box(pid, cid, "rff" ++ cid, "3", "Write a reply", "<button type=\"button\" class=\"quiet\" data-on:click=\"document.getElementById('rf" ++ (Html.esc(cid, "').replaceChildren()\">Cancel</button>")))

def reply_link(signed: Bool, +id: String) -> String:
  match signed:
    case True{}:
      "<a href=\"/reply/" ++ (Html.esc(id, "\" data-on:click__prevent=\"@get('/reply/" ++ (Html.esc(id, "?frag=1')\">Reply</a>"))))
    case False{}:
      ""

def delete_comment(b: Bool, +id: String) -> String:
  match b:
    case True{}:
      "<details class=\"del\"><summary>Delete</summary><form method=\"post\" action=\"/comment/" ++ (Html.esc(id, "/delete\" data-on:submit=\"@post('/comment/" ++ (Html.esc(id, "/delete?frag=1', {contentType: 'form'})\"><button class=\"danger\">Delete this comment</button></form></details>"))))
    case False{}:
      ""

# A comment's replies: a <details id="r<id>">, open unless the thread is
# collapsed (a top-level comment with replies, on a post with many
# comments). Live replies are appended into it.
# Every replies element has a summary (without one, browsers show their
# own "Details"): "N replies", which also folds the thread, or, with none
# yet, an empty one kept hidden.
def replies_sum(none: Bool, +n: String) -> String:
  match none:
    case True{}:
      "<summary class=\"none\"></summary>"
    case False{}:
      "<summary>" ++ (plural(n, "reply", "replies") ++ "</summary>")

def replies_open(collapse: Bool, +id: String, +n: String) -> String:
  match collapse:
    case True{}:
      "<details class=\"replies\" id=\"r" ++ (Html.esc(id, "\"><summary>" ++ (plural(n, "reply", "replies") ++ "</summary>")))
    case False{}:
      "<details class=\"replies\" id=\"r" ++ (Html.esc(id, "\" open>" ++ replies_sum(String.eq(n, "0"), n)))

# A comment row (see Q_COMMENTS): [id, depth, author id, author, date,
# deleted, mine, parent, handle, replies]. Before its body:
# extra: more classes (" fresh": just arrived, highlighted for a moment).
def comment_open_as(+extra: String, +r: List<&2, String>) -> String:
  "<div class=\"comment" ++ (extra ++ ("\" id=\"c" ++ (Html.esc(col(r, 0n), "\" data-parent=\"" ++ (Html.esc(col(r, 7n), "\"><div class=\"meta\">" ++ (author_link(col(r, 2n), col(r, 3n)) ++ (handle_tag(col(r, 8n)) ++ ("<span class=\"dot\"></span><a href=\"#c" ++ (Html.esc(col(r, 0n), "\">" ++ (date(col(r, 4n)) ++ ("</a></div><div class=\"cbody\" id=\"cb" ++ (Html.esc(col(r, 0n), "\">")))))))))))))))

def comment_open(+r: List<&2, String>) -> String:
  comment_open_as("", r)

# After its body: actions, the inline reply slot, and its replies opened.
def comment_after(+r: List<&2, String>, +signed: Bool, +can_mod: Bool, +collapse: Bool) -> String:
  "</div><div class=\"cactions\" id=\"ca" ++ (Html.esc(col(r, 0n), "\">" ++ (reply_link(signed, col(r, 0n)) ++ (delete_comment(Bool.and(Bool.not(String.eq(col(r, 5n), "1")), Bool.or(can_mod, String.eq(col(r, 6n), "1"))), col(r, 0n)) ++ ("</div><div class=\"rf\" id=\"rf" ++ (Html.esc(col(r, 0n), "\"></div>" ++ replies_open(collapse, col(r, 0n), col(r, 9n)))))))))

# The thread in thread order. Before a comment at depth d, the comments it
# does not reply to are closed: (previous depth - d + 1) of them, none for
# a reply to the previous one. many: collapse top-level threads.
def comment_segs(rows: List<&2, List<&2, String>>, +signed: Bool, +can_mod: Bool, +many: Bool, +prev: Maybe<&2, Nat>) -> List<&2, Seg>:
  match rows:
    case Nil{}:
      Con{T{closes(comment_open_count(prev))}, Nil{}}
    case Con{+r, t}:
      Con{T{closes(comment_close_before(prev, depth_of(col(r, 1n)))) ++ comment_open(r)}, Con{comment_body_seg(String.eq(col(r, 5n), "1"), col(r, 0n)), Con{T{comment_after(r, signed, can_mod, Bool.and(many, Bool.and(Nat.is_eq(depth_of(col(r, 1n)), 0n), Bool.not(String.eq(col(r, 9n), "0")))))}, comment_segs(t, signed, can_mod, many, Some{depth_of(col(r, 1n))})}}}

def live_attr(busy: Bool) -> String:
  match busy:
    case True{}:
      "data-init__delay.20s"
    case False{}:
      "data-init"

# The element that keeps the live update going: each answer patches it
# with the next request (n changes every time, so Datastar re-runs it).
# busy: wait before asking (too many readers waiting).
def live_div(+pid: String, +after: String, +n: String, busy: Bool) -> String:
  "<div id=\"live\" " ++ (live_attr(busy) ++ ("=\"@get('/live/" ++ (Html.esc(pid, "?after=" ++ (Html.esc(after, "&amp;n=" ++ (Html.esc(n, "', {requestCancellation: 'cleanup'})\"></div>"))))))))

def live_target.go(top: Bool, +parent: String) -> String:
  match top:
    case True{}:
      "#thread"
    case False{}:
      "#r" ++ parent

# New comments for the live update (Q_COMMENTS_AFTER rows): each appended
# to its parent's replies, or to the thread.
def live_target(+parent: String) -> String:
  live_target.go(String.eq(parent, "0"), parent)

def live_segs(rows: List<&2, List<&2, String>>, +signed: Bool, +can_mod: Bool) -> List<&2, Seg>:
  match rows:
    case Nil{}:
      Nil{}
    case Con{+r, t}:
      Con{T{live_target(col(r, 7n)) ++ (SCon{Char.from_u32(31), SNil{}} ++ ("append" ++ (SCon{Char.from_u32(31), SNil{}} ++ comment_open_as(" fresh", r))))}, Con{comment_body_seg(String.eq(col(r, 5n), "1"), col(r, 0n)), Con{T{comment_after(r, signed, can_mod, False{}) ++ ("</details></div>" ++ SCon{Char.from_u32(30), SNil{}})}, live_segs(t, signed, can_mod)}}}

# COMMENT PAGES: a post page shows 20 threads (src/handlers.bend
# threads_take); "More comments" brings the next 20 (Datastar puts them in
# place, before itself; without it, a page of their own). upto: the last
# comment when the post page was made (later ones came live, or will).
def more_comments(+pid: String, +after: String, +upto: String) -> String:
  "<div id=\"more-comments\" class=\"more-comments\"><a class=\"btn\" href=\"/comments/" ++ Html.esc(pid, "?after=" ++ Html.esc(after, "&amp;upto=" ++ Html.esc(upto, "\" data-on:click__prevent=\"@get('/comments/" ++ Html.esc(pid, "?after=" ++ Html.esc(after, "&amp;upto=" ++ Html.esc(upto, "&amp;frag=1')\" data-indicator:_morec data-attr:aria-busy=\"$_morec\">More comments</a></div>"))))))

def more_or_none(more: Bool, +pid: String, +after: String, +upto: String) -> String:
  match more:
    case True{}:
      more_comments(pid, after, upto)
    case False{}:
      ""

def more_mode(none: Bool) -> String:
  match none:
    case True{}:
      "remove"
    case False{}:
      "outer"

# Datastar's answer to "More comments": the threads put before it (in one
# element), then it is replaced by the next link (more) or removed.
def more_segs(+signed: Bool, +can_mod: Bool, +many: Bool, rows: List<&2, List<&2, String>>, +more: String) -> List<&2, Seg>:
  Con{T{"#more-comments" ++ (SCon{Char.from_u32(31), SNil{}} ++ ("before" ++ (SCon{Char.from_u32(31), SNil{}} ++ "<div class=\"cbatch\">")))}, List.append(&2, Seg, comment_segs(rows, signed, can_mod, many, None{}), Con{T{"</div>" ++ (SCon{Char.from_u32(30), SNil{}} ++ patch("#more-comments", more_mode(String.is_empty(more)), more))}, Nil{}})}

# Without Datastar: the next threads on a page of their own. view: as the
# post page's (Q_POST_VIEW: post slug, title, published, blog slug, ...).
def more_page(+signed: Bool, +can_mod: Bool, +many: Bool, +view: List<&2, String>, rows: List<&2, List<&2, String>>, +more: String) -> List<&2, Seg>:
  Con{T{layout_top("Comments: " ++ col(view, 1n), signed) ++ ("<p><a href=\"/b/" ++ Html.esc(col(view, 3n), "/" ++ Html.esc(col(view, 0n), "#comments\">← " ++ Html.esc(col(view, 1n), "</a></p><section class=\"comments\" id=\"comments\"><div id=\"thread\">"))))}, List.append(&2, Seg, comment_segs(rows, signed, can_mod, many, None{}), Con{T{more ++ ("</div></section>" ++ layout_bottom())}, Nil{}})}

def comments_section(+signed: Bool, +can_mod: Bool, +pid: String, +count: String, +last: String, rows: List<&2, List<&2, String>>, +more: String) -> List<&2, Seg>:
  Con{T{"<section class=\"comments\" id=\"comments\"><h2>Comments</h2>" ++ (comment_form(signed, pid) ++ (live_div(pid, last, "0", False{}) ++ "<div id=\"thread\">"))}, List.append(&2, Seg, comment_segs(rows, signed, can_mod, Nat.is_lt(20n, U32.to_nat(num(count))), None{}), Con{T{more ++ "</div></section>"}, Nil{}})}
