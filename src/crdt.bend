# A text CRDT (Fugue-style list): the state of a document is a sorted,
# duplicate-free list of operations, and replicas merge by sorted union.
#
# LAWS.bend proves merge commutative and idempotent (crdt_merge_comm,
# crdt_merge_idem): replicas that have seen the same operations hold the
# same state, whatever order they saw them in, and the document text is a
# pure function of that state.
#
# The order is total over whole operations (not just ids), so even a
# malicious client that reuses an id with different content cannot make
# replicas disagree.
import Base

# kind: 0 insert, 1 delete. An insert (ctr, rep) sits on `side` (0 left,
# 1 right) of its parent (pctr, prep); (0, 0) is the root. A delete hides
# the insert (pctr, prep). ch: the inserted character's code point.
type Op is Data:
  Op{ctr: Nat, rep: Nat, kind: Nat, pctr: Nat, prep: Nat, side: Nat, ch: Nat}

# ORDER
# -----

def lex(c: Cmp, d: Cmp) -> Cmp:
  match c:
    case EQ{}:
      d
    case LT{}:
      LT{}
    case GT{}:
      GT{}

def cmp(a: Op, b: Op) -> Cmp:
  match a b:
    case Op{+a1, +a2, +a3, +a4, +a5, +a6, +a7} Op{+b1, +b2, +b3, +b4, +b5, +b6, +b7}:
      lex(Nat.cmp(a1, b1), lex(Nat.cmp(a2, b2), lex(Nat.cmp(a3, b3), lex(Nat.cmp(a4, b4), lex(Nat.cmp(a5, b5), lex(Nat.cmp(a6, b6), Nat.cmp(a7, b7)))))))

def hd(xs: List<&2, Op>) -> Op:
  match xs:
    case Nil{}:
      Op{0n, 0n, 0n, 0n, 0n, 0n, 0n}
    case Con{x, t}:
      x

# MERGE
# -----
# c is cmp of the two heads (ignored when a list is empty); passing it in
# keeps this one self-recursive function (Bend has no mutual recursion and
# cannot match on a computed value).
def merge(+xs: List<&2, Op>, +ys: List<&2, Op>, c: Cmp) -> List<&2, Op>:
  match xs:
    case Nil{}:
      ys
    case Con{+x, +xt}:
      match ys:
        case Nil{}:
          xs
        case Con{+y, +yt}:
          match c:
            case LT{}:
              Con{x, merge(xt, ys, cmp(hd(xt), y))}
            case GT{}:
              Con{y, merge(xs, yt, cmp(x, hd(yt)))}
            case EQ{}:
              Con{x, merge(xt, yt, cmp(hd(xt), hd(yt)))}

# The union of two states.
def union(+xs: List<&2, Op>, +ys: List<&2, Op>) -> List<&2, Op>:
  merge(xs, ys, cmp(hd(xs), hd(ys)))
