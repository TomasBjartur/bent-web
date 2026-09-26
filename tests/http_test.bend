# Behavior tests for src/http.bend. Each case prints PASS or FAIL.
# Run: bend tests/http_test.bend
import Base
import ../src/http.bend as H

def show_segs(xs: List<&2, H.Seg>) -> String:
  match xs:
    case Nil{}:
      ""
    case Con{x, t}:
      "/" ++ (H.Seg.text(x) ++ show_segs(t))
def show_method(m: H.Method) -> String:
  match m:
    case H.GET{}:
      "GET"
    case H.HEAD{}:
      "HEAD"
    case H.POST{}:
      "POST"
    case H.PUT{}:
      "PUT"
    case H.PATCH{}:
      "PATCH"
    case H.DELETE{}:
      "DELETE"
def show_hv(m: Maybe<&2, H.Hval>) -> String:
  match m:
    case None{}:
      "-"
    case Some{v}:
      H.Hval.text(v)
def show_clen(m: Maybe<&2, H.Clen>) -> String:
  match m:
    case None{}:
      "-"
    case Some{v}:
      U32.show(H.Clen.n(v))
def show_hdrs(h: H.Hdrs) -> String:
  match h:
    case H.Hdrs{host, cookie, clen, ctype, origin, site, ds}:
      " host=" ++ (show_hv(host) ++ (" cookie=" ++ (show_hv(cookie) ++ (" clen=" ++ (show_clen(clen) ++ (" origin=" ++ (show_hv(origin) ++ (" site=" ++ show_hv(site)))))))))
def show_path(p: H.Path) -> String:
  match p:
    case H.Path{xs, pf}:
      match xs:
        case Nil{}:
          "/"
        case Con{x, t}:
          show_segs(x <> t)
def show(p: H.Parse) -> String:
  match p:
    case H.PMore{}:
      "more"
    case H.PBad{code}:
      "bad " ++ U32.show(code)
    case H.PDone{head, body}:
      match head:
        case H.Head{m, path, q, h}:
          "ok " ++ (show_method(m) ++ (" " ++ (show_path(path) ++ (" q=" ++ (H.Query.text(q) ++ (show_hdrs(h) ++ (" body=" ++ body)))))))
def check_msg(ok: Bool, name: String, got: String, want: String) -> String:
  match ok:
    case True{}:
      "PASS " ++ name
    case False{}:
      "FAIL " ++ (name ++ ("\n  got:  " ++ (got ++ ("\n  want: " ++ want))))
def check(name: String, input: String, +want: String) -> IO(Unit):
  +got = show(H.parse(input))
  IO.print(check_msg(String.eq(got, want), name, got, want))
def crlf(s: String) -> String:
  s ++ "\r\n"
def lines(hs: List<&2, String>) -> String:
  match hs:
    case Nil{}:
      ""
    case Con{h, t}:
      crlf(h) ++ lines(t)
def req(line: String, hs: List<&2, String>, body: String) -> String:
  crlf(line) ++ (lines(hs) ++ ("\r\n" ++ body))
def many(n: Nat) -> List<&2, String>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      "X-A: b" <> many(p)
def main() -> IO(Unit):
  do IO<Unit>:
    check("root", req("GET / HTTP/1.1", ["Host: x"], ""), "ok GET / q= host=x cookie=- clen=- origin=- site=- body=")
    check("path+query", req("GET /a/b-c_d.e~f?x=1&y=2 HTTP/1.1", ["Host: x"], ""), "ok GET /a/b-c_d.e~f q=x=1&y=2 host=x cookie=- clen=- origin=- site=- body=")
    check("incomplete head", "GET / HTTP/1.1\r\nHost: x\r\n", "more")
    check("incomplete line", "GET / HTT", "more")
    check("empty", "", "more")
    check("dotdot", req("GET /../etc HTTP/1.1", [], ""), "bad 400")
    check("dot", req("GET /a/./b HTTP/1.1", [], ""), "bad 400")
    check("empty seg", req("GET /a//b HTTP/1.1", [], ""), "bad 400")
    check("trailing slash", req("GET /a/ HTTP/1.1", [], ""), "bad 400")
    check("encoded dots", req("GET /a/%2e%2e HTTP/1.1", [], ""), "bad 400")
    check("no leading slash", req("GET a HTTP/1.1", [], ""), "bad 400")
    check("absolute form", req("GET http://x/ HTTP/1.1", [], ""), "bad 400")
    check("http/1.0", req("GET / HTTP/1.0", [], ""), "bad 505")
    check("unknown method", req("BREW / HTTP/1.1", [], ""), "bad 501")
    check("double space", req("GET  / HTTP/1.1", [], ""), "bad 400")
    check("bare LF", "GET / HTTP/1.1\nHost: x\n\n", "bad 400")
    check("bare CR", "GET / HTTP/1.1\rHost: x\r\n\r\n", "bad 400")
    check("transfer-encoding", req("POST / HTTP/1.1", ["Host: x", "Transfer-Encoding: chunked"], ""), "bad 501")
    check("dup content-length", req("POST / HTTP/1.1", ["Content-Length: 1", "Content-Length: 1"], "a"), "bad 400")
    check("dup host", req("GET / HTTP/1.1", ["Host: a", "host: b"], ""), "bad 400")
    check("body", req("POST /p HTTP/1.1", ["Host: x", "Content-Length: 5"], "hello"), "ok POST /p q= host=x cookie=- clen=5 origin=- site=- body=hello")
    check("clen too big", req("POST / HTTP/1.1", ["Content-Length: 2000000"], ""), "bad 400")
    check("clen not digits", req("POST / HTTP/1.1", ["Content-Length: +5"], ""), "bad 400")
    check("ctl in value", req("GET / HTTP/1.1", ["Cookie: a" ++ SCon{Chr{1}, "b"}], ""), "bad 400")
    check("space in name", req("GET / HTTP/1.1", ["Bad Name: x"], ""), "bad 400")
    check("space before colon", req("GET / HTTP/1.1", ["Host : x"], ""), "bad 400")
    check("obs-fold", req("GET / HTTP/1.1", ["Host: x", " folded"], ""), "bad 400")
    check("case + trim", req("GET / HTTP/1.1", ["HOST:   x  ", "Sec-Fetch-Site: same-origin", "Origin: https://a.b"], ""), "ok GET / q= host=x cookie=- clen=- origin=https://a.b site=same-origin body=")
    check("64 headers ok", req("GET / HTTP/1.1", many(64n), ""), "ok GET / q= host=- cookie=- clen=- origin=- site=- body=")
    check("65 headers", req("GET / HTTP/1.1", many(65n), ""), "bad 431")
    check("17 segments", req("GET /a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a HTTP/1.1", [], ""), "bad 400")
    check("16 segments", req("GET /a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a HTTP/1.1", [], ""), "ok GET /a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a q= host=- cookie=- clen=- origin=- site=- body=")
    check("long line", req("GET /" ++ (String.repeat("a", 4200n) ++ " HTTP/1.1"), [], ""), "bad 400")
    check("long seg", req("GET /" ++ (String.repeat("a", 129n) ++ " HTTP/1.1"), [], ""), "bad 400")
    check("bad query char", req("GET /?a=<b> HTTP/1.1", [], ""), "bad 400")
    check("high byte in path", req("GET /" ++ (SCon{Chr{200}, ""} ++ " HTTP/1.1"), [], ""), "bad 400")
