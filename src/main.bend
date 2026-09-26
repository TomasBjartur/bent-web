# The server: accept connections, read and parse each request, answer it.
import Base
import ./http.bend as Http
import ./net.bend as Net
import ./app.bend as App
import ./db.bend as Db
import ./route.bend as Route
import ./session.bend as Session
import ./handlers.bend as Handlers

def head_timeout() -> U32:
  10000
def body_timeout() -> U32:
  30000
def finish(r: Socket & Result<&1, &1, U32 & String, Unit>) -> IO(Unit):
  (s, x) = r
  Socket.close(s)
def send(s: Socket, resp: App.Resp) -> IO(Unit):
  match resp:
    case App.Resp{status, ctype, body}:
      do IO<Unit>:
        r : Socket & Result<&1, &1, U32 & String, Unit> <- Net.respond(s, status, ctype, body)
        finish(r)
# A failure from the network layer: an HTTP status to answer, or 1 (close).
def fail_answer(b: Bool, s: Socket, +code: U32) -> IO(Unit):
  match b:
    case True{}:
      send(s, App.error_page(code))
    case False{}:
      Socket.close(s)
def net_fail(s: Socket, err: U32 & String) -> IO(Unit):
  (code, msg) = err
  +c = code
  fail_answer(U32.is_ge(c, 400), s, c)
def head_hdrs(h: Http.Head) -> Http.Hdrs:
  match h:
    case Http.Head{m, p, q, hdrs}:
      hdrs
def handle.go(s: Socket, +h: Http.Head, +body: String, +token: String) -> IO(Unit):
  do IO<Unit>:
    +who : U32 <- Db.session_user(token)
    Handlers.exec(s, Route.plan(h), token, who, body)
# A complete request: find the session, plan, execute.
def handle(s: Socket, +h: Http.Head, +body: String) -> IO(Unit):
  +token = Session.token(head_hdrs(h))
  handle.go(s, h, body, token)
def with_body(+h: Http.Head, +prefix: String, r: Socket & Result<&1, &1, U32 & String, String>) -> IO(Unit):
  (s, res) = r
  match res:
    case Fail{err}:
      net_fail(s, err)
    case Done{more}:
      handle(s, h, prefix ++ more)
def body_need.go(enough: Bool, s: Socket, +h: Http.Head, +prefix: String, +clen: U32, +have: U32) -> IO(Unit):
  match enough:
    case True{}:
      handle(s, h, String.take(prefix, U32.to_nat(clen)))
    case False{}:
      do IO<Unit>:
        r : Socket & Result<&1, &1, U32 & String, String> <- Net.read_body(s, (clen - have : U32), body_timeout())
        with_body(h, prefix, r)
# The body is Content-Length bytes: `prefix` came with the head; read the rest.
# Bytes beyond Content-Length would belong to a next request; with
# Connection: close they are dropped.
def body_need(s: Socket, +h: Http.Head, +prefix: String, +clen: U32) -> IO(Unit):
  +have = U32.from_nat(String.length(prefix))
  body_need.go(U32.is_le(clen, have), s, h, prefix, clen, have)
def clen_of(h: Http.Hdrs) -> U32:
  match h:
    case Http.Hdrs{host, cookie, clen, ctype, origin, site, ds}:
      match clen:
        case None{}:
          0
        case Some{c}:
          Http.Clen.n(c)
def head_clen(+h: Http.Head) -> U32:
  match h:
    case Http.Head{m, p, q, hdrs}:
      clen_of(hdrs)
def on_parse(s: Socket, p: Http.Parse) -> IO(Unit):
  match p:
    case Http.PMore{}:
      send(s, App.error_page(400))
    case Http.PBad{code}:
      send(s, App.error_page(code))
    case Http.PDone{+head, body}:
      body_need(s, head, body, head_clen(head))
def on_head(r: Socket & Result<&1, &1, U32 & String, String>) -> IO(Unit):
  (s, res) = r
  match res:
    case Fail{err}:
      net_fail(s, err)
    case Done{buf}:
      on_parse(s, Http.parse(buf))
def conn(s: Socket) -> IO(Unit):
  do IO<Unit>:
    r : Socket & Result<&1, &1, U32 & String, String> <- Net.read_head(s, head_timeout())
    on_head(r)
def accepted(m: Listener & Result<&1, &1, U32 & String, Socket>) -> IO(Listener):
  (l, r) = m
  match r:
    case Fail{e}:
      IO.pure(Listener, l)
    case Done{s}:
      do IO<Listener>:
        IO.spawn(Unit, conn(s))
        return l
# Runs until killed.
@unsafe
def serve(l: Listener) -> IO(Unit):
  do IO<Unit>:
    m  : Listener & Result<&1, &1, U32 & String, Socket> <- TCP.accept(l)
    l2 : Listener <- accepted(m)
    serve(l2)
def port_of(r: Result<&1, &1, U32 & String, String>) -> U32:
  match r:
    case Fail{e}:
      8080
    case Done{s}:
      Maybe.default(&2, U32, U32.read(s), 8080)
def db_path(r: Result<&1, &1, U32 & String, String>) -> String:
  match r:
    case Fail{e}:
      "blog.db"
    case Done{p}:
      p
def main() -> IO(Unit):
  do IO<Unit>:
    env : Result<&1, &1, U32 & String, String> <- IO.get_env("PORT")
    +port : U32 = port_of(env)
    dbenv : Result<&1, &1, U32 & String, String> <- IO.get_env("BLOG_DB")
    IO.try(Unit, Db.db_open(db_path(dbenv)))
    l : Listener <- IO.try(Listener, Net.listen(port))
    IO.print("listening on 127.0.0.1:" ++ U32.show(port))
    serve(l)
