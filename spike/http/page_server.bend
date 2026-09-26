# Spike: the Bend HTTP demo, but each response is the full 14.7 KB blog page
# rendered per request (the naive "everything is a Bend String" design).
import Base
import ../render/main.bend as R

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
        x : Socket & Result<&1, &1, U32 & String, Unit> <- TCP.send(s, page())
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
    l : Listener <- IO.try(Listener, TCP.listen(8082))
    IO.print("serving :8082")
    serve(l)
