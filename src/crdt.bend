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
import ../spec/text.bend as TSpec

# kind: 0 insert, 1 delete. An insert (ctr, rep) sits on `side` (0 left,
# 1 right) of its parent (pctr, prep); (0, 0) is the root. A delete hides
# the insert (pctr, prep). ch: the inserted character's code point.
type Op is Data:
  Op{ctr: Nat, rep: Nat, kind: Nat, pctr: Nat, prep: Nat, side: Nat, ch: Nat}

type Index is Data:
  Index{kids: Map<&2, List<&2, Op>>, dead: Map<&2, Bool>}

# Work items: visit a node's subtree, or emit a node.
type Item is Data:
  WVisit{op: Op}
  WEmit{op: Op}

# The nodes in document order (deleted ones included), with a flag each.
type DNode is Data:
  DNode{op: Op, live: Bool}

# From the node list, drop everything up to and including the pos-th live
# node (pos counted from 1). The node before the insertion point is
# reported with the rest.
type At is Data:
  At{before: Op, rest: List<&2, DNode>}

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

# MATERIALIZING
# -------------
# The Fugue tree: each insert is a node, the left or right child of its
# parent. The document is the in-order traversal (left children, the node,
# right children; siblings in state order, i.e. by (counter, replica)),
# skipping deleted nodes.
def key2(+c: Nat, +r: Nat) -> String:
  Nat.show(c) ++ ("," ++ Nat.show(r))

def key3(+c: Nat, +r: Nat, +side: Nat) -> String:
  key2(c, r) ++ ("," ++ Nat.show(side))

def snd_list(p: Map<&2, List<&2, Op>> & List<&2, Op>) -> List<&2, Op>:
  (m, v) = p
  v

def kids_of(+ix: Index, +k: String) -> List<&2, Op>:
  match ix:
    case Index{+kids, +dead}:
      List.reverse(&2, Op, snd_list(Map.get(List<&2, Op>, Nil{}, kids, k)))

def snd_bool(p: Map<&2, Bool> & Bool) -> Bool:
  (m, v) = p
  v

def is_dead(+ix: Index, +k: String) -> Bool:
  match ix:
    case Index{+kids, +dead}:
      snd_bool(Map.get(Bool, False{}, dead, k))

def index_pick(ins: Bool, +kids: Map<&2, List<&2, Op>>, +dead: Map<&2, Bool>, +k3: String, +k2: String, +op: Op) -> Index:
  match ins:
    case True{}:
      Index{Map.set(&2, List<&2, Op>, kids, k3, op <> snd_list(Map.get(List<&2, Op>, Nil{}, kids, k3))), dead}
    case False{}:
      Index{kids, Map.set(&2, Bool, dead, k2, True{})}

def index_op(+ix: Index, op: Op) -> Index:
  match ix:
    case Index{+kids, +dead}:
      match op:
        case Op{+c, +r, +k, +pc, +pr, +sd, +ch}:
          index_pick(Nat.is_eq(k, 0n), kids, dead, key3(pc, pr, sd), key2(pc, pr), Op{c, r, k, pc, pr, sd, ch})

def index(ops: List<&2, Op>, +ix: Index) -> Index:
  match ops:
    case Nil{}:
      ix
    case Con{op, t}:
      index(t, index_op(ix, op))

def visits(xs: List<&2, Op>, rest: List<&2, Item>) -> List<&2, Item>:
  match xs:
    case Nil{}:
      rest
    case Con{x, t}:
      WVisit{x} <> visits(t, rest)

def root() -> Op:
  Op{0n, 0n, 0n, 0n, 0n, 0n, 0n}

def is_root(+op: Op) -> Bool:
  match op:
    case Op{+c, +r, +k, +pc, +pr, +sd, +ch}:
      Bool.and(Nat.is_eq(c, 0n), Nat.is_eq(r, 0n))

def op_id(+op: Op) -> String:
  match op:
    case Op{+c, +r, +k, +pc, +pr, +sd, +ch}:
      key2(c, r)

def op_ch(+op: Op) -> Nat:
  match op:
    case Op{+c, +r, +k, +pc, +pr, +sd, +ch}:
      ch

def expand.self(b: Bool, +op: Op, rest: List<&2, Item>) -> List<&2, Item>:
  match b:
    case True{}:
      rest
    case False{}:
      WEmit{op} <> rest

def expand(+ix: Index, +op: Op, rest: List<&2, Item>) -> List<&2, Item>:
  visits(kids_of(ix, op_id(op) ++ ",0"), expand.self(is_root(op), op, visits(kids_of(ix, op_id(op) ++ ",1"), rest)))

def walk(n: Nat, +ix: Index, stack: List<&2, Item>, +out: List<&2, DNode>) -> List<&2, DNode>:
  match n:
    case 0n:
      out
    case 1n+p:
      match stack:
        case Nil{}:
          out
        case Con{it, rest}:
          match it:
            case WVisit{+op}:
              walk(p, ix, expand(ix, op, rest), out)
            case WEmit{+op}:
              walk(p, ix, rest, DNode{op, Bool.not(is_dead(ix, op_id(op)))} <> out)

def empty_index() -> Index:
  Index{Map.new(&2, List<&2, Op>), Map.new(&2, Bool)}

# All nodes in document order.
def nodes(+ops: List<&2, Op>) -> List<&2, DNode>:
  List.reverse(&2, DNode, walk(Nat.add(Nat.mul(List.length(&2, Op, ops), 2n), 4n), index(ops, empty_index()), WVisit{root()} <> Nil{}, Nil{}))

def live_text.pick(b: Bool, +ch: Nat, r: String) -> String:
  match b:
    case True{}:
      SCon{Chr{U32.from_nat(ch)}, r}
    case False{}:
      r

def live_text(xs: List<&2, DNode>) -> String:
  match xs:
    case Nil{}:
      ""
    case Con{x, t}:
      match x:
        case DNode{+op, live}:
          live_text.pick(live, op_ch(op), live_text(t))

# The document text.
def text(+ops: List<&2, Op>) -> String:
  live_text(nodes(ops))

# LOCAL EDITS
# -----------
def op_ctr(+op: Op) -> Nat:
  match op:
    case Op{+c, +r, +k, +pc, +pr, +sd, +ch}:
      c

def op_rep(+op: Op) -> Nat:
  match op:
    case Op{+c, +r, +k, +pc, +pr, +sd, +ch}:
      r

# The largest counter in a state (it is sorted by counter first).
def max_ctr(xs: List<&2, Op>, +m: Nat) -> Nat:
  match xs:
    case Nil{}:
      m
    case Con{+x, t}:
      max_ctr(t, op_ctr(x))

def node_op(+n: DNode) -> Op:
  match n:
    case DNode{+op, +live}:
      op

def node_live(+n: DNode) -> Bool:
  match n:
    case DNode{+op, +live}:
      live

def first_op(xs: List<&2, DNode>) -> Maybe<&2, Op>:
  match xs:
    case Nil{}:
      None{}
    case Con{+x, t}:
      Some{node_op(x)}

def place.pick(none: Bool, +a: Op, +b: Op, +ctr: Nat, +rep: Nat, +ch: Nat) -> Op:
  match none:
    case True{}:
      Op{ctr, rep, 0n, op_ctr(a), op_rep(a), 1n, ch}
    case False{}:
      Op{ctr, rep, 0n, op_ctr(b), op_rep(b), 0n, ch}

def place.go(+nr: Nat, +a: Op, b: Maybe<&2, Op>, +ctr: Nat, +rep: Nat, +ch: Nat) -> Op:
  match b:
    case None{}:
      Op{ctr, rep, 0n, op_ctr(a), op_rep(a), 1n, ch}
    case Some{+bo}:
      place.pick(Nat.is_eq(nr, 0n), a, bo, ctr, rep, ch)

# The first new node's parent and side (Fugue): right child of the node
# before, unless it already has right children; then left child of the next
# node in document order.
def place(+ix: Index, +a: Op, b: Maybe<&2, Op>, +ctr: Nat, +rep: Nat, +ch: Nat) -> Op:
  place.go(List.length(&2, Op, kids_of(ix, op_id(a) ++ ",1")), a, b, ctr, rep, ch)

# Inserting s: the first character is placed by the rule above, each next
# one is the right child of the previous (which has no children yet).
def chain(s: String, +ctr: Nat, +rep: Nat, +pc: Nat, +pr: Nat) -> List<&2, Op>:
  match s:
    case SNil{}:
      Nil{}
    case SCon{+c, t}:
      Op{ctr, rep, 0n, pc, pr, 1n, U32.to_nat(Char.to_u32(c))} <> chain(t, 1n+ctr, rep, ctr, rep)

def inserts.go(+first: Op, t: String, +ctr: Nat, +rep: Nat) -> List<&2, Op>:
  first <> chain(t, 1n+ctr, rep, ctr, rep)

def inserts(+ix: Index, +a: Op, b: Maybe<&2, Op>, s: String, +ctr: Nat, +rep: Nat) -> List<&2, Op>:
  match s:
    case SNil{}:
      Nil{}
    case SCon{+c, t}:
      inserts.go(place(ix, a, b, ctr, rep, U32.to_nat(Char.to_u32(c))), t, ctr, rep)

def head_live(xs: List<&2, DNode>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case Con{+x, t}:
      node_live(x)

# Skip to just after the pos-th live node (from 1); report the last live
# node passed (the node before the insertion point) and what follows.
# lv: whether the head of xs is live.
def at(+xs: List<&2, DNode>, +pos: Nat, lv: Bool, +before: Op) -> At:
  match xs:
    case Nil{}:
      At{before, Nil{}}
    case Con{+x, +t}:
      match pos:
        case 0n:
          At{before, xs}
        case 1n+p:
          match lv:
            case True{}:
              at(t, p, head_live(t), node_op(x))
            case False{}:
              at(t, 1n+p, head_live(t), before)

def edit.at(+xs: List<&2, DNode>, +pos: Nat) -> At:
  at(xs, pos, head_live(xs), root())

# The node after the insertion point (deleted nodes count: Fugue places
# relative to the full order).
def first_after(+rest: List<&2, DNode>, +dels: List<&2, Op>) -> Maybe<&2, Op>:
  first_op(rest)

def app(xs: List<&2, Op>, ys: List<&2, Op>) -> List<&2, Op>:
  match xs:
    case Nil{}:
      ys
    case Con{x, t}:
      x <> app(t, ys)

def edit.ins(+ix: Index, +before: Op, +rest: List<&2, DNode>, +dels: List<&2, Op>, +ctr: Nat, +rep: Nat, +s: String) -> List<&2, Op>:
  app(dels, inserts(ix, before, first_after(rest, dels), s, Nat.add(ctr, List.length(&2, Op, dels)), rep))

# Deletes for the next n live nodes. lv: whether the head of xs is live.
def deletes(xs: List<&2, DNode>, +n: Nat, lv: Bool, +ctr: Nat, +rep: Nat) -> List<&2, Op>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{+x, +t}:
      match n:
        case 0n:
          Nil{}
        case 1n+p:
          match lv:
            case True{}:
              Op{ctr, rep, 1n, op_ctr(node_op(x)), op_rep(node_op(x)), 0n, 0n} <> deletes(t, p, head_live(t), 1n+ctr, rep)
            case False{}:
              deletes(t, 1n+p, head_live(t), ctr, rep)

def edit.go(+ix: Index, +a: At, +ctr: Nat, +rep: Nat, +del: Nat, +s: String) -> List<&2, Op>:
  match a:
    case At{+before, +rest}:
      edit.ins(ix, before, rest, deletes(rest, del, head_live(rest), ctr, rep), ctr, rep, s)

# Deleting the next n live nodes.
def edit(+ops: List<&2, Op>, +rep: Nat, +pos: Nat, +del: Nat, +s: String) -> List<&2, Op>:
  edit.go(index(ops, empty_index()), edit.at(nodes(ops), pos), 1n+max_ctr(ops, 0n), rep, del, s)

# NORMALIZING (merge sort by union)
# -----------
def singles(xs: List<&2, Op>) -> List<&2, List<&2, Op>>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{x, t}:
      (x <> Nil{}) <> singles(t)

def pairs(xss: List<&2, List<&2, Op>>) -> List<&2, List<&2, Op>>:
  match xss:
    case Nil{}:
      Nil{}
    case Con{+a, t}:
      match t:
        case Nil{}:
          a <> Nil{}
        case Con{+b, u}:
          union(a, b) <> pairs(u)

def rounds(n: Nat, +xss: List<&2, List<&2, Op>>) -> List<&2, Op>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      match xss:
        case Nil{}:
          Nil{}
        case Con{+a, t}:
          match t:
            case Nil{}:
              a
            case Con{b, u}:
              rounds(p, pairs(xss))

# Sorted and duplicate-free.
def normalize(+xs: List<&2, Op>) -> List<&2, Op>:
  rounds(Nat.add(List.length(&2, Op, xs), 1n), singles(xs))

# WIRE FORMAT
# -----------
# "c.r.k.pc.pr.s.ch;" per operation, decimal.
def enc1(+op: Op) -> String:
  match op:
    case Op{+c, +r, +k, +pc, +pr, +sd, +ch}:
      Nat.show(c) ++ ("." ++ (Nat.show(r) ++ ("." ++ (Nat.show(k) ++ ("." ++ (Nat.show(pc) ++ ("." ++ (Nat.show(pr) ++ ("." ++ (Nat.show(sd) ++ ("." ++ (Nat.show(ch) ++ (";")))))))))))))

def encode(xs: List<&2, Op>) -> String:
  match xs:
    case Nil{}:
      ""
    case Con{+x, t}:
      enc1(x) ++ encode(t)

def num.of(m: Maybe<&2, U32>) -> Maybe<&2, Nat>:
  match m:
    case None{}:
      None{}
    case Some{+x}:
      Some{U32.to_nat(x)}

def num.go(b: Bool, +s: String) -> Maybe<&2, Nat>:
  match b:
    case True{}:
      num.of(U32.read(s))
    case False{}:
      None{}

def num(+s: String) -> Maybe<&2, Nat>:
  num.go(Nat.is_le(String.length(s), 9n), s)

def valid.go(b: Bool, +op: Op) -> Maybe<&2, Op>:
  match b:
    case True{}:
      Some{op}
    case False{}:
      None{}

def ch_ok.go(b: Bool, +ch: Nat) -> Bool:
  match b:
    case True{}:
      TSpec.body_char(Chr{U32.from_nat(ch)})
    case False{}:
      False{}

# A body character (spec/text.bend body_char). The number is range-checked
# (at most U+10FFFF, not a surrogate) before a Char is built from it: the
# JS runtime refuses to build an invalid Char at all.
def ch_ok(+ch: Nat) -> Bool:
  ch_ok.go(Bool.and(Nat.is_le(ch, U32.to_nat(1114111)), Bool.not(Bool.and(Nat.is_le(U32.to_nat(55296), ch), Nat.is_le(ch, U32.to_nat(57343))))), ch)

# An operation this code could have produced: counter and replica >= 1;
# an insert has side 0 or 1 and a character allowed in a post body; a
# delete names a non-root node and carries no side or character.
def valid(+op: Op) -> Maybe<&2, Op>:
  match op:
    case Op{+c, +r, +k, +pc, +pr, +sd, +ch}:
      valid.go(Bool.and(Nat.is_lt(0n, c), Bool.and(Nat.is_lt(0n, r), Bool.or(Bool.and(Nat.is_eq(k, 0n), Bool.and(Nat.is_le(sd, 1n), ch_ok(ch))), Bool.and(Nat.is_eq(k, 1n), Bool.and(Nat.is_eq(sd, 0n), Bool.and(Nat.is_eq(ch, 0n), Nat.is_lt(0n, pc))))))), op)

def mk7(a: Maybe<&2, Nat>, b: Maybe<&2, Nat>, c: Maybe<&2, Nat>, d: Maybe<&2, Nat>, e: Maybe<&2, Nat>, f: Maybe<&2, Nat>, g: Maybe<&2, Nat>) -> Maybe<&2, Op>:
  match a b c d e f g:
    case Some{+x1} Some{+x2} Some{+x3} Some{+x4} Some{+x5} Some{+x6} Some{+x7}:
      valid(Op{x1, x2, x3, x4, x5, x6, x7})
    case _ _ _ _ _ _ _:
      None{}

def dec_fields(xs: List<&2, String>) -> Maybe<&2, Op>:
  match xs:
    case Con{+a, t1}:
      match t1:
        case Con{+b, t2}:
          match t2:
            case Con{+c, t3}:
              match t3:
                case Con{+d, t4}:
                  match t4:
                    case Con{+e, t5}:
                      match t5:
                        case Con{+f, t6}:
                          match t6:
                            case Con{+g, t7}:
                              match t7:
                                case Nil{}:
                                  mk7(num(a), num(b), num(c), num(d), num(e), num(f), num(g))
                                case Con{h, t8}:
                                  None{}
                            case Nil{}:
                              None{}
                        case Nil{}:
                          None{}
                    case Nil{}:
                      None{}
                case Nil{}:
                  None{}
            case Nil{}:
              None{}
        case Nil{}:
          None{}
    case Nil{}:
      None{}

def dec_cons(a: Maybe<&2, Op>, b: Maybe<&2, List<&2, Op>>) -> Maybe<&2, List<&2, Op>>:
  match a b:
    case Some{x} Some{xs}:
      Some{x <> xs}
    case _ _:
      None{}

def dec_skip(b: Bool, +x: String, r: Maybe<&2, List<&2, Op>>) -> Maybe<&2, List<&2, Op>>:
  match b:
    case True{}:
      r
    case False{}:
      dec_cons(dec_fields(String.split(x, '.')), r)

def dec_all(xs: List<&2, String>) -> Maybe<&2, List<&2, Op>>:
  match xs:
    case Nil{}:
      Some{Nil{}}
    case Con{+x, t}:
      dec_skip(String.is_empty(x), x, dec_all(t))

def norm_of(m: Maybe<&2, List<&2, Op>>) -> Maybe<&2, List<&2, Op>>:
  match m:
    case None{}:
      None{}
    case Some{+xs}:
      Some{normalize(xs)}

# Operations from the wire, validated and normalized; None if any is bad.
def decode(+s: String) -> Maybe<&2, List<&2, Op>>:
  norm_of(dec_all(String.split(s, ';')))
