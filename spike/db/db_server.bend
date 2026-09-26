# Spike: per request, query the 40 most recent post titles of a blog from
# SQLite (on an IO helper thread), escape them in Bend, and send the page
# with static chunks and stored bodies spliced in by C.
import Base
import ../render/main.bend as R

def Db.recent_titles(blog: U32, n: U32) -> IO(Result<&1, &1, U32 & String, List<String>>):
  import "./db_effect.c"

def Page.send(sock: Socket, tpl: String) -> IO(Socket & Result<&1, &1, U32 & String, Unit>):
  import "./page_send.c"

def chunk(+k: U32, rest: String) -> String:
  SCon{Chr{3}, SCon{Chr{(48 + k : U32)}, rest}}

def blob(+id: U32, rest: String) -> String:
  SCon{Chr{1}, U32.show(id) ++ SCon{Chr{2}, rest}}

def render_titles(ts: List<String>, +i: U32, rest: String) -> String:
  match ts:
    case Nil{}:
      rest
    case Con{t, more}:
      chunk(1, U32.show(i) ++ chunk(2, R.esc(t, chunk(3, "author" ++ chunk(4, blob(i, chunk(5, render_titles(more, (i + 1 : U32), rest))))))))

def sent(m: Socket & Result<&1, &1, U32 & String, Unit>) -> IO(Unit):
  (s, r) = m
  Socket.close(s)

def respond(s: Socket, r: Result<&1, &1, U32 & String, List<String>>) -> IO(Unit):
  match r:
    case Done{ts}:
      do IO<Unit>:
        x : Socket & Result<&1, &1, U32 & String, Unit> <- Page.send(s, chunk(0, render_titles(ts, 0, chunk(6, ""))))
        sent(x)
    case Fail{e}:
      Socket.close(s)

def reply(m: Socket & Result<&1, &1, U32 & String, String>) -> IO(Unit):
  (s, r) = m
  match r:
    case Done{req}:
      do IO<Unit>:
        rows : Result<&1, &1, U32 & String, List<String>> <- Db.recent_titles(7, 40)
        respond(s, rows)
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
    l : Listener <- IO.try(Listener, TCP.listen(8087))
    IO.print("serving :8087")
    serve(l)
