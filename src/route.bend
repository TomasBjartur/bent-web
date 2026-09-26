# Routing and planning. Pure.
#
# plan(head) decides what a request may do: read (GET, HEAD), write (POST,
# only with a same-origin Sec-Fetch-Site), or be denied. The IO layer only
# writes for Write plans. LAWS.bend: route_csrf and route_get_reads.
import Base
import ../spec/csrf.bend as Csrf
import ./http.bend as Http

type Route is Data:
  RHome{}
  RHealth{}
  RBlog{slug: String}
  RPost{blog: String, post: String}
  RDash{}
  RDashBlog{slug: String}
  REdit{post: U32}
  RCreateBlog{}
  RCreatePost{blog: String}
  RSavePost{post: U32}
  RPublish{post: U32}
  RUnpublish{post: U32}
  RDeletePost{post: U32}
  RAddAuthor{blog: String}
  RRemoveAuthor{blog: String, user: U32}
  RLogout{}
  RStatic{name: String}
  RSignupPage{}
  RLoginPage{}
  RVerify{}
  RSignup{}
  RRecover{}
  RRegOptions{}
  RRegister{}
  RLoginOptions{}
  RLogin{}
  RSync{post: U32}
  RAuthor{user: U32}
  RWrite{}
  RFeed{}
  RBlogFeed{blog: String}
  RSearch{}
  RLike{post: U32}
  RComment{post: U32}
  RDeleteComment{comment: U32}
  RReply{comment: U32}
  RLive{post: U32}
  RTag{tag: String}
  RUpload{post: U32}
  RImage{key: String}
  RBlogDomain{blog: String}
  RDomainAsk{}
  RToMain{path: String}
  RNotFound{}

type Plan is Data:
  Read{route: Route}
  Write{route: Route}
  Deny{status: U32}

def texts(xs: List<&2, Http.Seg>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{x, t}:
      Http.Seg.text(x) <> texts(t)

def id_of.go(b: Bool, +s: String) -> U32:
  match b:
    case True{}:
      Maybe.default(&2, U32, U32.read(s), 0)
    case False{}:
      0

# A decimal id (1..9 digits), or 0.
def id_of(+s: String) -> U32:
  id_of.go(Nat.is_le(String.length(s), 9n), s)

def eq(+a: String, +b: String) -> Nat:
  U32.to_nat(Bool.to_u32(String.eq(a, b)))

# GET routes.
def get1(k: Nat, +a: String) -> Route:
  match k:
    case 1n:
      RHealth{}
    case 2n:
      RDash{}
    case 3n:
      RSignupPage{}
    case 4n:
      RLoginPage{}
    case 5n:
      RVerify{}
    case 6n:
      RFeed{}
    case 7n:
      RSearch{}
    case 8n:
      RDomainAsk{}
    case _:
      RNotFound{}

def get2(k: Nat, +b: String) -> Route:
  match k:
    case 1n:
      RBlog{b}
    case 2n:
      RDashBlog{b}
    case 3n:
      REdit{id_of(b)}
    case 4n:
      RStatic{b}
    case 5n:
      RAuthor{id_of(b)}
    case 6n:
      RReply{id_of(b)}
    case 7n:
      RTag{b}
    case 8n:
      RImage{b}
    case 9n:
      RLive{id_of(b)}
    case _:
      RNotFound{}

# /b/<blog>/<post>, /b/<blog>/feed.xml (a post slug never has a '.').
def get3(k: Nat, +b: String, +c: String) -> Route:
  match k:
    case 1n:
      RPost{b, c}
    case 2n:
      RBlogFeed{b}
    case _:
      RNotFound{}

def route_get(xs: List<&2, String>) -> Route:
  match xs:
    case Nil{}:
      RHome{}
    case Con{+a, t}:
      match t:
        case Nil{}:
          get1(Nat.add(eq(a, "healthz"), Nat.add(Nat.mul(eq(a, "dash"), 2n), Nat.add(Nat.mul(eq(a, "signup"), 3n), Nat.add(Nat.mul(eq(a, "login"), 4n), Nat.add(Nat.mul(eq(a, "verify"), 5n), Nat.add(Nat.mul(eq(a, "feed.xml"), 6n), Nat.add(Nat.mul(eq(a, "search"), 7n), Nat.mul(eq(a, "_domain"), 8n)))))))), a)
        case Con{+b, u}:
          match u:
            case Nil{}:
              get2(Nat.add(eq(a, "b"), Nat.add(Nat.mul(eq(a, "dash"), 2n), Nat.add(Nat.mul(eq(a, "edit"), 3n), Nat.add(Nat.mul(eq(a, "s"), 4n), Nat.add(Nat.mul(eq(a, "u"), 5n), Nat.add(Nat.mul(eq(a, "reply"), 6n), Nat.add(Nat.mul(eq(a, "t"), 7n), Nat.add(Nat.mul(eq(a, "img"), 8n), Nat.mul(eq(a, "live"), 9n))))))))), b)
            case Con{+c, v}:
              match v:
                case Nil{}:
                  get3(Nat.mul(eq(a, "b"), Nat.add(1n, eq(c, "feed.xml"))), b, c)
                case Con{d, w}:
                  RNotFound{}

# POST routes.
def post1(k: Nat) -> Route:
  match k:
    case 1n:
      RCreateBlog{}
    case 2n:
      RLogout{}
    case 3n:
      RSignup{}
    case 4n:
      RRecover{}
    case 5n:
      RWrite{}
    case _:
      RNotFound{}

def post2(k: Nat, +b: String) -> Route:
  match k:
    case 1n:
      RSavePost{id_of(b)}
    case 2n:
      RLogin{}
    case 3n:
      RRegister{}
    case 4n:
      RLike{id_of(b)}
    case 5n:
      RComment{id_of(b)}
    case 6n:
      RUpload{id_of(b)}
    case _:
      RNotFound{}

# /dash/<slug>/posts, /dash/<slug>/authors, /edit/<id>/publish,
# /edit/<id>/unpublish, /edit/<id>/delete
def post3(k: Nat, +b: String) -> Route:
  match k:
    case 1n:
      RCreatePost{b}
    case 2n:
      RAddAuthor{b}
    case 3n:
      RPublish{id_of(b)}
    case 4n:
      RUnpublish{id_of(b)}
    case 5n:
      RDeletePost{id_of(b)}
    case 6n:
      RRegOptions{}
    case 7n:
      RLoginOptions{}
    case 8n:
      RSync{id_of(b)}
    case 9n:
      RDeleteComment{id_of(b)}
    case 10n:
      RBlogDomain{b}
    case _:
      RNotFound{}

def post3_old(+a: String, +c: String) -> Nat:
  Nat.add(Nat.mul(eq(a, "dash"), Nat.add(eq(c, "posts"), Nat.mul(eq(c, "authors"), 2n))), Nat.mul(eq(a, "edit"), Nat.add(Nat.mul(eq(c, "publish"), 3n), Nat.add(Nat.mul(eq(c, "unpublish"), 4n), Nat.add(Nat.mul(eq(c, "delete"), 5n), Nat.mul(eq(c, "sync"), 8n))))))

def post3_id(+a: String, +b: String, +c: String) -> Nat:
  Nat.add(Nat.mul(Nat.mul(eq(a, "passkey"), eq(c, "options")), Nat.add(Nat.mul(eq(b, "register"), 6n), Nat.mul(eq(b, "login"), 7n))), Nat.add(Nat.mul(Nat.mul(eq(a, "comment"), eq(c, "delete")), 9n), Nat.add(Nat.mul(Nat.mul(eq(a, "dash"), eq(c, "domain")), 10n), post3_old(a, c))))

# /dash/<slug>/authors/<id>/remove
def post5(k: Nat, +b: String, +d: String) -> Route:
  match k:
    case 1n:
      RRemoveAuthor{b, id_of(d)}
    case _:
      RNotFound{}

def route_post(xs: List<&2, String>) -> Route:
  match xs:
    case Nil{}:
      RNotFound{}
    case Con{+a, t}:
      match t:
        case Nil{}:
          post1(Nat.add(eq(a, "blogs"), Nat.add(Nat.mul(eq(a, "logout"), 2n), Nat.add(Nat.mul(eq(a, "signup"), 3n), Nat.add(Nat.mul(eq(a, "recover"), 4n), Nat.mul(eq(a, "write"), 5n))))))
        case Con{+b, u}:
          match u:
            case Nil{}:
              post2(Nat.add(eq(a, "edit"), Nat.add(Nat.mul(eq(a, "passkey"), Nat.add(Nat.mul(eq(b, "login"), 2n), Nat.mul(eq(b, "register"), 3n))), Nat.add(Nat.mul(eq(a, "like"), 4n), Nat.add(Nat.mul(eq(a, "comment"), 5n), Nat.mul(eq(a, "upload"), 6n))))), b)
            case Con{+c, v}:
              match v:
                case Nil{}:
                  post3(post3_id(a, b, c), b)
                case Con{+d, w}:
                  match w:
                    case Nil{}:
                      RNotFound{}
                    case Con{+e, z}:
                      match z:
                        case Nil{}:
                          post5(U32.to_nat(Bool.to_u32(Bool.and(String.eq(a, "dash"), Bool.and(String.eq(c, "authors"), String.eq(e, "remove"))))), b, d)
                        case Con{f, y}:
                          RNotFound{}

def site_of(h: Http.Hdrs) -> Maybe<&2, String>:
  match h:
    case Http.Hdrs{host, cookie, clen, ctype, origin, site, ds}:
      match site:
        case None{}:
          None{}
        case Some{v}:
          Some{Http.Hval.text(v)}

def plan_post(ok: Bool, path: Http.Path) -> Plan:
  match ok:
    case True{}:
      Write{route_post(texts(Http.Path.segs(path)))}
    case False{}:
      Deny{403}

def plan(h: Http.Head) -> Plan:
  match h:
    case Http.Head{m, path, q, hdrs}:
      match m:
        case Http.GET{}:
          Read{route_get(texts(Http.Path.segs(path)))}
        case Http.HEAD{}:
          Read{route_get(texts(Http.Path.segs(path)))}
        case Http.POST{}:
          plan_post(Csrf.csrf_ok(site_of(hdrs)), path)
        case _:
          Deny{405}

# CUSTOM DOMAINS
# --------------
# A request to a blog's own domain (verified by DNS) can only read: "/" is
# the blog, "/feed.xml" its feed, "/<post>" and "/b/<blog>/<post>" its
# posts, "/s/..." and "/img/..." as usual. Anything else (logging in,
# writing, other blogs) goes to the main site, where sessions and passkeys
# live. Every POST is denied. LAWS.bend: route_custom_reads.
def path_of(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}:
      ""
    case Con{x, t}:
      "/" ++ (x ++ path_of(t))

# The site's own one-segment pages go to the main site (a post named like
# one is still at /b/<blog>/<post>).
def site_page(+a: String) -> Bool:
  Bool.or(String.eq(a, "login"), Bool.or(String.eq(a, "signup"), Bool.or(String.eq(a, "dash"), Bool.or(String.eq(a, "search"), Bool.or(String.eq(a, "verify"), String.eq(a, "healthz"))))))

def custom_one.go(k: Nat, +slug: String, +a: String) -> Route:
  match k:
    case 1n:
      RBlogFeed{slug}
    case 2n:
      RToMain{"/" ++ a}
    case _:
      RPost{slug, a}

def custom_one(+slug: String, +a: String) -> Route:
  custom_one.go(Nat.add(eq(a, "feed.xml"), Nat.mul(U32.to_nat(Bool.to_u32(site_page(a))), 2n)), slug, a)

def custom_two(k: Nat, +a: String, +b: String) -> Route:
  match k:
    case 1n:
      RStatic{b}
    case 2n:
      RImage{b}
    case _:
      RToMain{"/" ++ (a ++ ("/" ++ b))}

def custom_three(own: Bool, +slug: String, +a: String, +b: String, +c: String) -> Route:
  match own:
    case True{}:
      RPost{slug, c}
    case False{}:
      RToMain{"/" ++ (a ++ ("/" ++ (b ++ ("/" ++ c))))}

def custom_get(+slug: String, xs: List<&2, String>) -> Route:
  match xs:
    case Nil{}:
      RBlog{slug}
    case Con{+a, t}:
      match t:
        case Nil{}:
          custom_one(slug, a)
        case Con{+b, u}:
          match u:
            case Nil{}:
              custom_two(Nat.add(eq(a, "s"), Nat.mul(eq(a, "img"), 2n)), a, b)
            case Con{+c, v}:
              match v:
                case Nil{}:
                  custom_three(Bool.and(String.eq(a, "b"), String.eq(b, slug)), slug, a, b, c)
                case Con{d, w}:
                  RToMain{path_of(Con{a, Con{b, Con{c, Con{d, w}}}})}

def custom_plan(+slug: String, h: Http.Head) -> Plan:
  match h:
    case Http.Head{m, path, q, hdrs}:
      match m:
        case Http.GET{}:
          Read{custom_get(slug, texts(Http.Path.segs(path)))}
        case Http.HEAD{}:
          Read{custom_get(slug, texts(Http.Path.segs(path)))}
        case Http.POST{}:
          Deny{403}
        case _:
          Deny{405}
