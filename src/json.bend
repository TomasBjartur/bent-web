# A strict parser for flat JSON objects whose values are strings or
# booleans (e.g. WebAuthn's clientDataJSON). Anything else is rejected:
# numbers, null, nesting, raw control characters in strings, escapes that
# decode to surrogates, and trailing garbage. A key that occurs more than
# once reads as absent. Pure.
#
# One self-recursive state machine (Bend has no mutual recursion). The
# class of the next character is passed in, so every branch matches on a
# parameter. Fuel (the input length) proves termination.
import Base

type JVal is Data:
  JStr{s: String}
  JBool{b: Bool}
type JField is Data:
  JField{key: String, val: JVal}
# ESCAPES
# -------
# Given the text after a backslash: whether it is a valid escape, the
# character it stands for, and what follows it.
type Esc is Data:
  Esc{ok: Bool, ch: Char, rest: String}
def q.kind.go(a: Bool, b: Bool, c: Bool, d: Bool) -> Nat:
  match a b c d:
    case True{} _ _ _:
      1n
    case _ True{} _ _:
      2n
    case _ _ True{} _:
      3n
    case _ _ _ True{}:
      4n
    case _ _ _ _:
      0n
def q.kind(+x: U32) -> Nat:
  q.kind.go(U32.is_eq(x, 34), U32.is_eq(x, 92), U32.is_lt(x, 32), U32.is_eq(x, 60))
def hexch.go(b: Bool, +v: U32) -> Char:
  match b:
    case True{}:
      Chr{(v + 48 : U32)}
    case False{}:
      Chr{(v + 87 : U32)}
def hexch(+v: U32) -> Char:
  hexch.go(U32.is_lt(v, 10), v)
def q.char(k: Nat, +c: Char, r: String) -> String:
  match k:
    case 1n:
      "\\\"" ++ r
    case 2n:
      "\\\\" ++ r
    case 0n:
      SCon{c, r}
    case _:
      "\\u00" ++ SCon{hexch((Char.to_u32(c) >> 4n : U32)), SCon{hexch((Char.to_u32(c) .&. 15 : U32)), r}}
# JSON OUTPUT
# -----------
# Escapes s as the contents of a JSON string: quote, backslash, and every
# control character become escapes; '<' too, so the output is safe to
# embed anywhere.
def q(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{+c, t}:
      q.char(q.kind(Char.to_u32(c)), c, q(t))
def cls_pick(q: Bool, bs: Bool, co: Bool, cm: Bool, lb: Bool, rb: Bool, ws: Bool, t: Bool, f: Bool, wsc: Bool, ctl: Bool) -> Nat:
  match q bs co cm lb rb ws t f wsc ctl:
    case True{} _ _ _ _ _ _ _ _ _ _:
      1n
    case _ True{} _ _ _ _ _ _ _ _ _:
      2n
    case _ _ True{} _ _ _ _ _ _ _ _:
      3n
    case _ _ _ True{} _ _ _ _ _ _ _:
      4n
    case _ _ _ _ True{} _ _ _ _ _ _:
      5n
    case _ _ _ _ _ True{} _ _ _ _ _:
      6n
    case _ _ _ _ _ _ True{} _ _ _ _:
      7n
    case _ _ _ _ _ _ _ True{} _ _ _:
      8n
    case _ _ _ _ _ _ _ _ True{} _ _:
      9n
    case _ _ _ _ _ _ _ _ _ True{} _:
      12n
    case _ _ _ _ _ _ _ _ _ _ True{}:
      10n
    case _ _ _ _ _ _ _ _ _ _ _:
      0n
# Character classes: 0 other, 1 '"', 2 '\\', 3 ':', 4 ',', 5 '{', 6 '}',
# 7 space, 8 't', 9 'f', 10 control, 11 end of input, 12 tab/LF/CR
# (whitespace between tokens, but a control character inside strings).
def cls_of(+x: U32) -> Nat:
  cls_pick(U32.is_eq(x, 34), U32.is_eq(x, 92), U32.is_eq(x, 58), U32.is_eq(x, 44), U32.is_eq(x, 123), U32.is_eq(x, 125), U32.is_eq(x, 32), U32.is_eq(x, 116), U32.is_eq(x, 102), Bool.or(U32.is_eq(x, 9), Bool.or(U32.is_eq(x, 10), U32.is_eq(x, 13))), U32.is_lt(x, 32))
def head_cls(t: String) -> Nat:
  match t:
    case SNil{}:
      11n
    case SCon{+c, r}:
      cls_of(Char.to_u32(c))
def head(t: String) -> Char:
  match t:
    case SNil{}:
      Chr{0}
    case SCon{c, r}:
      c
def tail(t: String) -> String:
  match t:
    case SNil{}:
      SNil{}
    case SCon{c, r}:
      r
def guard(-A: Data, ok: Bool, r: Maybe<&2, A>) -> Maybe<&2, A>:
  match ok:
    case True{}:
      r
    case False{}:
      None{}
def hexd.go(d: Bool, l: Bool, u: Bool, +x: U32) -> Maybe<&2, U32>:
  match d l u:
    case True{} _ _:
      Some{(x - 48 : U32)}
    case _ True{} _:
      Some{(x - 87 : U32)}
    case _ _ True{}:
      Some{(x - 55 : U32)}
    case _ _ _:
      None{}
def hexd(+c: Char) -> Maybe<&2, U32>:
  +x = Char.to_u32(c)
  hexd.go(Bool.and(U32.is_ge(x, 48), U32.is_le(x, 57)), Bool.and(U32.is_ge(x, 97), U32.is_le(x, 102)), Bool.and(U32.is_ge(x, 65), U32.is_le(x, 70)), x)
def h4(a: Maybe<&2, U32>, b: Maybe<&2, U32>, c: Maybe<&2, U32>, d: Maybe<&2, U32>) -> Maybe<&2, U32>:
  match a b c d:
    case Some{+w} Some{+x} Some{+y} Some{+z}:
      Some{((w << 12n) .|. ((x << 8n) .|. ((y << 4n) .|. z)) : U32)}
    case _ _ _ _:
      None{}
def nth(s: String, n: Nat) -> Char:
  head(String.drop(s, n))
def hex4.len(ok: Bool, +s: String) -> Maybe<&2, U32>:
  match ok:
    case True{}:
      h4(hexd(nth(s, 0n)), hexd(nth(s, 1n)), hexd(nth(s, 2n)), hexd(nth(s, 3n)))
    case False{}:
      None{}
def hex4.go(+s: String) -> Maybe<&2, U32>:
  hex4.len(Nat.is_eq(String.length(s), 4n), s)
def hex4(+t: String) -> Maybe<&2, U32>:
  hex4.go(String.take(t, 4n))
# The character is only built when valid: the runtime refuses surrogates.
def esc_u.go(ok: Bool, +v: U32, +t: String) -> Esc:
  match ok:
    case True{}:
      Esc{True{}, Chr{v}, String.drop(t, 4n)}
    case False{}:
      Esc{False{}, Chr{0}, ""}
# \uXXXX: a code unit; surrogates are rejected (fail closed).
def esc_u(m: Maybe<&2, U32>, +t: String) -> Esc:
  match m:
    case None{}:
      Esc{False{}, Chr{0}, ""}
    case Some{+v}:
      esc_u.go(Bool.or(U32.is_lt(v, 55296), U32.is_gt(v, 57343)), v, t)
def esc_pick(k: Nat, +t: String) -> Esc:
  match k:
    case 1n:
      Esc{True{}, '"', t}
    case 2n:
      Esc{True{}, '\\', t}
    case 3n:
      Esc{True{}, '/', t}
    case 4n:
      Esc{True{}, Chr{8}, t}
    case 5n:
      Esc{True{}, Chr{12}, t}
    case 6n:
      Esc{True{}, '\n', t}
    case 7n:
      Esc{True{}, '\r', t}
    case 8n:
      Esc{True{}, '\t', t}
    case 9n:
      esc_u(hex4(t), t)
    case _:
      Esc{False{}, Chr{0}, ""}
def esc_kind(+c: Char) -> Nat:
  +x = Char.to_u32(c)
  U32.to_nat((Bool.to_u32(U32.is_eq(x, 34)) + ((2 * Bool.to_u32(U32.is_eq(x, 92))) + ((3 * Bool.to_u32(U32.is_eq(x, 47))) + ((4 * Bool.to_u32(U32.is_eq(x, 98))) + ((5 * Bool.to_u32(U32.is_eq(x, 102))) + ((6 * Bool.to_u32(U32.is_eq(x, 110))) + ((7 * Bool.to_u32(U32.is_eq(x, 114))) + ((8 * Bool.to_u32(U32.is_eq(x, 116))) + (9 * Bool.to_u32(U32.is_eq(x, 117)))))))))) : U32))
def escape(+t: String) -> Esc:
  esc_pick(esc_kind(head(t)), tail(t))
def esc_ok(+e: Esc) -> Bool:
  match e:
    case Esc{ok, ch, rest}:
      ok
def esc_ch(+e: Esc) -> Char:
  match e:
    case Esc{ok, ch, rest}:
      ch
def esc_rest(+e: Esc) -> String:
  match e:
    case Esc{ok, ch, rest}:
      rest
# THE MACHINE
# -----------
# States: 0 before '{'; 1 after '{'; 2 in a key; 3 after a key; 4 before a
# value; 5 in a string value; 7 after a value; 8 after ','; 9 after '}';
# 12 escape in a key; 15 escape in a value. key and val are accumulated in
# reverse.
def done(st: Nat, acc: List<&2, JField>) -> Maybe<&2, List<&2, JField>>:
  match st:
    case 9n:
      Some{acc}
    case _:
      None{}
def rev(s: String) -> String:
  String.reverse(s)
def js(n: Nat, st: Nat, k: Nat, +t: String, +key: String, +val: String, +acc: List<&2, JField>) -> Maybe<&2, List<&2, JField>>:
  match n:
    case 0n:
      None{}
    case 1n+p:
      match st:
        case 0n:
          match k:
            case 7n:
              js(p, 0n, head_cls(tail(t)), tail(t), key, val, acc)
            case 12n:
              js(p, 0n, head_cls(tail(t)), tail(t), key, val, acc)
            case 5n:
              js(p, 1n, head_cls(tail(t)), tail(t), key, val, acc)
            case _:
              None{}
        case 1n:
          match k:
            case 7n:
              js(p, 1n, head_cls(tail(t)), tail(t), key, val, acc)
            case 12n:
              js(p, 1n, head_cls(tail(t)), tail(t), key, val, acc)
            case 1n:
              js(p, 2n, head_cls(tail(t)), tail(t), "", "", acc)
            case 6n:
              js(p, 9n, head_cls(tail(t)), tail(t), key, val, acc)
            case _:
              None{}
        case 2n:
          match k:
            case 1n:
              js(p, 3n, head_cls(tail(t)), tail(t), key, val, acc)
            case 2n:
              js(p, 12n, head_cls(tail(t)), tail(t), key, val, acc)
            case 10n:
              None{}
            case 11n:
              None{}
            case 12n:
              None{}
            case _:
              js(p, 2n, head_cls(tail(t)), tail(t), SCon{head(t), key}, val, acc)
        case 3n:
          match k:
            case 7n:
              js(p, 3n, head_cls(tail(t)), tail(t), key, val, acc)
            case 12n:
              js(p, 3n, head_cls(tail(t)), tail(t), key, val, acc)
            case 3n:
              js(p, 4n, head_cls(tail(t)), tail(t), key, val, acc)
            case _:
              None{}
        case 4n:
          match k:
            case 7n:
              js(p, 4n, head_cls(tail(t)), tail(t), key, val, acc)
            case 12n:
              js(p, 4n, head_cls(tail(t)), tail(t), key, val, acc)
            case 1n:
              js(p, 5n, head_cls(tail(t)), tail(t), key, "", acc)
            case 8n:
              guard(List<&2, JField>, String.starts_with(t, "true"), js(p, 7n, head_cls(String.drop(t, 4n)), String.drop(t, 4n), "", "", JField{rev(key), JBool{True{}}} <> acc))
            case 9n:
              guard(List<&2, JField>, String.starts_with(t, "false"), js(p, 7n, head_cls(String.drop(t, 5n)), String.drop(t, 5n), "", "", JField{rev(key), JBool{False{}}} <> acc))
            case _:
              None{}
        case 5n:
          match k:
            case 1n:
              js(p, 7n, head_cls(tail(t)), tail(t), "", "", JField{rev(key), JStr{rev(val)}} <> acc)
            case 2n:
              js(p, 15n, head_cls(tail(t)), tail(t), key, val, acc)
            case 10n:
              None{}
            case 11n:
              None{}
            case 12n:
              None{}
            case _:
              js(p, 5n, head_cls(tail(t)), tail(t), key, SCon{head(t), val}, acc)
        case 7n:
          match k:
            case 7n:
              js(p, 7n, head_cls(tail(t)), tail(t), key, val, acc)
            case 12n:
              js(p, 7n, head_cls(tail(t)), tail(t), key, val, acc)
            case 4n:
              js(p, 8n, head_cls(tail(t)), tail(t), key, val, acc)
            case 6n:
              js(p, 9n, head_cls(tail(t)), tail(t), key, val, acc)
            case _:
              None{}
        case 8n:
          match k:
            case 7n:
              js(p, 8n, head_cls(tail(t)), tail(t), key, val, acc)
            case 12n:
              js(p, 8n, head_cls(tail(t)), tail(t), key, val, acc)
            case 1n:
              js(p, 2n, head_cls(tail(t)), tail(t), "", "", acc)
            case _:
              None{}
        case 9n:
          match k:
            case 7n:
              js(p, 9n, head_cls(tail(t)), tail(t), key, val, acc)
            case 12n:
              js(p, 9n, head_cls(tail(t)), tail(t), key, val, acc)
            case 11n:
              Some{acc}
            case _:
              None{}
        case 12n:
          match k:
            case 11n:
              None{}
            case _:
              guard(List<&2, JField>, esc_ok(escape(t)), js(p, 2n, head_cls(esc_rest(escape(t))), esc_rest(escape(t)), SCon{esc_ch(escape(t)), key}, val, acc))
        case 15n:
          match k:
            case 11n:
              None{}
            case _:
              guard(List<&2, JField>, esc_ok(escape(t)), js(p, 5n, head_cls(esc_rest(escape(t))), esc_rest(escape(t)), key, SCon{esc_ch(escape(t)), val}, acc))
        case _:
          None{}
# Parses a flat object of string/boolean values, or None.
def parse(+s: String) -> Maybe<&2, List<&2, JField>>:
  js(Nat.add(String.length(s), 1n), 0n, head_cls(s), s, "", "", Nil{})
# LOOKUP (a key that occurs more than once reads as absent)
# ------
def count(xs: List<&2, JField>, +key: String) -> Nat:
  match xs:
    case Nil{}:
      0n
    case Con{f, t}:
      match f:
        case JField{k, v}:
          Nat.add(U32.to_nat(Bool.to_u32(String.eq(k, key))), count(t, key))
def first.pick(b: Bool, +v: JVal, r: Maybe<&2, JVal>) -> Maybe<&2, JVal>:
  match b:
    case True{}:
      Some{v}
    case False{}:
      r
def first(xs: List<&2, JField>, +key: String) -> Maybe<&2, JVal>:
  match xs:
    case Nil{}:
      None{}
    case Con{f, t}:
      match f:
        case JField{+k, +v}:
          first.pick(String.eq(k, key), v, first(t, key))
def get(+xs: List<&2, JField>, +key: String) -> Maybe<&2, JVal>:
  guard(JVal, Nat.is_eq(count(xs, key), 1n), first(xs, key))
def str_of(m: Maybe<&2, JVal>) -> Maybe<&2, String>:
  match m:
    case Some{v}:
      match v:
        case JStr{s}:
          Some{s}
        case JBool{b}:
          None{}
    case None{}:
      None{}
def bool_of(m: Maybe<&2, JVal>) -> Maybe<&2, Bool>:
  match m:
    case Some{v}:
      match v:
        case JStr{s}:
          None{}
        case JBool{b}:
          Some{b}
    case None{}:
      None{}
# The string value of key (exactly once, and a string), or None.
def str(+xs: List<&2, JField>, +key: String) -> Maybe<&2, String>:
  str_of(get(xs, key))
# The boolean value of key (exactly once, and a boolean), or None.
def boolean(+xs: List<&2, JField>, +key: String) -> Maybe<&2, Bool>:
  bool_of(get(xs, key))
