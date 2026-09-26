# SPEC: what user-supplied text may contain once decoded.
#
# Human-owned. Code may import this file but must never redefine or weaken
# it. Every change here is a security decision and must be called out in the
# commit message.
import Base
import ./http.bend as Http

# A Unicode scalar value: at most U+10FFFF and not a surrogate.
def scalar(+x: U32) -> Bool:
  Bool.and(U32.is_le(x, 1114111), Bool.not(Http.in_range(x, 55296, 57343)))

# Not a control character: C0 (below 32), DEL (127) and C1 (128..159).
def not_control(+x: U32) -> Bool:
  Bool.and(U32.is_ge(x, 32), Bool.not(Http.in_range(x, 127, 159)))

# A character allowed in a single-line field (titles, names).
def line_char(+c: Char) -> Bool:
  +x = Char.to_u32(c)
  Bool.and(scalar(x), not_control(x))

# A character allowed in multi-line text (post bodies): a line character,
# or newline, or tab.
def body_char(+c: Char) -> Bool:
  +x = Char.to_u32(c)
  Bool.or(line_char(c), Bool.or(U32.is_eq(x, 10), U32.is_eq(x, 9)))

def all_line_chars(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{+h, t}:
      Bool.and(line_char(h), all_line_chars(t))

def all_body_chars(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{+h, t}:
      Bool.and(body_char(h), all_body_chars(t))

# A title: 1..200 line characters.
def title_ok(+s: String) -> Bool:
  Bool.and(Bool.not(String.is_empty(s)), Bool.and(Nat.is_le(String.length(s), 200n), all_line_chars(s)))

# A post body: body characters only. (Its length is bounded by the request
# body limit, 1 MiB, and by the schema.)
def body_ok(+s: String) -> Bool:
  all_body_chars(s)

# A slug: 1..64 of a-z 0-9 and '-'.
def slug_char(+c: Char) -> Bool:
  +x = Char.to_u32(c)
  Bool.or(Http.in_range(x, 97, 122), Bool.or(Http.in_range(x, 48, 57), U32.is_eq(x, 45)))

def all_slug_chars(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{+h, t}:
      Bool.and(slug_char(h), all_slug_chars(t))

def slug_ok(+s: String) -> Bool:
  Bool.and(Bool.not(String.is_empty(s)), Bool.and(Nat.is_le(String.length(s), 64n), all_slug_chars(s)))
