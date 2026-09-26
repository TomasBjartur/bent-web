# The application: routes a parsed request to a response. Pure.
import Base
import ./http.bend as Http
import ./html.bend as Html
import ./net.bend as Net

type Resp is Data:
  Resp{status: U32, ctype: U32, body: String}
type Route is Data:
  Home{}
  Health{}
  NotFound{}
def page(title: String, body: String) -> String:
  "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>" ++ (Html.esc(title, "</title></head><body>") ++ (body ++ "</body></html>\n"))
def error_page(+status: U32) -> Resp:
  Resp{status, Net.ct_html(), page("Error " ++ U32.show(status), "<h1>Error " ++ (U32.show(status) ++ "</h1>"))}
def route_pick(k: Nat) -> Route:
  match k:
    case 1n:
      Health{}
    case _:
      NotFound{}
def route_one(+s: String) -> Route:
  route_pick(U32.to_nat((Bool.to_u32(String.eq(s, "healthz")) : U32)))
def route_path(xs: List<&2, Http.Seg>) -> Route:
  match xs:
    case Nil{}:
      Home{}
    case Con{x, t}:
      match t:
        case Nil{}:
          route_one(Http.Seg.text(x))
        case Con{y, u}:
          NotFound{}
def is_get(m: Http.Method) -> Bool:
  match m:
    case Http.GET{}:
      True{}
    case Http.HEAD{}:
      True{}
    case _:
      False{}
def serve_route(r: Route) -> Resp:
  match r:
    case Home{}:
      Resp{200, Net.ct_html(), page("Blog", "<h1>Hello from Bend</h1><p>Proved parser, proved escaping.</p>")}
    case Health{}:
      Resp{200, Net.ct_text(), "ok\n"}
    case NotFound{}:
      error_page(404)
def serve_get(b: Bool, path: Http.Path) -> Resp:
  match b:
    case True{}:
      serve_route(route_path(Http.Path.segs(path)))
    case False{}:
      error_page(405)
def handle(h: Http.Head, body: String) -> Resp:
  match h:
    case Http.Head{m, path, q, hdrs}:
      serve_get(is_get(m), path)
