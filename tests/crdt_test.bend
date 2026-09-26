# Tests for src/crdt.bend: behavior, concurrency, wire format, and a
# randomized convergence simulation.
import Base
import ../src/crdt.bend as C

# Three replicas A, B, C. Each round: each edits, then one random pair
# syncs one way. At the end all sync fully; all must be identical.
type Three is Data:
  Three{a: List<&2, C.Op>, b: List<&2, C.Op>, c: List<&2, C.Op>}

def msg(ok: Bool, name: String, got: String, want: String) -> String:
  match ok:
    case True{}:
      "PASS " ++ name
    case False{}:
      "FAIL " ++ (name ++ ("\n  got  " ++ (got ++ ("\n  want " ++ want))))

def check(name: String, +got: String, +want: String) -> IO(Unit):
  IO.print(msg(String.eq(got, want), name, got, want))

def check_b(name: String, b: Bool) -> IO(Unit):
  IO.print(msg(b, name, "false", "true"))

# Apply an edit locally: generate its ops and merge them in.
def ed(+st: List<&2, C.Op>, +rep: Nat, +pos: Nat, +del: Nat, +s: String) -> List<&2, C.Op>:
  C.union(st, C.edit(st, rep, pos, del, s))

def none() -> List<&2, C.Op>:
  Nil{}

def decodes.go(m: Maybe<&2, List<&2, C.Op>>) -> String:
  match m:
    case None{}:
      "none"
    case Some{+xs}:
      C.text(xs)

def decodes(+s: String) -> String:
  decodes.go(C.decode(s))

def next.c(+x: U32) -> U32:
  ((x .^. (x << 5n)) : U32)

def next.b(+x: U32) -> U32:
  next.c(((x .^. (x >> 17n)) : U32))

# PSEUDO-RANDOM (xorshift32)
def next(+x: U32) -> U32:
  next.b(((x .^. (x << 13n)) : U32))

def below(+x: U32, +n: Nat) -> Nat:
  U32.to_nat((x % U32.from_nat(Nat.add(n, 1n)) : U32))

def letter(+x: U32) -> String:
  SCon{Chr{((x % 26) + 97 : U32)}, ""}

def rand_str.go(+n: Nat, +x: U32) -> String:
  match n:
    case 0n:
      ""
    case 1n+p:
      letter(x) ++ rand_str.go(p, next(x))

def rand_str(+x: U32) -> String:
  rand_str.go(below(x, 3n), x)

# One random edit by replica rep on its state.
def rand_edit(+st: List<&2, C.Op>, +rep: Nat, +x: U32) -> List<&2, C.Op>:
  +len = String.length(C.text(st))
  +pos = below(x, len)
  ed(st, rep, pos, below(next(x), Nat.min(2n, Nat.sub(len, pos))), rand_str(next(next(x))))

def sync.pick(k: Nat, +a: List<&2, C.Op>, +b: List<&2, C.Op>, +c: List<&2, C.Op>) -> Three:
  match k:
    case 0n:
      Three{C.union(a, b), b, c}
    case 1n:
      Three{a, C.union(b, c), c}
    case 2n:
      Three{a, b, C.union(c, a)}
    case 3n:
      Three{C.union(a, c), b, c}
    case 4n:
      Three{a, C.union(b, a), c}
    case _:
      Three{a, b, C.union(c, b)}

def sync(+t: Three, +k: Nat) -> Three:
  match t:
    case Three{+a, +b, +c}:
      sync.pick(k, a, b, c)

def round(+t: Three, +x: U32) -> Three:
  match t:
    case Three{+a, +b, +c}:
      sync(Three{rand_edit(a, 1n, x), rand_edit(b, 2n, next(x)), rand_edit(c, 3n, next(next(x)))}, below(next(next(next(x))), 5n))

def rounds(n: Nat, +t: Three, +x: U32) -> Three:
  match n:
    case 0n:
      t
    case 1n+p:
      rounds(p, round(t, x), next(next(next(next(x)))))

def all_equal.go(+x: List<&2, C.Op>, +y: List<&2, C.Op>, +z: List<&2, C.Op>) -> Bool:
  Bool.and(String.eq(C.encode(x), C.encode(y)), String.eq(C.encode(y), C.encode(z)))

def all_equal(+t: Three) -> Bool:
  match t:
    case Three{+a, +b, +c}:
      all_equal.go(C.union(C.union(a, b), c), C.union(C.union(c, a), b), C.union(b, C.union(c, a)))

def assoc(+t: Three) -> Bool:
  match t:
    case Three{+a, +b, +c}:
      String.eq(C.encode(C.union(C.union(a, b), c)), C.encode(C.union(a, C.union(b, c))))

def sim(+seed: U32) -> Three:
  rounds(40n, Three{none(), none(), none()}, seed)

def trials(n: Nat, +seed: U32, +ok: Bool) -> Bool:
  match n:
    case 0n:
      ok
    case 1n+p:
      trials(p, next(seed), Bool.and(ok, Bool.and(all_equal(sim(seed)), assoc(sim(seed)))))

def main() -> IO(Unit):
  do IO<Unit>:
    +h : List<&2, C.Op> = ed(none(), 1n, 0n, 0n, "hello")
    check("type", C.text(h), "hello")
    check("insert middle", C.text(ed(h, 1n, 2n, 0n, "XY")), "heXYllo")
    check("insert end", C.text(ed(h, 1n, 5n, 0n, "!")), "hello!")
    check("insert start", C.text(ed(h, 1n, 0n, 0n, ">")), ">hello")
    check("delete", C.text(ed(h, 1n, 1n, 2n, "")), "hlo")
    check("replace", C.text(ed(h, 1n, 1n, 3n, "EY")), "hEYo")
    check("delete all then type", C.text(ed(ed(h, 1n, 0n, 5n, ""), 1n, 0n, 0n, "new")), "new")
    +a : List<&2, C.Op> = ed(none(), 1n, 0n, 0n, "abc")
    +b : List<&2, C.Op> = ed(none(), 2n, 0n, 0n, "xyz")
    check_b("concurrent same spot: not interleaved", Bool.or(String.eq(C.text(C.union(a, b)), "abcxyz"), String.eq(C.text(C.union(a, b)), "xyzabc")))
    check("concurrent: order independent", C.text(C.union(a, b)), C.text(C.union(b, a)))
    +ha : List<&2, C.Op> = ed(h, 1n, 2n, 0n, "AA")
    +hb : List<&2, C.Op> = ed(h, 2n, 2n, 0n, "BB")
    check_b("concurrent middle: runs kept whole", Bool.or(String.eq(C.text(C.union(ha, hb)), "heAABBllo"), String.eq(C.text(C.union(ha, hb)), "heBBAAllo")))
    +hd : List<&2, C.Op> = ed(h, 1n, 2n, 2n, "")
    +hi : List<&2, C.Op> = ed(h, 2n, 3n, 0n, "X")
    check("delete vs concurrent insert inside", C.text(C.union(hd, hi)), "heXo")
    check("idempotent", C.encode(C.union(h, h)), C.encode(h))
    check("wire round trip", decodes(C.encode(ha)), "heAAllo")
    check("wire: bad kind", decodes("1.1.2.0.0.1.97;"), "none")
    check("wire: control char", decodes("1.1.0.0.0.1.7;"), "none")
    check("wire: zero counter", decodes("0.1.0.0.0.1.97;"), "none")
    check("wire: zero replica", decodes("1.0.0.0.0.1.97;"), "none")
    check("wire: delete of root", decodes("1.1.1.0.0.0.0;"), "none")
    check("wire: surrogate", decodes("1.1.0.0.0.1.55296;"), "none")
    check("wire: above max scalar", decodes("1.1.0.0.0.1.1114112;"), "none")
    check("wire: 6 fields", decodes("1.1.0.0.0.1;"), "none")
    check("wire: garbage", decodes("1.1.x.0.0.1.97;"), "none")
    check("wire: unsorted input is normalized", decodes("2.1.0.1.1.1.98;1.1.0.0.0.1.97;1.1.0.0.0.1.97;"), "ab")
    check("wire: newline and tab allowed", decodes("1.1.0.0.0.1.10;2.1.0.1.1.1.9;"), "\n\t")
    check_b("random: 20 simulations of 3 replicas converge, union associative", trials(20n, 12345, True{}))
