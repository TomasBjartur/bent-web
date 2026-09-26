# The server: accept connections, read and parse each request, answer it.
#
# Configuration (environment): PORT (8080), BLOG_DB (blog.db),
# BLOG_ORIGIN (http://localhost:8080) and BLOG_RP_ID (localhost): the
# origin browsers report and the WebAuthn relying-party id.
import Base
import ./http.bend as Http
import ./net.bend as Net
import ./app.bend as App
import ./db.bend as Db
import ./route.bend as Route
import ./session.bend as Session
import ./handlers.bend as Handlers
import ./auth.bend as Auth

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

def head_query(h: Http.Head) -> String:
  match h:
    case Http.Head{m, p, q, hdrs}:
      Http.Query.text(q)

def head_hdrs(h: Http.Head) -> Http.Hdrs:
  match h:
    case Http.Head{m, p, q, hdrs}:
      hdrs

def handle.go(s: Socket, +c: Auth.Conf, +h: Http.Head, +body: String, +token: String) -> IO(Unit):
  do IO<Unit>:
    Db.tick()
    +who : U32 <- Db.session_user(token)
    Handlers.exec(s, Route.plan(h), c, token, who, body, head_query(h))

# A complete request: find the session, plan, execute.
def handle(s: Socket, +c: Auth.Conf, +h: Http.Head, +body: String) -> IO(Unit):
  handle.go(s, c, h, body, Session.token(head_hdrs(h)))

def with_body(+c: Auth.Conf, +h: Http.Head, +prefix: String, r: Socket & Result<&1, &1, U32 & String, String>) -> IO(Unit):
  (s, res) = r
  match res:
    case Fail{err}:
      net_fail(s, err)
    case Done{more}:
      handle(s, c, h, prefix ++ more)

# The body is Content-Length bytes: `prefix` came with the head; read the
# rest. Bytes beyond Content-Length would belong to a next request; with
# Connection: close they are dropped.
def body_need.go(enough: Bool, s: Socket, +c: Auth.Conf, +h: Http.Head, +prefix: String, +clen: U32, +have: U32) -> IO(Unit):
  match enough:
    case True{}:
      handle(s, c, h, String.take(prefix, U32.to_nat(clen)))
    case False{}:
      do IO<Unit>:
        r : Socket & Result<&1, &1, U32 & String, String> <- Net.read_body(s, (clen - have : U32), body_timeout())
        with_body(c, h, prefix, r)

def body_need(s: Socket, +c: Auth.Conf, +h: Http.Head, +prefix: String, +clen: U32) -> IO(Unit):
  +have = U32.from_nat(String.length(prefix))
  body_need.go(U32.is_le(clen, have), s, c, h, prefix, clen, have)

def clen_of(h: Http.Hdrs) -> U32:
  match h:
    case Http.Hdrs{host, cookie, clen, ctype, origin, site, ds}:
      match clen:
        case None{}:
          0
        case Some{x}:
          Http.Clen.n(x)

def head_clen(+h: Http.Head) -> U32:
  clen_of(head_hdrs(h))

def on_parse(s: Socket, +c: Auth.Conf, p: Http.Parse) -> IO(Unit):
  match p:
    case Http.PMore{}:
      send(s, App.error_page(400))
    case Http.PBad{code}:
      send(s, App.error_page(code))
    case Http.PDone{+head, body}:
      body_need(s, c, head, body, head_clen(head))

def on_head(+c: Auth.Conf, r: Socket & Result<&1, &1, U32 & String, String>) -> IO(Unit):
  (s, res) = r
  match res:
    case Fail{err}:
      net_fail(s, err)
    case Done{buf}:
      on_parse(s, c, Http.parse(buf))

def conn(+c: Auth.Conf, s: Socket) -> IO(Unit):
  do IO<Unit>:
    r : Socket & Result<&1, &1, U32 & String, String> <- Net.read_head(s, head_timeout())
    on_head(c, r)

def accepted(+c: Auth.Conf, m: Listener & Result<&1, &1, U32 & String, Socket>) -> IO(Listener):
  (l, r) = m
  match r:
    case Fail{e}:
      IO.pure(Listener, l)
    case Done{s}:
      do IO<Listener>:
        IO.spawn(Unit, conn(c, s))
        return l

# Runs until killed.
@unsafe
def serve(+c: Auth.Conf, l: Listener) -> IO(Unit):
  do IO<Unit>:
    m  : Listener & Result<&1, &1, U32 & String, Socket> <- TCP.accept(l)
    l2 : Listener <- accepted(c, m)
    serve(c, l2)

def env_or(r: Result<&1, &1, U32 & String, String>, +d: String) -> String:
  match r:
    case Fail{e}:
      d
    case Done{v}:
      v

def main() -> IO(Unit):
  do IO<Unit>:
    port_env : Result<&1, &1, U32 & String, String> <- IO.get_env("PORT")
    +port : U32 = Maybe.default(&2, U32, U32.read(env_or(port_env, "8080")), 8080)
    db_env : Result<&1, &1, U32 & String, String> <- IO.get_env("BLOG_DB")
    IO.try(Unit, Db.db_open(env_or(db_env, "blog.db")))
    origin_env : Result<&1, &1, U32 & String, String> <- IO.get_env("BLOG_ORIGIN")
    rp_env : Result<&1, &1, U32 & String, String> <- IO.get_env("BLOG_RP_ID")
    direct_env : Result<&1, &1, U32 & String, String> <- IO.get_env("BLOG_SIGNUP_DIRECT")
    +c : Auth.Conf <- Auth.conf(env_or(origin_env, "http://localhost:" ++ U32.show(port)), env_or(rp_env, "localhost"), String.eq(env_or(direct_env, "0"), "1"))
    l : Listener <- IO.try(Listener, Net.listen(port))
    IO.print("listening on 127.0.0.1:" ++ U32.show(port))
    serve(c, l)
