# SPEC: what escaped HTML text may contain.
#
# Human-owned. Code may import this file but must never redefine or weaken
# it. Every change here is a security decision and must be called out in the
# commit message.
import Base

# A character that is safe anywhere in HTML text or a quoted attribute
# value: not a control character (below 32, or 127) and not < > " '.
def safe_char(+c: Char) -> Bool:
  +x = Char.to_u32(c)
  Bool.and(U32.is_ge(x, 32), Bool.and(U32.is_ne(x, 127), Bool.and(U32.is_ne(x, 60), Bool.and(U32.is_ne(x, 62), Bool.and(U32.is_ne(x, 34), U32.is_ne(x, 39))))))

# Every character of s is safe.
def safe_str(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{+h, t}:
      Bool.and(safe_char(h), safe_str(t))

# THE ESCAPER
# -----------
# How text becomes HTML. Used by code (src/html.bend) and by the markup
# serializer (spec/markup.bend). LAWS.bend html_esc_safe proves it never
# emits a character outside safe_str.
def base_ok(+c: Char) -> Bool:
  +x = Char.to_u32(c)
  Bool.and(U32.is_ge(x, 32), Bool.and(U32.is_ne(x, 127), Bool.and(U32.is_ne(x, 60), Bool.and(U32.is_ne(x, 62), Bool.and(U32.is_ne(x, 34), U32.is_ne(x, 39))))))

# Copied through unchanged: safe, and not '&' (which is encoded, so text
# like "&lt;" typed by a user displays as typed).
def plain(+c: Char) -> Bool:
  Bool.and(base_ok(c), U32.is_ne(Char.to_u32(c), 38))

# Encoding of a character that is not plain: an entity for & < > " ',
# a numeric reference for newline and tab (so text keeps its lines, in a
# textarea or a <pre>), nothing for anything else (other control characters
# are dropped).
def enc_tab(b: Bool, x: String) -> String:
  match b:
    case True{}:
      "&#9;" ++ x
    case False{}:
      x

def enc_nl(b: Bool, +h: Char, x: String) -> String:
  match b:
    case True{}:
      "&#10;" ++ x
    case False{}:
      enc_tab(U32.is_eq(Char.to_u32(h), 9), x)

def enc_apos(b: Bool, +h: Char, x: String) -> String:
  match b:
    case True{}:
      "&#39;" ++ x
    case False{}:
      enc_nl(U32.is_eq(Char.to_u32(h), 10), h, x)

def enc_quot(b: Bool, +h: Char, x: String) -> String:
  match b:
    case True{}:
      "&quot;" ++ x
    case False{}:
      enc_apos(Char.is_eq(h, '\''), h, x)

def enc_amp(b: Bool, +h: Char, x: String) -> String:
  match b:
    case True{}:
      "&amp;" ++ x
    case False{}:
      enc_quot(Char.is_eq(h, '"'), h, x)

def enc_gt(b: Bool, +h: Char, x: String) -> String:
  match b:
    case True{}:
      "&gt;" ++ x
    case False{}:
      enc_amp(Char.is_eq(h, '&'), h, x)

def enc_lt(b: Bool, +h: Char, x: String) -> String:
  match b:
    case True{}:
      "&lt;" ++ x
    case False{}:
      enc_gt(Char.is_eq(h, '>'), h, x)

def encode(+h: Char, x: String) -> String:
  enc_lt(Char.is_eq(h, '<'), h, x)

def pick(b: Bool, +h: Char, x: String) -> String:
  match b:
    case True{}:
      SCon{h, x}
    case False{}:
      encode(h, x)

# Escapes s in front of rest ("prepend onto rest", so pages build linearly).
def esc(s: String, rest: String) -> String:
  match s:
    case SNil{}:
      rest
    case SCon{+h, t}:
      pick(plain(h), h, esc(t, rest))
