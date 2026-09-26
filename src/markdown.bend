# Markdown (a small, predictable subset) to spec/markup.bend's Node.
#
# Safety does not depend on this file: whatever it builds is a Node, and a
# Node can only serialize to allowed markup (spec/markup.bend). Bugs here
# can only mis-format a post.
#
# Blocks: paragraphs (blank-line separated), "# "/"## " (h2) and "### "
# (h3) headings, "- "/"* " lists, "1. " numbered lists, "> " quotes, and
# ``` fenced code. Inline: **strong**, *em* / _em_, `code`, [text](url)
# (url must pass url_ok, else the brackets stay literal), and \x to write
# x literally. Every search for a closing marker stops at the first match
# and is bounded (128 characters; 256 for link text, 512 for URLs), so
# rendering is linear in the input with a small constant.
import Base
import ../spec/markup.bend as M
import ./text.bend as Text

# What the text at the current position starts: 0 a plain character,
# 1 a code span of a characters, 2 strong (a characters inside **...**),
# 3 em with '*', 4 em with '_', 5 a link ([a characters](b characters)),
# 6 an escaped character, 9 the end.
type Act is Data:
  Act{kind: Nat, a: Nat, b: Nat}

# HTML that is, provably, spec/markup.bend's serialization of a Node. The
# database write for post bodies takes only this (src/db.bend).
type Rendered is Data:
  Rendered{node: M.Node, html: String, pf: {html == M.html(node, "") : String}}

def head(s: String) -> Char:
  match s:
    case SNil{}:
      Chr{0}
    case SCon{c, t}:
      c

def tail(s: String) -> String:
  match s:
    case SNil{}:
      SNil{}
    case SCon{c, t}:
      t

# Index of the first c within the first n characters of s. `hit` says
# whether s starts with c, so a match stops the scan (Bend is strict: a
# helper that picked between "here" and a recursive result would always
# pay for the whole window).
def find_go(n: Nat, hit: Bool, +i: Nat, +s: String, +c: Char) -> Maybe<&2, Nat>:
  match n:
    case 0n:
      None{}
    case 1n+p:
      match hit:
        case True{}:
          Some{i}
        case False{}:
          match s:
            case SNil{}:
              None{}
            case SCon{h, t}:
              find_go(p, Char.is_eq(head(t), c), 1n+i, t, c)

def find_char(+n: Nat, +s: String, +c: Char) -> Maybe<&2, Nat>:
  find_go(n, Bool.and(Bool.not(String.is_empty(s)), Char.is_eq(head(s), c)), 0n, s, c)

def find_sgo(n: Nat, hit: Bool, +i: Nat, +s: String, +pat: String) -> Maybe<&2, Nat>:
  match n:
    case 0n:
      None{}
    case 1n+p:
      match hit:
        case True{}:
          Some{i}
        case False{}:
          match s:
            case SNil{}:
              None{}
            case SCon{h, +t}:
              find_sgo(p, String.starts_with(t, pat), 1n+i, t, pat)

def kb.pick(close: Bool, stop: Bool) -> Nat:
  match close stop:
    case True{} _:
      1n
    case _ True{}:
      2n
    case _ _:
      0n

# Class of the next character for a bracket scan: 1 ']', 2 '[' or a line
# break (the link text cannot contain them), 3 end, 0 anything else.
def kb(s: String) -> Nat:
  match s:
    case SNil{}:
      3n
    case SCon{+c, t}:
      kb.pick(Char.is_eq(c, ']'), Bool.or(Char.is_eq(c, '['), Char.is_eq(c, '\n')))

# Class of the next character for a URL scan: 1 ')', 2 whitespace, '[' or
# '(' (a URL here cannot contain them), 3 end, 0 anything else.
def kp(s: String) -> Nat:
  match s:
    case SNil{}:
      3n
    case SCon{+c, t}:
      kb.pick(Char.is_eq(c, ')'), Bool.or(Char.is_eq(c, ' '), Bool.or(Char.is_eq(c, '\n'), Bool.or(Char.is_eq(c, '\t'), Bool.or(Char.is_eq(c, '['), Char.is_eq(c, '('))))))

# Index of the first ']' (bracket) or ')' (url) within n characters, unless
# a stop character comes first. Stopping keeps link scanning linear.
def scan_go(n: Nat, url: Bool, k: Nat, +i: Nat, +s: String) -> Maybe<&2, Nat>:
  match n:
    case 0n:
      None{}
    case 1n+p:
      match url:
        case True{}:
          match k:
            case 1n:
              Some{i}
            case 0n:
              scan_go(p, True{}, kp(tail(s)), 1n+i, tail(s))
            case _:
              None{}
        case False{}:
          match k:
            case 1n:
              Some{i}
            case 0n:
              scan_go(p, False{}, kb(tail(s)), 1n+i, tail(s))
            case _:
              None{}

def find_bracket(+n: Nat, +s: String) -> Maybe<&2, Nat>:
  scan_go(n, False{}, kb(s), 0n, s)

def find_paren(+n: Nat, +s: String) -> Maybe<&2, Nat>:
  scan_go(n, True{}, kp(s), 0n, s)

# Index of the first occurrence of pat within the first n positions of s.
def find_str(+n: Nat, +s: String, +pat: String) -> Maybe<&2, Nat>:
  find_sgo(n, String.starts_with(s, pat), 0n, s, pat)

def plain() -> Act:
  Act{0n, 0n, 0n}

def span.go(empty: Bool, +k: Nat, +i: Nat) -> Act:
  match empty:
    case True{}:
      plain()
    case False{}:
      Act{k, i, 0n}

# A span of length i >= 1 closed by a marker.
def span(+k: Nat, m: Maybe<&2, Nat>) -> Act:
  match m:
    case None{}:
      plain()
    case Some{+i}:
      span.go(Nat.is_eq(i, 0n), k, i)

def link_ok(b: Bool, +i: Nat, +j: Nat) -> Act:
  match b:
    case True{}:
      Act{5n, i, j}
    case False{}:
      plain()

def link_url(+i: Nat, mj: Maybe<&2, Nat>, +after: String) -> Act:
  match mj:
    case None{}:
      plain()
    case Some{+j}:
      link_ok(M.url_ok(String.take(after, j)), i, j)

def bracket_paren.go(b: Bool, +i: Nat) -> Maybe<&2, Nat>:
  match b:
    case True{}:
      Some{i}
    case False{}:
      None{}

# The ']' found must be followed by '('.
def bracket_paren(m: Maybe<&2, Nat>, +t: String) -> Maybe<&2, Nat>:
  match m:
    case None{}:
      None{}
    case Some{+i}:
      bracket_paren.go(String.starts_with(String.drop(t, i), "]("), i)

def link_act(mi: Maybe<&2, Nat>, +rest: String) -> Act:
  match mi:
    case None{}:
      plain()
    case Some{+i}:
      link_url(i, find_paren(512n, String.drop(rest, Nat.add(i, 2n))), String.drop(rest, Nat.add(i, 2n)))

def star(two: Bool, +s: String) -> Act:
  match two:
    case True{}:
      span(2n, find_str(128n, String.drop(s, 2n), "**"))
    case False{}:
      span(3n, find_char(128n, String.drop(s, 1n), '*'))

def classify.pick(k: Nat, +s: String, +t: String) -> Act:
  match k:
    case 1n:
      span(1n, find_char(128n, t, '`'))
    case 2n:
      star(String.starts_with(s, "**"), s)
    case 3n:
      span(4n, find_char(128n, t, '_'))
    case 4n:
      link_act(bracket_paren(find_bracket(256n, t), t), t)
    case 5n:
      Act{6n, 0n, 0n}
    case _:
      plain()

def mark(a: Bool, b: Bool, c: Bool, d: Bool, e: Bool) -> Nat:
  match a b c d e:
    case True{} _ _ _ _:
      1n
    case _ True{} _ _ _:
      2n
    case _ _ True{} _ _:
      3n
    case _ _ _ True{} _:
      4n
    case _ _ _ _ True{}:
      5n
    case _ _ _ _ _:
      0n

def classify(+s: String) -> Act:
  match s:
    case SNil{}:
      Act{9n, 0n, 0n}
    case SCon{+c, +t}:
      classify.pick(mark(Char.is_eq(c, '`'), Char.is_eq(c, '*'), Char.is_eq(c, '_'), Char.is_eq(c, '['), Char.is_eq(c, '\\')), s, t)

def seq(a: M.Node, b: M.Node) -> M.Node:
  M.Seq{a, b}

def text(+acc: String) -> M.Node:
  M.Text{String.reverse(acc)}

def mk_link.go(b: Bool, +url: String, kids: M.Node, e: {M.url_ok(url) == b : Bool}) -> M.Node:
  match b:
    case True{}:
      M.Link{url, e, kids}
    case False{}:
      kids

def mk_link(+url: String, kids: M.Node) -> M.Node:
  mk_link.go(M.url_ok(url), url, kids, {==})

# n: fuel. act: what s starts. acc: plain text so far (reversed).
# out: what came before.
def inl(+n: Nat, act: Act, +s: String, +acc: String, out: M.Node) -> M.Node:
  match n:
    case 0n:
      seq(out, text(acc))
    case 1n+p:
      match act:
        case Act{kind, +a, +b}:
          match kind:
            case 9n:
              seq(out, text(acc))
            case 1n:
              inl(p, classify(String.drop(s, Nat.add(a, 2n))), String.drop(s, Nat.add(a, 2n)), "", seq(seq(out, text(acc)), M.El{M.Code{}, M.Text{String.take(String.drop(s, 1n), a)}}))
            case 2n:
              inl(p, classify(String.drop(s, Nat.add(a, 4n))), String.drop(s, Nat.add(a, 4n)), "", seq(seq(out, text(acc)), M.El{M.Strong{}, inl(p, classify(String.take(String.drop(s, 2n), a)), String.take(String.drop(s, 2n), a), "", M.Empty{})}))
            case 3n:
              inl(p, classify(String.drop(s, Nat.add(a, 2n))), String.drop(s, Nat.add(a, 2n)), "", seq(seq(out, text(acc)), M.El{M.Em{}, inl(p, classify(String.take(String.drop(s, 1n), a)), String.take(String.drop(s, 1n), a), "", M.Empty{})}))
            case 4n:
              inl(p, classify(String.drop(s, Nat.add(a, 2n))), String.drop(s, Nat.add(a, 2n)), "", seq(seq(out, text(acc)), M.El{M.Em{}, inl(p, classify(String.take(String.drop(s, 1n), a)), String.take(String.drop(s, 1n), a), "", M.Empty{})}))
            case 5n:
              inl(p, classify(String.drop(s, Nat.add(Nat.add(a, b), 4n))), String.drop(s, Nat.add(Nat.add(a, b), 4n)), "", seq(seq(out, text(acc)), mk_link(String.take(String.drop(s, Nat.add(a, 3n)), b), inl(p, classify(String.take(String.drop(s, 1n), a)), String.take(String.drop(s, 1n), a), "", M.Empty{}))))
            case 6n:
              inl(p, classify(String.drop(s, 2n)), String.drop(s, 2n), SCon{head(String.drop(s, 1n)), acc}, out)
            case _:
              inl(p, classify(String.drop(s, 1n)), String.drop(s, 1n), SCon{head(s), acc}, out)

def inline(+s: String) -> M.Node:
  inl(Nat.add(String.length(s), 1n), classify(s), s, "", M.Empty{})

def digits.go(b: Bool, +r: Nat) -> Nat:
  match b:
    case True{}:
      1n+r
    case False{}:
      0n

# Line kinds: 0 blank, 1 "# " or "## ", 2 "### ", 3 "- " or "* ", 4 "N. ",
# 5 "> ", 6 "```", 7 text.
def digits(s: String) -> Nat:
  match s:
    case SNil{}:
      0n
    case SCon{+c, t}:
      digits.go(Char.is_digit(c), digits(t))

def ol_prefix.ok(b: Bool, +d: Nat) -> Nat:
  match b:
    case True{}:
      Nat.add(d, 2n)
    case False{}:
      0n

def ol_prefix.go(+d: Nat, +s: String) -> Nat:
  ol_prefix.ok(Bool.and(Bool.not(Nat.is_eq(d, 0n)), Bool.and(Nat.is_le(d, 9n), String.starts_with(String.drop(s, d), ". "))), d)

# "12. text": the length of the "12. " prefix, or 0.
def ol_prefix(+s: String) -> Nat:
  ol_prefix.go(digits(s), s)

def kind_of.pick(h3: Bool, h2: Bool, ul: Bool, ol: Bool, q: Bool, f: Bool) -> Nat:
  match h3 h2 ul ol q f:
    case True{} _ _ _ _ _:
      2n
    case _ True{} _ _ _ _:
      1n
    case _ _ True{} _ _ _:
      3n
    case _ _ _ True{} _ _:
      4n
    case _ _ _ _ True{} _:
      5n
    case _ _ _ _ _ True{}:
      6n
    case _ _ _ _ _ _:
      7n

def kind_of.go(blank: Bool, +l: String) -> Nat:
  match blank:
    case True{}:
      0n
    case False{}:
      kind_of.pick(String.starts_with(l, "### "), Bool.or(String.starts_with(l, "## "), String.starts_with(l, "# ")), Bool.or(String.starts_with(l, "- "), String.starts_with(l, "* ")), Bool.not(Nat.is_eq(ol_prefix(l), 0n)), Bool.or(String.starts_with(l, "> "), String.eq(l, ">")), String.starts_with(l, "```"))

def kind_of(+l: String) -> Nat:
  kind_of.go(String.is_empty(String.trim(l)), l)

def digits_hash(s: String) -> Nat:
  match s:
    case SNil{}:
      0n
    case SCon{+c, t}:
      digits.go(Char.is_eq(c, '#'), digits_hash(t))

# The text of a heading line: after its "#"s and one space.
def heading_text(+l: String) -> String:
  String.trim(String.drop(l, Nat.add(digits_hash(l), 1n)))

def join(xs: List<&2, String>, +sep: String) -> String:
  String.join(List.reverse(&2, String, xs), sep)

# Items (reversed) as <li>s.
def items(xs: List<&2, String>) -> M.Node:
  match xs:
    case Nil{}:
      M.Empty{}
    case Con{+x, t}:
      M.Seq{items(t), M.El{M.Li{}, inline(x)}}

def item_text.go(ol: Bool, +l: String) -> String:
  match ol:
    case True{}:
      String.drop(l, ol_prefix(l))
    case False{}:
      String.drop(l, 2n)

def item_text(+k: Nat, +l: String) -> String:
  item_text.go(Nat.is_eq(k, 4n), l)

def quote_text(+l: String) -> String:
  String.trim_start(String.drop(l, 1n))

def untab.go(b: Bool, +c: Char, r: String) -> String:
  match b:
    case True{}:
      "    " ++ r
    case False{}:
      SCon{c, r}

# Tabs become 4 spaces (the escaper drops control characters).
def untab(s: String) -> String:
  match s:
    case SNil{}:
      SNil{}
    case SCon{+c, t}:
      untab.go(Char.is_eq(c, '\t'), c, untab(t))

def code_sep(b: Bool) -> M.Node:
  match b:
    case True{}:
      M.Empty{}
    case False{}:
      M.Br{}

# Code lines separated by <br> (the escaper drops newlines).
def code_lines(xs: List<&2, String>, first: Bool) -> M.Node:
  match xs:
    case Nil{}:
      M.Empty{}
    case Con{x, t}:
      M.Seq{code_sep(first), M.Seq{M.Text{untab(x)}, code_lines(t, False{})}}

# The current block, finished. mode: 1 paragraph, 2 ul, 3 ol, 4 quote,
# 5 code; acc holds its lines, reversed.
def flush(mode: Nat, +acc: List<&2, String>) -> M.Node:
  match mode:
    case 1n:
      M.El{M.P{}, inline(join(acc, " "))}
    case 2n:
      M.El{M.Ul{}, items(acc)}
    case 3n:
      M.El{M.Ol{}, items(acc)}
    case 4n:
      M.El{M.Quote{}, M.El{M.P{}, inline(join(acc, " "))}}
    case 5n:
      M.El{M.Pre{}, M.El{M.Code{}, code_lines(List.reverse(&2, String, acc), True{})}}
    case _:
      M.Empty{}

def heading.go(h3: Bool, +l: String) -> M.Node:
  match h3:
    case True{}:
      M.El{M.H3{}, inline(heading_text(l))}
    case False{}:
      M.El{M.H2{}, inline(heading_text(l))}

def heading(+k: Nat, +l: String) -> M.Node:
  heading.go(Nat.is_eq(k, 2n), l)

# Does line kind k continue a block in mode?
def continues(+mode: Nat, +k: Nat) -> Bool:
  Bool.or(Bool.and(Nat.is_eq(mode, 1n), Nat.is_eq(k, 7n)), Bool.or(Bool.and(Nat.is_eq(mode, 2n), Nat.is_eq(k, 3n)), Bool.or(Bool.and(Nat.is_eq(mode, 3n), Nat.is_eq(k, 4n)), Bool.and(Nat.is_eq(mode, 4n), Nat.is_eq(k, 5n)))))

def line_for.go(mode: Nat, +k: Nat, +l: String) -> String:
  match mode:
    case 2n:
      item_text(k, l)
    case 3n:
      item_text(k, l)
    case 4n:
      quote_text(l)
    case _:
      l

# The line as it goes into a block's accumulator.
def line_for(+mode: Nat, +k: Nat, +l: String) -> String:
  line_for.go(mode, k, l)

# The mode a line of kind k starts (from between blocks).
def start_mode(k: Nat) -> Nat:
  match k:
    case 3n:
      2n
    case 4n:
      3n
    case 5n:
      4n
    case 6n:
      5n
    case 7n:
      1n
    case _:
      0n

def hd(ls: List<&2, String>) -> String:
  match ls:
    case Nil{}:
      ""
    case Con{x, t}:
      x

def tl(ls: List<&2, String>) -> List<&2, String>:
  match ls:
    case Nil{}:
      Nil{}
    case Con{x, t}:
      t

# The kind of the next line (8 at the end), whether it continues the block
# in mode, and whether it is a code fence.
def kind_head(ls: List<&2, String>) -> Nat:
  match ls:
    case Nil{}:
      8n
    case Con{+x, t}:
      kind_of(x)

def cont_head(+mode: Nat, +ls: List<&2, String>) -> Bool:
  continues(mode, kind_head(ls))

def fence_head(ls: List<&2, String>) -> Bool:
  match ls:
    case Nil{}:
      False{}
    case Con{+x, t}:
      String.starts_with(x, "```")

# One self-recursive machine over the lines. n: fuel (each step consumes a
# line or leaves a block). mode: 0 between blocks, else as in flush.
# fence, cont, k: about the next line (see kind_head, cont_head,
# fence_head). acc: the current block's lines, reversed.
def blocks(+n: Nat, mode: Nat, fence: Bool, cont: Bool, k: Nat, +ls: List<&2, String>, +acc: List<&2, String>, out: M.Node) -> M.Node:
  match n:
    case 0n:
      out
    case 1n+p:
      match mode:
        case 0n:
          match k:
            case 8n:
              out
            case 0n:
              blocks(p, 0n, fence_head(tl(ls)), cont_head(0n, tl(ls)), kind_head(tl(ls)), tl(ls), Nil{}, out)
            case 1n:
              blocks(p, 0n, fence_head(tl(ls)), cont_head(0n, tl(ls)), kind_head(tl(ls)), tl(ls), Nil{}, M.Seq{out, heading(1n, hd(ls))})
            case 2n:
              blocks(p, 0n, fence_head(tl(ls)), cont_head(0n, tl(ls)), kind_head(tl(ls)), tl(ls), Nil{}, M.Seq{out, heading(2n, hd(ls))})
            case 6n:
              blocks(p, 5n, fence_head(tl(ls)), cont_head(5n, tl(ls)), kind_head(tl(ls)), tl(ls), Nil{}, out)
            case 3n:
              blocks(p, 2n, fence_head(tl(ls)), cont_head(2n, tl(ls)), kind_head(tl(ls)), tl(ls), line_for(2n, 3n, hd(ls)) <> Nil{}, out)
            case 4n:
              blocks(p, 3n, fence_head(tl(ls)), cont_head(3n, tl(ls)), kind_head(tl(ls)), tl(ls), line_for(3n, 4n, hd(ls)) <> Nil{}, out)
            case 5n:
              blocks(p, 4n, fence_head(tl(ls)), cont_head(4n, tl(ls)), kind_head(tl(ls)), tl(ls), line_for(4n, 5n, hd(ls)) <> Nil{}, out)
            case _:
              blocks(p, 1n, fence_head(tl(ls)), cont_head(1n, tl(ls)), kind_head(tl(ls)), tl(ls), hd(ls) <> Nil{}, out)
        case 5n:
          match fence:
            case True{}:
              blocks(p, 0n, fence_head(tl(ls)), cont_head(0n, tl(ls)), kind_head(tl(ls)), tl(ls), Nil{}, M.Seq{out, flush(5n, acc)})
            case False{}:
              match k:
                case 8n:
                  M.Seq{out, flush(5n, acc)}
                case _:
                  blocks(p, 5n, fence_head(tl(ls)), cont_head(5n, tl(ls)), kind_head(tl(ls)), tl(ls), hd(ls) <> acc, out)
        case 1n:
          match cont:
            case True{}:
              blocks(p, 1n, fence_head(tl(ls)), cont_head(1n, tl(ls)), kind_head(tl(ls)), tl(ls), line_for(1n, k, hd(ls)) <> acc, out)
            case False{}:
              match k:
                case 8n:
                  M.Seq{out, flush(1n, acc)}
                case _:
                  blocks(p, 0n, fence_head(ls), cont_head(0n, ls), kind_head(ls), ls, Nil{}, M.Seq{out, flush(1n, acc)})
        case 2n:
          match cont:
            case True{}:
              blocks(p, 2n, fence_head(tl(ls)), cont_head(2n, tl(ls)), kind_head(tl(ls)), tl(ls), line_for(2n, k, hd(ls)) <> acc, out)
            case False{}:
              match k:
                case 8n:
                  M.Seq{out, flush(2n, acc)}
                case _:
                  blocks(p, 0n, fence_head(ls), cont_head(0n, ls), kind_head(ls), ls, Nil{}, M.Seq{out, flush(2n, acc)})
        case 3n:
          match cont:
            case True{}:
              blocks(p, 3n, fence_head(tl(ls)), cont_head(3n, tl(ls)), kind_head(tl(ls)), tl(ls), line_for(3n, k, hd(ls)) <> acc, out)
            case False{}:
              match k:
                case 8n:
                  M.Seq{out, flush(3n, acc)}
                case _:
                  blocks(p, 0n, fence_head(ls), cont_head(0n, ls), kind_head(ls), ls, Nil{}, M.Seq{out, flush(3n, acc)})
        case 4n:
          match cont:
            case True{}:
              blocks(p, 4n, fence_head(tl(ls)), cont_head(4n, tl(ls)), kind_head(tl(ls)), tl(ls), line_for(4n, k, hd(ls)) <> acc, out)
            case False{}:
              match k:
                case 8n:
                  M.Seq{out, flush(4n, acc)}
                case _:
                  blocks(p, 0n, fence_head(ls), cont_head(0n, ls), kind_head(ls), ls, Nil{}, M.Seq{out, flush(4n, acc)})
        case _:
          out

def render.go(+ls: List<&2, String>) -> M.Node:
  blocks(Nat.add(Nat.mul(List.length(&2, String, ls), 2n), 2n), 0n, fence_head(ls), cont_head(0n, ls), kind_head(ls), ls, Nil{}, M.Empty{})

# Markdown text to a Node.
def render(+s: String) -> M.Node:
  render.go(String.split(s, '\n'))

def mk_rendered(+n: M.Node) -> Rendered:
  Rendered{n, M.html(n, ""), {==}}

def Rendered.html(r: Rendered) -> String:
  match r:
    case Rendered{n, h, pf}:
      h

# A post body (Markdown) rendered.
def render_body(+b: Text.Body) -> Rendered:
  mk_rendered(render(Text.Body.text(b)))
