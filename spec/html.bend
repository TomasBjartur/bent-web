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
