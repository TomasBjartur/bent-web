# HTML pages. Pure. Every dynamic string goes through Html.esc (proved safe:
# LAWS.bend html_esc_safe), including slugs and ids in attributes.
import Base
import ./html.bend as Html

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

def nav(b: Bool) -> String:
  match b:
    case True{}:
      "<a href=\"/dash\">Dashboard</a><form method=\"post\" action=\"/logout\"><button>Log out</button></form>"
    case False{}:
      "<a href=\"/login\">Log in</a>"

def layout_top(+title: String, signed_in: Bool) -> String:
  "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><link rel=\"stylesheet\" href=\"/s/app.css\"><title>" ++ (e(title) ++ ("</title></head><body><header><a href=\"/\" class=\"brand\">bent</a><nav>" ++ (nav(signed_in) ++ "</nav></header><main>")))

def layout_bottom() -> String:
  "</main></body></html>\n"

def layout(+title: String, signed_in: Bool, body: String) -> String:
  layout_top(title, signed_in) ++ (body ++ layout_bottom())

def error_pick(k: Nat) -> String:
  match k:
    case 1n:
      "Nothing here."
    case 2n:
      "Not allowed."
    case 3n:
      "That name is taken, or something changed meanwhile. Go back and try again."
    case 4n:
      "That did not look right. Go back and check the form."
    case _:
      "Something went wrong."

def error_text(+status: U32) -> String:
  error_pick(U32.to_nat((Bool.to_u32(U32.is_eq(status, 404)) + ((2 * Bool.to_u32(U32.is_eq(status, 403))) + ((3 * Bool.to_u32(U32.is_eq(status, 409))) + (4 * Bool.to_u32(U32.is_eq(status, 400))))) : U32)))

def error_body(+status: U32) -> String:
  "<h1>" ++ (U32.show(status) ++ ("</h1><p>" ++ (error_text(status) ++ "</p>")))

# HOME
# ----
def recent_items(rows: List<&2, List<&2, String>>) -> String:
  match rows:
    case Nil{}:
      ""
    case Con{+r, t}:
      "<li><a href=\"/b/" ++ (e(col(r, 0n)) ++ ("/" ++ (e(col(r, 1n)) ++ ("\">" ++ (e(col(r, 2n)) ++ ("</a> <small>in " ++ (e(col(r, 3n)) ++ ("</small></li>" ++ recent_items(t)))))))))

def home_page(rows: List<&2, List<&2, String>>) -> String:
  "<h1>Recent posts</h1><ul class=\"posts\">" ++ (recent_items(rows) ++ "</ul>")

# BLOG
# ----
def post_items(+bslug: String, rows: List<&2, List<&2, String>>) -> String:
  match rows:
    case Nil{}:
      ""
    case Con{+r, t}:
      "<li><a href=\"/b/" ++ (e(bslug) ++ ("/" ++ (e(col(r, 1n)) ++ ("\">" ++ (e(col(r, 2n)) ++ ("</a></li>" ++ post_items(bslug, t)))))))

def blog_page(+slug: String, title: String, rows: List<&2, List<&2, String>>) -> String:
  "<h1>" ++ (e(title) ++ ("</h1><ul class=\"posts\">" ++ (post_items(slug, rows) ++ "</ul>")))

def draft_badge(b: Bool) -> String:
  match b:
    case True{}:
      "<p class=\"badge\">Draft: only authors of this blog can see it.</p>"
    case False{}:
      ""

# POST (the stored body is spliced in between the two halves)
def post_before(+blog_slug: String, blog_title: String, title: String, draft: Bool) -> String:
  "<article><p class=\"crumb\"><a href=\"/b/" ++ (e(blog_slug) ++ ("\">" ++ (e(blog_title) ++ ("</a></p><h1>" ++ (e(title) ++ ("</h1>" ++ (draft_badge(draft) ++ "<div class=\"body\">")))))))

def post_after() -> String:
  "</div></article>"

def role_name.go(b: Bool) -> String:
  match b:
    case True{}:
      "owner"
    case False{}:
      "author"

# DASHBOARD
# ---------
def role_name(+r: String) -> String:
  role_name.go(String.eq(r, "1"))

def my_blog_items(rows: List<&2, List<&2, String>>) -> String:
  match rows:
    case Nil{}:
      ""
    case Con{+r, t}:
      "<li><a href=\"/dash/" ++ (e(col(r, 1n)) ++ ("\">" ++ (e(col(r, 2n)) ++ ("</a> <small>" ++ (role_name(col(r, 3n)) ++ ("</small></li>" ++ my_blog_items(t)))))))

def dash_page(rows: List<&2, List<&2, String>>) -> String:
  "<h1>Your blogs</h1><ul class=\"posts\">" ++ (my_blog_items(rows) ++ ("</ul><h2>New blog</h2><form method=\"post\" action=\"/blogs\"><label>Address <input name=\"slug\" required maxlength=\"64\" pattern=\"[a-z0-9-]+\" placeholder=\"my-blog\"></label><label>Title <input name=\"title\" required maxlength=\"200\"></label><button>Create</button></form>"))

def state_name.go(b: Bool) -> String:
  match b:
    case True{}:
      "published"
    case False{}:
      "draft"

def state_name(+p: String) -> String:
  state_name.go(String.eq(p, "1"))

def member_post_items(rows: List<&2, List<&2, String>>) -> String:
  match rows:
    case Nil{}:
      ""
    case Con{+r, t}:
      "<li><a href=\"/edit/" ++ (e(col(r, 0n)) ++ ("\">" ++ (e(col(r, 2n)) ++ ("</a> <small>" ++ (state_name(col(r, 3n)) ++ ("</small></li>" ++ member_post_items(t)))))))

def remove_button(b: Bool, +blog: String, uid: String) -> String:
  match b:
    case True{}:
      "<form method=\"post\" action=\"/dash/" ++ (e(blog) ++ ("/authors/" ++ (e(uid) ++ "/remove\"><button>Remove</button></form>")))
    case False{}:
      ""

def author_items(+blog: String, +is_owner: Bool, rows: List<&2, List<&2, String>>) -> String:
  match rows:
    case Nil{}:
      ""
    case Con{+r, t}:
      "<li>" ++ (e(col(r, 1n)) ++ (" <small>" ++ (e(col(r, 2n)) ++ (", " ++ (role_name(col(r, 3n)) ++ ("</small>" ++ (remove_button(Bool.and(is_owner, Bool.not(String.eq(col(r, 3n), "1"))), blog, col(r, 0n)) ++ ("</li>" ++ author_items(blog, is_owner, t)))))))))

def owner_tools(b: Bool, +blog: String) -> String:
  match b:
    case True{}:
      "<h2>Add an author</h2><form method=\"post\" action=\"/dash/" ++ (e(blog) ++ "/authors\"><label>Email <input name=\"email\" type=\"email\" required></label><button>Add</button></form>")
    case False{}:
      ""

def dash_blog(+slug: String, title: String, +is_owner: Bool, posts: List<&2, List<&2, String>>, authors: List<&2, List<&2, String>>) -> String:
  "<p class=\"crumb\"><a href=\"/dash\">Dashboard</a> / <a href=\"/b/" ++ (e(slug) ++ ("\">view blog</a></p><h1>" ++ (e(title) ++ ("</h1><h2>Posts</h2><ul class=\"posts\">" ++ (member_post_items(posts) ++ ("</ul><h2>New post</h2><form method=\"post\" action=\"/dash/" ++ (e(slug) ++ ("/posts\"><label>Address <input name=\"slug\" required maxlength=\"64\" pattern=\"[a-z0-9-]+\"></label><label>Title <input name=\"title\" required maxlength=\"200\"></label><button>Create</button></form><h2>Authors</h2><ul>" ++ (author_items(slug, is_owner, authors) ++ ("</ul>" ++ owner_tools(is_owner, slug)))))))))))

# EDITOR
# ------
def edit_page(+id: String, +rep: String, title: String, md: String) -> String:
  "<p class=\"crumb\"><a href=\"/dash\">Dashboard</a> <span id=\"sync-status\"></span></p><form method=\"post\" action=\"/edit/" ++ (e(id) ++ ("\" class=\"editor\"><label>Title <input name=\"title\" required maxlength=\"200\" value=\"" ++ (e(title) ++ ("\"></label><label>Text <textarea id=\"editor\" name=\"body\" rows=\"24\" data-post=\"" ++ (e(id) ++ ("\" data-rep=\"" ++ (e(rep) ++ ("\">" ++ (e(md) ++ ("</textarea></label><button>Save and render</button></form><div class=\"row\"><form method=\"post\" action=\"/edit/" ++ (e(id) ++ ("/publish\"><button>Publish</button></form><form method=\"post\" action=\"/edit/" ++ (e(id) ++ ("/unpublish\"><button>Unpublish</button></form><form method=\"post\" action=\"/edit/" ++ (e(id) ++ "/delete\"><button>Delete</button></form></div><script type=\"module\" src=\"/s/editor.js\"></script>")))))))))))))))
