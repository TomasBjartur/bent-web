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
    case _:
      RNotFound{}
def get3(k: Nat, +b: String, +c: String) -> Route:
  match k:
    case 1n:
      RPost{b, c}
    case _:
      RNotFound{}
def route_get(xs: List<&2, String>) -> Route:
  match xs:
    case Nil{}:
      RHome{}
    case Con{+a, t}:
      match t:
        case Nil{}:
          get1(Nat.add(eq(a, "healthz"), Nat.mul(eq(a, "dash"), 2n)), a)
        case Con{+b, u}:
          match u:
            case Nil{}:
              get2(Nat.add(eq(a, "b"), Nat.add(Nat.mul(eq(a, "dash"), 2n), Nat.mul(eq(a, "edit"), 3n))), b)
            case Con{+c, v}:
              match v:
                case Nil{}:
                  get3(eq(a, "b"), b, c)
                case Con{d, w}:
                  RNotFound{}
# POST routes.
def post1(k: Nat) -> Route:
  match k:
    case 1n:
      RCreateBlog{}
    case 2n:
      RLogout{}
    case _:
      RNotFound{}
def post2(k: Nat, +b: String) -> Route:
  match k:
    case 1n:
      RSavePost{id_of(b)}
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
    case _:
      RNotFound{}
def post3_id(+a: String, +c: String) -> Nat:
  Nat.add(Nat.mul(eq(a, "dash"), Nat.add(eq(c, "posts"), Nat.mul(eq(c, "authors"), 2n))), Nat.mul(eq(a, "edit"), Nat.add(Nat.mul(eq(c, "publish"), 3n), Nat.add(Nat.mul(eq(c, "unpublish"), 4n), Nat.mul(eq(c, "delete"), 5n)))))
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
          post1(Nat.add(eq(a, "blogs"), Nat.mul(eq(a, "logout"), 2n)))
        case Con{+b, u}:
          match u:
            case Nil{}:
              post2(eq(a, "edit"), b)
            case Con{+c, v}:
              match v:
                case Nil{}:
                  post3(post3_id(a, c), b)
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
