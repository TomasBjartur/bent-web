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

def render_post(p: R.Post, rest: String) -> String:
  R.Post{+id, title, author, excerpt} = p
  "<article><h2><a href=\"/p/" ++ (U32.show(id) ++ ("\">" ++ R.esc(title, "</a></h2><p class=\"by\">" ++ R.esc(author, "</p><p>" ++ blob(id, "</p></article>\n" ++ rest)))))

def render_posts(ps: List<R.Post>, rest: String) -> String:
  match ps:
    case Nil{}:
      rest
    case Con{p, t}:
      render_post(p, render_posts(t, rest))

def page2() -> String:
  "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n<!doctype html><html><head><meta charset=\"utf-8\"><title>Blog</title></head><body><main>\n" ++ render_posts(R.gen_posts(40n, 0), "</main></body></html>\n")

def page() -> String:
  "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n" ++ R.render_page(R.gen_posts(40n, 0))

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
    l : Listener <- IO.try(Listener, TCP.listen(8084))
    IO.print("serving :8084")
    serve(l)
