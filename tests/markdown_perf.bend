import Base
import ../spec/markup.bend as M
import ../src/markdown.bend as Md

def time(name: String, +s: String) -> IO(Unit):
  do IO<Unit>:
    +t0 : Nat <- IO.now()
    +n : Nat = String.length(M.html(Md.render(s), ""))
    +t1 : Nat <- IO.now()
    IO.print(name ++ (": in=" ++ (Nat.show(String.length(s)) ++ (" out=" ++ (Nat.show(n) ++ (" ms=" ++ Nat.show(Nat.sub(t1, t0))))))))

def main() -> IO(Unit):
  do IO<Unit>:
    time("plain text 100KB", String.repeat("lorem ipsum dolor sit amet ", 3800n))
    time("backticks 100KB", String.repeat("`", 100000n))
    time("stars 100KB", String.repeat("*", 100000n))
    time("open brackets 100KB", String.repeat("[a](", 25000n))
    time("open brackets only 100KB", String.repeat("[", 100000n))
    time("sparse long unclosed links", String.repeat("[a](" ++ String.repeat("x", 500n), 200n))
    time("nested emphasis", String.repeat("**a *b _c_ b* a** ", 5000n))
    time("many short lines", String.repeat("- item\n", 14000n))
