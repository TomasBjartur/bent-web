# HTML text escaping. Every user-supplied string rendered into a page goes
# through esc. Its safety law (LAWS.bend: html_esc_safe) is proved in
# PROOF.bend.
import Base

# A character that is safe anywhere in escaped output: not a control
# character (below 32, or 127), and not one of < > " '.
def base_ok(+c: Char) -> Bool:
  +x = Char.to_u32(c)
  Bool.and(U32.is_ge(x, 32), Bool.and(U32.is_ne(x, 127), Bool.and(U32.is_ne(x, 60), Bool.and(U32.is_ne(x, 62), Bool.and(U32.is_ne(x, 34), U32.is_ne(x, 39))))))

# Copied through unchanged: safe, and not '&' (which is encoded, so text
# like "&lt;" typed by a user displays as typed).
def plain(+c: Char) -> Bool:
  Bool.and(base_ok(c), U32.is_ne(Char.to_u32(c), 38))

# Encoding of a character that is not plain: an entity for & < > " ',
# nothing for anything else (control characters are dropped).
def enc_apos(b: Bool, x: String) -> String:
  match b:
    case True{}:
      "&#39;" ++ x
    case False{}:
      x

def enc_quot(b: Bool, +h: Char, x: String) -> String:
  match b:
    case True{}:
      "&quot;" ++ x
    case False{}:
      enc_apos(Char.is_eq(h, '\''), x)

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
