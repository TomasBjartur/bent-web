# Spike: render a realistic blog index page (~10 KB) many times, with HTML
# escaping of every user-supplied field. Measures Bend's String cost on the
# workload we actually care about. C twin: main.c.
import Base

type Post is Data:
  Post{id: U32, title: String, author: String, excerpt: String}

# Escaping, written in "prepend onto rest" style so building a page is linear.
def esc_q2(b: Bool, +h: Char, rest: String) -> String:
  match b:
    case True{}:
      "&#39;" ++ rest
    case False{}:
      SCon{h, rest}

def esc_q1(b: Bool, +h: Char, rest: String) -> String:
  match b:
    case True{}:
      "&quot;" ++ rest
    case False{}:
      esc_q2(Char.is_eq(h, '\''), h, rest)

def esc_amp(b: Bool, +h: Char, rest: String) -> String:
  match b:
    case True{}:
      "&amp;" ++ rest
    case False{}:
      esc_q1(Char.is_eq(h, '"'), h, rest)

def esc_gt(b: Bool, +h: Char, rest: String) -> String:
  match b:
    case True{}:
      "&gt;" ++ rest
    case False{}:
      esc_amp(Char.is_eq(h, '&'), h, rest)

def esc_lt(b: Bool, +h: Char, rest: String) -> String:
  match b:
    case True{}:
      "&lt;" ++ rest
    case False{}:
      esc_gt(Char.is_eq(h, '>'), h, rest)

def esc_char(+h: Char, rest: String) -> String:
  esc_lt(Char.is_eq(h, '<'), h, rest)

def esc(s: String, rest: String) -> String:
  match s:
    case SNil{}:
      rest
    case SCon{h, t}:
      esc_char(h, esc(t, rest))

def render_post(p: Post, rest: String) -> String:
  Post{id, title, author, excerpt} = p
  "<article><h2><a href=\"/p/" ++ (U32.show(id) ++ ("\">" ++ esc(title, "</a></h2><p class=\"by\">" ++ esc(author, "</p><p>" ++ esc(excerpt, "</p></article>\n" ++ rest)))))

def render_posts(ps: List<Post>, rest: String) -> String:
  match ps:
    case Nil{}:
      rest
    case Con{p, t}:
      render_post(p, render_posts(t, rest))

def render_page(ps: List<Post>) -> String:
  "<!doctype html><html><head><meta charset=\"utf-8\"><title>Blog</title></head><body><main>\n" ++ render_posts(ps, "</main></body></html>\n")

def excerpt() -> String:
  String.repeat("Lorem ipsum dolor sit amet, <em>consectetur</em> & adipiscing elit. ", 3n)

def gen_posts(+n: Nat, +seed: U32) -> List<Post>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      +i = (seed + U32.from_nat(p) : U32)
      Post{i, "Post " ++ (U32.show(i) ++ " <draft> & notes"), "author" ++ U32.show((i % 7 : U32)), excerpt()} <> gen_posts(p, seed)

# Render the page `n` times (each with fresh data), summing lengths.
def bench(+n: Nat, acc: Nat) -> Nat:
  match n:
    case 0n:
      acc
    case 1n+p:
      +len = String.length(render_page(gen_posts(40n, U32.from_nat(p))))
      bench(p, Nat.add(acc, len))

def main() -> IO(Unit):
  do IO<Unit>:
    +t0 : Nat <- IO.now()
    +total : Nat = bench(2000n, 0n)
    +t1 : Nat <- IO.now()
    IO.print("bytes=" ++ (Nat.show(total) ++ (" ms=" ++ Nat.show(Nat.sub(t1, t0)))))
    IO.print("one page bytes=" ++ Nat.show(String.length(render_page(gen_posts(40n, 0)))))
