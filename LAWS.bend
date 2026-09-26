# The laws of the blog. Humans own this file: code must satisfy these, and
# PROOF.bend must prove each one. `bend PROOF.bend` is the gate.
#
# RULE: every predicate a law uses is defined HERE, never in the code under
# test. A law stated with the implementation's own predicates is weakened
# whenever the implementation is (found by mutation testing, 2026-09-26).
import Base
import ./src/html.bend as Html

# SPEC: a character that is safe anywhere in HTML text or a quoted attribute
# value: not a control character (below 32, or 127) and not < > " '.
def safe_char(+c: Char) -> Bool:
  +x = Char.to_u32(c)
  Bool.and(U32.is_ge(x, 32), Bool.and(U32.is_ne(x, 127), Bool.and(U32.is_ne(x, 60), Bool.and(U32.is_ne(x, 62), Bool.and(U32.is_ne(x, 34), U32.is_ne(x, 39))))))

# SPEC: every character of s is safe.
def safe_str(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{+h, t}:
      Bool.and(safe_char(h), safe_str(t))

# LAW: escaping never produces an unsafe character. Whatever the user typed,
# Html.esc emits no < > " ' and no control characters (so it cannot open a
# tag, close an attribute, or forge an internal marker), provided what it is
# prepended to was already safe.
law html_esc_safe:
  for s: String
  for -rest: String
  for hr: {safe_str(rest) == True{} : Bool}
  {safe_str(Html.esc(s, rest)) == True{} : Bool}

# LAW: in particular, escaping a string on its own is safe.
law html_esc_safe_alone:
  for s: String
  {safe_str(Html.esc(s, "")) == True{} : Bool}
