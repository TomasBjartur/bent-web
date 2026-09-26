# Spike: split the render cost into parts to see where time goes.
import Base
import ./main.bend as R

# A 14.7 KB-ish input string, built once per iteration.
def input(+seed: U32) -> String:
  String.repeat("Lorem ipsum <em>dolor</em> & sit amet, consectetur adipiscing elit. ", 200n) ++ U32.show(seed)

# 1. Just walk and rebuild the string (the floor for any per-char work).
def copy(s: String) -> String:
  match s:
    case SNil{}:
      SNil{}
    case SCon{h, t}:
      SCon{h, copy(t)}

# 2. Escape with a single U32 compare chain on the code point.
def esc2_class(+c: U32) -> U32:
  (Bool.to_u32(U32.is_eq(c, 60)) + (2 * Bool.to_u32(U32.is_eq(c, 62))) + (3 * Bool.to_u32(U32.is_eq(c, 38))) + (4 * Bool.to_u32(U32.is_eq(c, 34))) + (5 * Bool.to_u32(U32.is_eq(c, 39))) : U32)

def esc2_pick(k: Nat, +c: U32, rest: String) -> String:
  match k:
    case 0n:
      SCon{Chr{c}, rest}
    case 1n:
      SCon{'&', SCon{'l', SCon{'t', SCon{';', rest}}}}
    case 2n:
      SCon{'&', SCon{'g', SCon{'t', SCon{';', rest}}}}
    case 3n:
      SCon{'&', SCon{'a', SCon{'m', SCon{'p', SCon{';', rest}}}}}
    case 4n:
      SCon{'&', SCon{'q', SCon{'u', SCon{'o', SCon{'t', SCon{';', rest}}}}}}
    case _:
      SCon{'&', SCon{'#', SCon{'3', SCon{'9', SCon{';', rest}}}}}

def esc2(s: String, rest: String) -> String:
  match s:
    case SNil{}:
      rest
    case SCon{h, t}:
      +c = Char.to_u32(h)
      esc2_pick(U32.to_nat(esc2_class(c)), c, esc2(t, rest))

def run_nat(+mode: Nat, +seed: U32) -> Nat:
  match mode:
    case 0n:
      String.length(input(seed))
    case 1n:
      String.length(copy(input(seed)))
    case 2n:
      String.length(R.esc(input(seed), ""))
    case _:
      String.length(esc2(input(seed), ""))

def run(+mode: U32, +seed: U32) -> Nat:
  run_nat(U32.to_nat(mode), seed)

def bench(+n: Nat, +mode: U32, acc: Nat) -> Nat:
  match n:
    case 0n:
      acc
    case 1n+p:
      +len = run(mode, U32.from_nat(p))
      bench(p, mode, Nat.add(acc, len))

def time(+mode: U32, name: String) -> IO(Unit):
  do IO<Unit>:
    +t0 : Nat <- IO.now()
    +total : Nat = bench(2000n, mode, 0n)
    +t1 : Nat <- IO.now()
    IO.print(name ++ (" chars=" ++ (Nat.show(total) ++ (" ms=" ++ Nat.show(Nat.sub(t1, t0))))))

def main() -> IO(Unit):
  do IO<Unit>:
    time(0, "build input      ")
    time(1, "build+copy       ")
    time(2, "build+esc (naive)")
    time(3, "build+esc (u32)  ")
