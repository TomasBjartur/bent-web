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

# A post body: at most 1 MiB characters (the request limit; a U32 bound: a
# Nat literal this large overflows the checker), body characters only.
# Novel-length posts (several MB) need the block-based editor (see
# CLAUDE.md), not a larger limit here.
def body_ok(+s: String) -> Bool:
  Bool.and(U32.is_le(U32.from_nat(String.length(s)), 1048576), all_body_chars(s))

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

# An email address, conservatively: 3..254 printable ASCII characters with
# exactly one '@', not first or last, and none of < > " ' ( ) [ ] , ; : \
# or space. (Stricter than RFC 5321; safe to put in a mail header or HTML.)
def email_char(+c: Char) -> Bool:
  +x = Char.to_u32(c)
  Bool.and(Http.in_range(x, 33, 126), Bool.not(Bool.or(U32.is_eq(x, 60), Bool.or(U32.is_eq(x, 62), Bool.or(U32.is_eq(x, 34), Bool.or(U32.is_eq(x, 39), Bool.or(U32.is_eq(x, 40), Bool.or(U32.is_eq(x, 41), Bool.or(U32.is_eq(x, 91), Bool.or(U32.is_eq(x, 93), Bool.or(U32.is_eq(x, 44), Bool.or(U32.is_eq(x, 59), Bool.or(U32.is_eq(x, 58), U32.is_eq(x, 92))))))))))))))

def all_email_chars(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{+h, t}:
      Bool.and(email_char(h), all_email_chars(t))

def ats(s: String) -> Nat:
  match s:
    case SNil{}:
      0n
    case SCon{+h, t}:
      Nat.add(U32.to_nat(Bool.to_u32(Char.is_eq(h, '@'))), ats(t))

def email_ok(+s: String) -> Bool:
  Bool.and(Nat.is_le(3n, String.length(s)), Bool.and(Nat.is_le(String.length(s), 254n), Bool.and(all_email_chars(s), Bool.and(Nat.is_eq(ats(s), 1n), Bool.and(Bool.not(String.starts_with(s, "@")), Bool.not(String.ends_with(s, "@")))))))

# A display name: 1..64 line characters.
def name_ok(+s: String) -> Bool:
  Bool.and(Bool.not(String.is_empty(s)), Bool.and(Nat.is_le(String.length(s), 64n), all_line_chars(s)))
