# Spike: the Bend HTTP demo, but each response is the full 14.7 KB blog page
# rendered per request (the naive "everything is a Bend String" design).
import Base
import ../render/main.bend as R

def Page.send(sock: Socket, tpl: String) -> IO(Socket & Result<&1, &1, U32 & String, Unit>):
  import "./page_send.c"

# A marker for stored blob `id`: \x01 id \x02. Escaped text never contains
# control characters, so markers cannot be forged by user input.
def blob(+id: U32, rest: String) -> String:
  SCon{Chr{1}, U32.show(id) ++ SCon{Chr{2}, rest}}

# Static template chunk k (see page_send.c).
def chunk(+k: U32, rest: String) -> String:
  SCon{Chr{3}, SCon{Chr{(48 + k : U32)}, rest}}

def render_post(p: R.Post, rest: String) -> String:
  R.Post{+id, title, author, excerpt} = p
  chunk(1, U32.show(id) ++ chunk(2, R.esc(title, chunk(3, R.esc(author, chunk(4, blob(id, chunk(5, rest))))))))

def render_posts(ps: List<R.Post>, rest: String) -> String:
  match ps:
    case Nil{}:
      rest
    case Con{p, t}:
      render_post(p, render_posts(t, rest))

def page2() -> String:
  chunk(0, render_posts(R.gen_posts(40n, 0), chunk(6, "")))

def sent(m: Socket & Result<&1, &1, U32 & String, Unit>) -> IO(Unit):
  (s, r) = m
  Socket.close(s)

def reply(m: Socket & Result<&1, &1, U32 & String, String>) -> IO(Unit):
  (s, r) = m
  match r:
    case Done{req}:
      do IO<Unit>:
        x : Socket & Result<&1, &1, U32 & String, Unit> <- Page.send(s, page2())
        sent(x)
    case Fail{e}:
      Socket.close(s)

def talk(s: Socket) -> IO(Unit):
  do IO<Unit>:
    read : Socket & Result<&1, &1, U32 & String, String> <- TCP.recv(s, 8192)
    reply(read)

def conn(m: Listener & Result<&1, &1, U32 & String, Socket>) -> IO(Listener):
  (l, r) = m
  do IO<Listener>:
    s : Socket <- IO.pass(Socket, r)
    IO.spawn(Unit, talk(s))
    return l

@unsafe
def serve(l: Listener) -> IO(Unit):
  do IO<Unit>:
    m  : Listener & Result<&1, &1, U32 & String, Socket> <- TCP.accept(l)
    l2 : Listener <- conn(m)
    serve(l2)

def main() -> IO(Unit):
  do IO<Unit>:
    l : Listener <- IO.try(Listener, TCP.listen(8085))
    IO.print("serving :8085")
    serve(l)
