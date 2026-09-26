# Proofs of LAWS.bend.
import Base
import ./src/html.bend as Html
import ./LAWS.bend as Laws

# If a && b is True, then a is True.
def and_left(a: Bool, -b: Bool, e: {Bool.and(a, b) == True{} : Bool}) -> {a == True{} : Bool}:
  match a:
    case True{}:
      {==}
    case False{}:
      e

# Each encoding branch emits a fixed entity (whose characters compute to
# safe) in front of x, or just x.
def enc_apos_ok(b: Bool, -x: String, hx: {Laws.safe_str(x) == True{} : Bool}) -> {Laws.safe_str(Html.enc_apos(b, x)) == True{} : Bool}:
  match b:
    case True{}:
      hx
    case False{}:
      hx

def enc_quot_ok(b: Bool, +h: Char, -x: String, hx: {Laws.safe_str(x) == True{} : Bool}) -> {Laws.safe_str(Html.enc_quot(b, h, x)) == True{} : Bool}:
  match b:
    case True{}:
      hx
    case False{}:
      enc_apos_ok(Char.is_eq(h, '\''), x, hx)

def enc_amp_ok(b: Bool, +h: Char, -x: String, hx: {Laws.safe_str(x) == True{} : Bool}) -> {Laws.safe_str(Html.enc_amp(b, h, x)) == True{} : Bool}:
  match b:
    case True{}:
      hx
    case False{}:
      enc_quot_ok(Char.is_eq(h, '"'), h, x, hx)

def enc_gt_ok(b: Bool, +h: Char, -x: String, hx: {Laws.safe_str(x) == True{} : Bool}) -> {Laws.safe_str(Html.enc_gt(b, h, x)) == True{} : Bool}:
  match b:
    case True{}:
      hx
    case False{}:
      enc_amp_ok(Char.is_eq(h, '&'), h, x, hx)

def enc_lt_ok(b: Bool, +h: Char, -x: String, hx: {Laws.safe_str(x) == True{} : Bool}) -> {Laws.safe_str(Html.enc_lt(b, h, x)) == True{} : Bool}:
  match b:
    case True{}:
      hx
    case False{}:
      enc_gt_ok(Char.is_eq(h, '>'), h, x, hx)

# One character: a plain one is copied, and plain means the implementation's
# base_ok holds, which must match the spec's safe_char; any other is encoded.
def pick_ok(b: Bool, +h: Char, -x: String, e: {Html.plain(h) == b : Bool}, hx: {Laws.safe_str(x) == True{} : Bool}) -> {Laws.safe_str(Html.pick(b, h, x)) == True{} : Bool}:
  match b:
    case True{}:
      hb = and_left(Html.base_ok(h), U32.is_ne(Char.to_u32(h), 38), e)
      %Equal.sym(Bool, Html.base_ok(h), True{}, hb) : {Bool.and(_, Laws.safe_str(x)) == True{} : Bool}
      hx
    case False{}:
      enc_lt_ok(Char.is_eq(h, '<'), h, x, hx)

def Laws.html_esc_safe(s, rest, hr):
  match s:
    case SNil{}:
      hr
    case SCon{+h, t}:
      pick_ok(Html.plain(h), h, Html.esc(t, rest), {==}, Laws.html_esc_safe(t, rest, hr))

def Laws.html_esc_safe_alone(s):
  Laws.html_esc_safe(s, "", {==})
