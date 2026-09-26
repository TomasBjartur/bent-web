# Byte strings: a String whose Chars are bytes (0..255). Base64url and hex
# encoding, and big-endian integers. Pure.
import Base

# HEX
# ---

def b(+x: U32) -> Char:
  Chr{(x .&. 255 : U32)}
def hex_digit.go(b: Bool, +v: U32) -> Char:
  match b:
    case True{}:
      Chr{(v + 48 : U32)}
    case False{}:
      Chr{(v + 87 : U32)}
def hex_digit(+v: U32) -> Char:
  hex_digit.go(U32.is_lt(v, 10), v)
def u8(+c: Char) -> U32:
  (Char.to_u32(c) .&. 255 : U32)
# Bytes to lowercase hex.
def hex(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{+c, t}:
      SCon{hex_digit((u8(c) >> 4n : U32)), SCon{hex_digit((u8(c) .&. 15 : U32)), hex(t)}}
def hexval.go(d: Bool, l: Bool, +x: U32) -> Maybe<&2, U32>:
  match d l:
    case True{} _:
      Some{(x - 48 : U32)}
    case False{} True{}:
      Some{(x - 87 : U32)}
    case _ _:
      None{}
def hexval(+c: Char) -> Maybe<&2, U32>:
  +x = Char.to_u32(c)
  hexval.go(Bool.and(U32.is_ge(x, 48), U32.is_le(x, 57)), Bool.and(U32.is_ge(x, 97), U32.is_le(x, 102)), x)
def hex_pair(a: Maybe<&2, U32>, b: Maybe<&2, U32>, r: Maybe<&2, String>) -> Maybe<&2, String>:
  match a b r:
    case Some{+x} Some{+y} Some{s}:
      Some{SCon{Chr{((x << 4n) .|. y : U32)}, s}}
    case _ _ _:
      None{}
# Lowercase hex to bytes, or None.
def unhex(s: String) -> Maybe<&2, String>:
  match s:
    case SNil{}:
      Some{""}
    case SCon{+a, t}:
      match t:
        case SNil{}:
          None{}
        case SCon{+b, u}:
          hex_pair(hexval(a), hexval(b), unhex(u))
def b64_char.go(a: Bool, b: Bool, c: Bool, d: Bool, +v: U32) -> Char:
  match a b c d:
    case True{} _ _ _:
      Chr{(v + 65 : U32)}
    case False{} True{} _ _:
      Chr{(v + 71 : U32)}
    case False{} False{} True{} _:
      Chr{(v - 4 : U32)}
    case False{} False{} False{} True{}:
      '-'
    case _ _ _ _:
      '_'
# BASE64URL (RFC 4648 section 5, no padding)
# ---------
def b64_char(+v: U32) -> Char:
  b64_char.go(U32.is_lt(v, 26), U32.is_lt(v, 52), U32.is_lt(v, 62), U32.is_eq(v, 62), v)
def b64_val.go(up: Bool, lo: Bool, di: Bool, dash: Bool, us: Bool, +x: U32) -> Maybe<&2, U32>:
  match up lo di dash us:
    case True{} _ _ _ _:
      Some{(x - 65 : U32)}
    case False{} True{} _ _ _:
      Some{(x - 71 : U32)}
    case False{} False{} True{} _ _:
      Some{(x + 4 : U32)}
    case False{} False{} False{} True{} _:
      Some{62}
    case False{} False{} False{} False{} True{}:
      Some{63}
    case _ _ _ _ _:
      None{}
def b64_val(+c: Char) -> Maybe<&2, U32>:
  +x = Char.to_u32(c)
  b64_val.go(Bool.and(U32.is_ge(x, 65), U32.is_le(x, 90)), Bool.and(U32.is_ge(x, 97), U32.is_le(x, 122)), Bool.and(U32.is_ge(x, 48), U32.is_le(x, 57)), U32.is_eq(x, 45), U32.is_eq(x, 95), x)
def enc1(+x1: U32) -> String:
  SCon{b64_char((x1 >> 2n : U32)), SCon{b64_char(((x1 .&. 3) << 4n : U32)), ""}}
def enc2(+x1: U32, +x2: U32) -> String:
  SCon{b64_char((x1 >> 2n : U32)), SCon{b64_char((((x1 .&. 3) << 4n) .|. (x2 >> 4n) : U32)), SCon{b64_char(((x2 .&. 15) << 2n : U32)), ""}}}
def enc3(+x1: U32, +x2: U32, +x3: U32, rest: String) -> String:
  SCon{b64_char((x1 >> 2n : U32)), SCon{b64_char((((x1 .&. 3) << 4n) .|. (x2 >> 4n) : U32)), SCon{b64_char((((x2 .&. 15) << 2n) .|. (x3 >> 6n) : U32)), SCon{b64_char((x3 .&. 63 : U32)), rest}}}}
# Bytes to base64url without padding.
def b64(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{+c1, t}:
      match t:
        case SNil{}:
          enc1(u8(c1))
        case SCon{+c2, u}:
          match u:
            case SNil{}:
              enc2(u8(c1), u8(c2))
            case SCon{+c3, v}:
              enc3(u8(c1), u8(c2), u8(c3), b64(v))
def quad(a: Maybe<&2, U32>, b2: Maybe<&2, U32>, c: Maybe<&2, U32>, d: Maybe<&2, U32>, r: Maybe<&2, String>) -> Maybe<&2, String>:
  match a b2 c d r:
    case Some{+w} Some{+x} Some{+y} Some{+z} Some{s}:
      Some{SCon{b(((w << 2n) .|. (x >> 4n) : U32)), SCon{b((((x .&. 15) << 4n) .|. (y >> 2n) : U32)), SCon{b((((y .&. 3) << 6n) .|. z : U32)), s}}}}
    case _ _ _ _ _:
      None{}
def tail2.go(ok: Bool, +w: U32, +x: U32) -> Maybe<&2, String>:
  match ok:
    case True{}:
      Some{SCon{b(((w << 2n) .|. (x >> 4n) : U32)), ""}}
    case False{}:
      None{}
# The last 2 or 3 characters; the unused low bits must be zero (so each
# byte string has exactly one encoding).
def tail2(a: Maybe<&2, U32>, b2: Maybe<&2, U32>) -> Maybe<&2, String>:
  match a b2:
    case Some{+w} Some{+x}:
      tail2.go(U32.is_eq((x .&. 15 : U32), 0), w, x)
    case _ _:
      None{}
def tail3.go(ok: Bool, +w: U32, +x: U32, +y: U32) -> Maybe<&2, String>:
  match ok:
    case True{}:
      Some{SCon{b(((w << 2n) .|. (x >> 4n) : U32)), SCon{b((((x .&. 15) << 4n) .|. (y >> 2n) : U32)), ""}}}
    case False{}:
      None{}
def tail3(a: Maybe<&2, U32>, b2: Maybe<&2, U32>, c: Maybe<&2, U32>) -> Maybe<&2, String>:
  match a b2 c:
    case Some{+w} Some{+x} Some{+y}:
      tail3.go(U32.is_eq((y .&. 3 : U32), 0), w, x, y)
    case _ _ _:
      None{}
# Base64url (no padding) to bytes, or None.
def unb64(s: String) -> Maybe<&2, String>:
  match s:
    case SNil{}:
      Some{""}
    case SCon{+c1, t}:
      match t:
        case SNil{}:
          None{}
        case SCon{+c2, u}:
          match u:
            case SNil{}:
              tail2(b64_val(c1), b64_val(c2))
            case SCon{+c3, v}:
              match v:
                case SNil{}:
                  tail3(b64_val(c1), b64_val(c2), b64_val(c3))
                case SCon{+c4, w}:
                  quad(b64_val(c1), b64_val(c2), b64_val(c3), b64_val(c4), unb64(w))
# INTEGERS
# --------
def byte_at(s: String, n: Nat) -> U32:
  match s:
    case SNil{}:
      0
    case SCon{c, t}:
      match n:
        case 0n:
          (Char.to_u32(c) .&. 255 : U32)
        case 1n+p:
          byte_at(t, p)
def be16(+s: String) -> U32:
  ((byte_at(s, 0n) << 8n) .|. byte_at(s, 1n) : U32)
def be32(+s: String) -> U32:
  ((byte_at(s, 0n) << 24n) .|. ((byte_at(s, 1n) << 16n) .|. ((byte_at(s, 2n) << 8n) .|. byte_at(s, 3n))) : U32)
# The bytes as a list of numbers (for comparing against fixed templates).
def bytes_of(xs: List<&2, U32>) -> String:
  match xs:
    case Nil{}:
      ""
    case Con{+x, t}:
      SCon{Chr{x}, bytes_of(t)}
