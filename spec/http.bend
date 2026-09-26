# SPEC: what a valid HTTP request looks like to this server.
#
# Human-owned. Code may import this file (to carry proofs about its output)
# but must never redefine or weaken it. Every change here is a security
# decision and must be called out in the commit message.
import Base

# LIMITS
# ------

# Longest request line or header line, in bytes (including nothing else).
def lim_line() -> Nat:
  4096n

# Most header lines in one request.
def lim_headers() -> Nat:
  64n

# Most path segments ("/a/b/c" has 3).
def lim_segs() -> Nat:
  16n

# Longest path segment, in bytes.
def lim_seg() -> Nat:
  128n

# Longest query string, in bytes.
def lim_query() -> Nat:
  2048n

# Largest request body, in bytes (1 MiB). A U32, not a Nat: Nat is unary in
# the checker, and a literal this large overflows it.
def lim_body() -> U32:
  1048576

# CHARACTERS
# ----------

def in_range(+x: U32, +lo: U32, +hi: U32) -> Bool:
  Bool.and(U32.is_ge(x, lo), U32.is_le(x, hi))

# 0-9 A-Z a-z
def is_alnum(+x: U32) -> Bool:
  Bool.or(in_range(x, 48, 57), Bool.or(in_range(x, 65, 90), in_range(x, 97, 122)))

# RFC 3986 "unreserved": ALPHA DIGIT - . _ ~
def is_unreserved(+x: U32) -> Bool:
  Bool.or(is_alnum(x), Bool.or(U32.is_eq(x, 45), Bool.or(U32.is_eq(x, 46), Bool.or(U32.is_eq(x, 95), U32.is_eq(x, 126)))))

# A path segment character: unreserved only. No percent-encoding, so a
# segment can never smuggle "/", "..", NUL or anything else in encoded form.
def seg_char(+c: Char) -> Bool:
  is_unreserved(Char.to_u32(c))

# A query character: unreserved, or % & = + (values are percent-decoded
# later, by code with its own laws).
def query_char(+c: Char) -> Bool:
  +x = Char.to_u32(c)
  Bool.or(is_unreserved(x), Bool.or(U32.is_eq(x, 37), Bool.or(U32.is_eq(x, 38), Bool.or(U32.is_eq(x, 61), U32.is_eq(x, 43)))))

# A header value character: visible ASCII, space or tab. No CR, LF, NUL,
# other control characters or bytes >= 128, so a header value can never
# split a response if it is ever reflected.
def hval_char(+c: Char) -> Bool:
  +x = Char.to_u32(c)
  Bool.or(U32.is_eq(x, 9), in_range(x, 32, 126))

# STRINGS
# -------

def all_seg_chars(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{+h, t}:
      Bool.and(seg_char(h), all_seg_chars(t))

def all_query_chars(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{+h, t}:
      Bool.and(query_char(h), all_query_chars(t))

def all_hval_chars(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{+h, t}:
      Bool.and(hval_char(h), all_hval_chars(t))

# A path segment: 1..lim_seg unreserved characters, and not "." or "..".
# So a parsed path can never walk up a directory.
def seg_ok(+s: String) -> Bool:
  Bool.and(Bool.not(String.is_empty(s)), Bool.and(Nat.is_le(String.length(s), lim_seg()), Bool.and(all_seg_chars(s), Bool.and(Bool.not(String.eq(s, ".")), Bool.not(String.eq(s, ".."))))))

# A path: at most lim_segs segments.
def seg_count_ok(n: Nat) -> Bool:
  Nat.is_le(n, lim_segs())

# A query string: at most lim_query query characters.
def query_ok(+s: String) -> Bool:
  Bool.and(Nat.is_le(String.length(s), lim_query()), all_query_chars(s))

# A header value: at most lim_line header-value characters, no leading or
# trailing whitespace is required of it (the parser trims).
def hval_ok(+s: String) -> Bool:
  Bool.and(Nat.is_le(String.length(s), lim_line()), all_hval_chars(s))

# A Content-Length: at most lim_body.
def clen_ok(+n: U32) -> Bool:
  U32.is_le(n, lim_body())
