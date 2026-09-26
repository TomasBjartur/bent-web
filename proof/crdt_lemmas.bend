# Lemmas for the CRDT laws (src/crdt.bend).
import Base
import ../src/crdt.bend as Crdt
import ./lemmas.bend as L

def flip(c: Cmp) -> Cmp:
  match c:
    case LT{}:
      GT{}
    case EQ{}:
      EQ{}
    case GT{}:
      LT{}

# CMP DISCRIMINATION

def cmp_is_eq(c: Cmp) -> Type:
  match c:
    case EQ{}:
      Empty
    case LT{}:
      Unit
    case GT{}:
      Unit

def lt_ne_eq(e: {LT{} == EQ{} : Cmp}) -> Empty:
  %e : cmp_is_eq(_)
  Unit{}

def gt_ne_eq(e: {GT{} == EQ{} : Cmp}) -> Empty:
  %e : cmp_is_eq(_)
  Unit{}

def absurd_nat(z: Empty, -a: Nat, -b: Nat) -> {a == b : Nat}:
  match z:

def absurd_cmp(z: Empty, -c: Cmp) -> {c == EQ{} : Cmp}:
  match z:

# NAT

def nat_cmp_refl(+a: Nat) -> {Nat.cmp(a, a) == EQ{} : Cmp}:
  match a:
    case 0n:
      {==}
    case 1n+p:
      nat_cmp_refl(p)

def nat_cmp_flip(+a: Nat, +b: Nat) -> {Nat.cmp(b, a) == flip(Nat.cmp(a, b)) : Cmp}:
  match a b:
    case 0n 0n:
      {==}
    case 0n 1n+bp:
      {==}
    case 1n+ap 0n:
      {==}
    case 1n+ap 1n+bp:
      nat_cmp_flip(ap, bp)

def nat_cmp_eq(+a: Nat, +b: Nat, e: {Nat.cmp(a, b) == EQ{} : Cmp}) -> {a == b : Nat}:
  match a b:
    case 0n 0n:
      {==}
    case 0n 1n+bp:
      absurd_nat(lt_ne_eq(e), 0n, 1n+bp)
    case 1n+ap 0n:
      absurd_nat(gt_ne_eq(e), 1n+ap, 0n)
    case 1n+ap 1n+bp:
      %nat_cmp_eq(ap, bp, e) : {1n+ap == 1n+_ : Nat}
      {==}

# LEX

def lex_flip(c: Cmp, -d: Cmp) -> {Crdt.lex(flip(c), flip(d)) == flip(Crdt.lex(c, d)) : Cmp}:
  match c:
    case EQ{}:
      {==}
    case LT{}:
      {==}
    case GT{}:
      {==}

def lex_eq_l(c: Cmp, -d: Cmp, e: {Crdt.lex(c, d) == EQ{} : Cmp}) -> {c == EQ{} : Cmp}:
  match c:
    case EQ{}:
      {==}
    case LT{}:
      absurd_cmp(lt_ne_eq(e), LT{})
    case GT{}:
      absurd_cmp(gt_ne_eq(e), GT{})

def lex_eq_r(c: Cmp, -d: Cmp, e: {Crdt.lex(c, d) == EQ{} : Cmp}) -> {d == EQ{} : Cmp}:
  match c:
    case EQ{}:
      e
    case LT{}:
      absurd_cmp(lt_ne_eq(e), d)
    case GT{}:
      absurd_cmp(gt_ne_eq(e), d)


# OPS

def op_cmp_refl(+a: Crdt.Op) -> {Crdt.cmp(a, a) == EQ{} : Cmp}:
  match a:
    case Crdt.Op{+a1, +a2, +a3, +a4, +a5, +a6, +a7}:
    %Equal.sym(Cmp, Nat.cmp(a1, a1), EQ{}, nat_cmp_refl(a1)) : {Crdt.lex(_, Crdt.lex(Nat.cmp(a2, a2), Crdt.lex(Nat.cmp(a3, a3), Crdt.lex(Nat.cmp(a4, a4), Crdt.lex(Nat.cmp(a5, a5), Crdt.lex(Nat.cmp(a6, a6), Nat.cmp(a7, a7))))))) == EQ{} : Cmp}
    %Equal.sym(Cmp, Nat.cmp(a2, a2), EQ{}, nat_cmp_refl(a2)) : {Crdt.lex(_, Crdt.lex(Nat.cmp(a3, a3), Crdt.lex(Nat.cmp(a4, a4), Crdt.lex(Nat.cmp(a5, a5), Crdt.lex(Nat.cmp(a6, a6), Nat.cmp(a7, a7)))))) == EQ{} : Cmp}
    %Equal.sym(Cmp, Nat.cmp(a3, a3), EQ{}, nat_cmp_refl(a3)) : {Crdt.lex(_, Crdt.lex(Nat.cmp(a4, a4), Crdt.lex(Nat.cmp(a5, a5), Crdt.lex(Nat.cmp(a6, a6), Nat.cmp(a7, a7))))) == EQ{} : Cmp}
    %Equal.sym(Cmp, Nat.cmp(a4, a4), EQ{}, nat_cmp_refl(a4)) : {Crdt.lex(_, Crdt.lex(Nat.cmp(a5, a5), Crdt.lex(Nat.cmp(a6, a6), Nat.cmp(a7, a7)))) == EQ{} : Cmp}
    %Equal.sym(Cmp, Nat.cmp(a5, a5), EQ{}, nat_cmp_refl(a5)) : {Crdt.lex(_, Crdt.lex(Nat.cmp(a6, a6), Nat.cmp(a7, a7))) == EQ{} : Cmp}
    %Equal.sym(Cmp, Nat.cmp(a6, a6), EQ{}, nat_cmp_refl(a6)) : {Crdt.lex(_, Nat.cmp(a7, a7)) == EQ{} : Cmp}
    %Equal.sym(Cmp, Nat.cmp(a7, a7), EQ{}, nat_cmp_refl(a7)) : {_ == EQ{} : Cmp}
    {==}


def op_cmp_flip(+a: Crdt.Op, +b: Crdt.Op) -> {Crdt.cmp(b, a) == flip(Crdt.cmp(a, b)) : Cmp}:
  match a b:
    case Crdt.Op{+a1, +a2, +a3, +a4, +a5, +a6, +a7} Crdt.Op{+b1, +b2, +b3, +b4, +b5, +b6, +b7}:
      %Equal.sym(Cmp, Nat.cmp(b1, a1), flip(Nat.cmp(a1, b1)), nat_cmp_flip(a1, b1)) : {Crdt.lex(_, Crdt.lex(Nat.cmp(b2, a2), Crdt.lex(Nat.cmp(b3, a3), Crdt.lex(Nat.cmp(b4, a4), Crdt.lex(Nat.cmp(b5, a5), Crdt.lex(Nat.cmp(b6, a6), Nat.cmp(b7, a7))))))) == flip(Crdt.lex(Nat.cmp(a1, b1), Crdt.lex(Nat.cmp(a2, b2), Crdt.lex(Nat.cmp(a3, b3), Crdt.lex(Nat.cmp(a4, b4), Crdt.lex(Nat.cmp(a5, b5), Crdt.lex(Nat.cmp(a6, b6), Nat.cmp(a7, b7)))))))) : Cmp}
      %Equal.sym(Cmp, Nat.cmp(b2, a2), flip(Nat.cmp(a2, b2)), nat_cmp_flip(a2, b2)) : {Crdt.lex(flip(Nat.cmp(a1, b1)), Crdt.lex(_, Crdt.lex(Nat.cmp(b3, a3), Crdt.lex(Nat.cmp(b4, a4), Crdt.lex(Nat.cmp(b5, a5), Crdt.lex(Nat.cmp(b6, a6), Nat.cmp(b7, a7))))))) == flip(Crdt.lex(Nat.cmp(a1, b1), Crdt.lex(Nat.cmp(a2, b2), Crdt.lex(Nat.cmp(a3, b3), Crdt.lex(Nat.cmp(a4, b4), Crdt.lex(Nat.cmp(a5, b5), Crdt.lex(Nat.cmp(a6, b6), Nat.cmp(a7, b7)))))))) : Cmp}
      %Equal.sym(Cmp, Nat.cmp(b3, a3), flip(Nat.cmp(a3, b3)), nat_cmp_flip(a3, b3)) : {Crdt.lex(flip(Nat.cmp(a1, b1)), Crdt.lex(flip(Nat.cmp(a2, b2)), Crdt.lex(_, Crdt.lex(Nat.cmp(b4, a4), Crdt.lex(Nat.cmp(b5, a5), Crdt.lex(Nat.cmp(b6, a6), Nat.cmp(b7, a7))))))) == flip(Crdt.lex(Nat.cmp(a1, b1), Crdt.lex(Nat.cmp(a2, b2), Crdt.lex(Nat.cmp(a3, b3), Crdt.lex(Nat.cmp(a4, b4), Crdt.lex(Nat.cmp(a5, b5), Crdt.lex(Nat.cmp(a6, b6), Nat.cmp(a7, b7)))))))) : Cmp}
      %Equal.sym(Cmp, Nat.cmp(b4, a4), flip(Nat.cmp(a4, b4)), nat_cmp_flip(a4, b4)) : {Crdt.lex(flip(Nat.cmp(a1, b1)), Crdt.lex(flip(Nat.cmp(a2, b2)), Crdt.lex(flip(Nat.cmp(a3, b3)), Crdt.lex(_, Crdt.lex(Nat.cmp(b5, a5), Crdt.lex(Nat.cmp(b6, a6), Nat.cmp(b7, a7))))))) == flip(Crdt.lex(Nat.cmp(a1, b1), Crdt.lex(Nat.cmp(a2, b2), Crdt.lex(Nat.cmp(a3, b3), Crdt.lex(Nat.cmp(a4, b4), Crdt.lex(Nat.cmp(a5, b5), Crdt.lex(Nat.cmp(a6, b6), Nat.cmp(a7, b7)))))))) : Cmp}
      %Equal.sym(Cmp, Nat.cmp(b5, a5), flip(Nat.cmp(a5, b5)), nat_cmp_flip(a5, b5)) : {Crdt.lex(flip(Nat.cmp(a1, b1)), Crdt.lex(flip(Nat.cmp(a2, b2)), Crdt.lex(flip(Nat.cmp(a3, b3)), Crdt.lex(flip(Nat.cmp(a4, b4)), Crdt.lex(_, Crdt.lex(Nat.cmp(b6, a6), Nat.cmp(b7, a7))))))) == flip(Crdt.lex(Nat.cmp(a1, b1), Crdt.lex(Nat.cmp(a2, b2), Crdt.lex(Nat.cmp(a3, b3), Crdt.lex(Nat.cmp(a4, b4), Crdt.lex(Nat.cmp(a5, b5), Crdt.lex(Nat.cmp(a6, b6), Nat.cmp(a7, b7)))))))) : Cmp}
      %Equal.sym(Cmp, Nat.cmp(b6, a6), flip(Nat.cmp(a6, b6)), nat_cmp_flip(a6, b6)) : {Crdt.lex(flip(Nat.cmp(a1, b1)), Crdt.lex(flip(Nat.cmp(a2, b2)), Crdt.lex(flip(Nat.cmp(a3, b3)), Crdt.lex(flip(Nat.cmp(a4, b4)), Crdt.lex(flip(Nat.cmp(a5, b5)), Crdt.lex(_, Nat.cmp(b7, a7))))))) == flip(Crdt.lex(Nat.cmp(a1, b1), Crdt.lex(Nat.cmp(a2, b2), Crdt.lex(Nat.cmp(a3, b3), Crdt.lex(Nat.cmp(a4, b4), Crdt.lex(Nat.cmp(a5, b5), Crdt.lex(Nat.cmp(a6, b6), Nat.cmp(a7, b7)))))))) : Cmp}
      %Equal.sym(Cmp, Nat.cmp(b7, a7), flip(Nat.cmp(a7, b7)), nat_cmp_flip(a7, b7)) : {Crdt.lex(flip(Nat.cmp(a1, b1)), Crdt.lex(flip(Nat.cmp(a2, b2)), Crdt.lex(flip(Nat.cmp(a3, b3)), Crdt.lex(flip(Nat.cmp(a4, b4)), Crdt.lex(flip(Nat.cmp(a5, b5)), Crdt.lex(flip(Nat.cmp(a6, b6)), _)))))) == flip(Crdt.lex(Nat.cmp(a1, b1), Crdt.lex(Nat.cmp(a2, b2), Crdt.lex(Nat.cmp(a3, b3), Crdt.lex(Nat.cmp(a4, b4), Crdt.lex(Nat.cmp(a5, b5), Crdt.lex(Nat.cmp(a6, b6), Nat.cmp(a7, b7)))))))) : Cmp}
      %Equal.sym(Cmp, Crdt.lex(flip(Nat.cmp(a6, b6)), flip(Nat.cmp(a7, b7))), flip(Crdt.lex(Nat.cmp(a6, b6), Nat.cmp(a7, b7))), lex_flip(Nat.cmp(a6, b6), Nat.cmp(a7, b7))) : {Crdt.lex(flip(Nat.cmp(a1, b1)), Crdt.lex(flip(Nat.cmp(a2, b2)), Crdt.lex(flip(Nat.cmp(a3, b3)), Crdt.lex(flip(Nat.cmp(a4, b4)), Crdt.lex(flip(Nat.cmp(a5, b5)), _))))) == flip(Crdt.lex(Nat.cmp(a1, b1), Crdt.lex(Nat.cmp(a2, b2), Crdt.lex(Nat.cmp(a3, b3), Crdt.lex(Nat.cmp(a4, b4), Crdt.lex(Nat.cmp(a5, b5), Crdt.lex(Nat.cmp(a6, b6), Nat.cmp(a7, b7)))))))) : Cmp}
      %Equal.sym(Cmp, Crdt.lex(flip(Nat.cmp(a5, b5)), flip(Crdt.lex(Nat.cmp(a6, b6), Nat.cmp(a7, b7)))), flip(Crdt.lex(Nat.cmp(a5, b5), Crdt.lex(Nat.cmp(a6, b6), Nat.cmp(a7, b7)))), lex_flip(Nat.cmp(a5, b5), Crdt.lex(Nat.cmp(a6, b6), Nat.cmp(a7, b7)))) : {Crdt.lex(flip(Nat.cmp(a1, b1)), Crdt.lex(flip(Nat.cmp(a2, b2)), Crdt.lex(flip(Nat.cmp(a3, b3)), Crdt.lex(flip(Nat.cmp(a4, b4)), _)))) == flip(Crdt.lex(Nat.cmp(a1, b1), Crdt.lex(Nat.cmp(a2, b2), Crdt.lex(Nat.cmp(a3, b3), Crdt.lex(Nat.cmp(a4, b4), Crdt.lex(Nat.cmp(a5, b5), Crdt.lex(Nat.cmp(a6, b6), Nat.cmp(a7, b7)))))))) : Cmp}
      %Equal.sym(Cmp, Crdt.lex(flip(Nat.cmp(a4, b4)), flip(Crdt.lex(Nat.cmp(a5, b5), Crdt.lex(Nat.cmp(a6, b6), Nat.cmp(a7, b7))))), flip(Crdt.lex(Nat.cmp(a4, b4), Crdt.lex(Nat.cmp(a5, b5), Crdt.lex(Nat.cmp(a6, b6), Nat.cmp(a7, b7))))), lex_flip(Nat.cmp(a4, b4), Crdt.lex(Nat.cmp(a5, b5), Crdt.lex(Nat.cmp(a6, b6), Nat.cmp(a7, b7))))) : {Crdt.lex(flip(Nat.cmp(a1, b1)), Crdt.lex(flip(Nat.cmp(a2, b2)), Crdt.lex(flip(Nat.cmp(a3, b3)), _))) == flip(Crdt.lex(Nat.cmp(a1, b1), Crdt.lex(Nat.cmp(a2, b2), Crdt.lex(Nat.cmp(a3, b3), Crdt.lex(Nat.cmp(a4, b4), Crdt.lex(Nat.cmp(a5, b5), Crdt.lex(Nat.cmp(a6, b6), Nat.cmp(a7, b7)))))))) : Cmp}
      %Equal.sym(Cmp, Crdt.lex(flip(Nat.cmp(a3, b3)), flip(Crdt.lex(Nat.cmp(a4, b4), Crdt.lex(Nat.cmp(a5, b5), Crdt.lex(Nat.cmp(a6, b6), Nat.cmp(a7, b7)))))), flip(Crdt.lex(Nat.cmp(a3, b3), Crdt.lex(Nat.cmp(a4, b4), Crdt.lex(Nat.cmp(a5, b5), Crdt.lex(Nat.cmp(a6, b6), Nat.cmp(a7, b7)))))), lex_flip(Nat.cmp(a3, b3), Crdt.lex(Nat.cmp(a4, b4), Crdt.lex(Nat.cmp(a5, b5), Crdt.lex(Nat.cmp(a6, b6), Nat.cmp(a7, b7)))))) : {Crdt.lex(flip(Nat.cmp(a1, b1)), Crdt.lex(flip(Nat.cmp(a2, b2)), _)) == flip(Crdt.lex(Nat.cmp(a1, b1), Crdt.lex(Nat.cmp(a2, b2), Crdt.lex(Nat.cmp(a3, b3), Crdt.lex(Nat.cmp(a4, b4), Crdt.lex(Nat.cmp(a5, b5), Crdt.lex(Nat.cmp(a6, b6), Nat.cmp(a7, b7)))))))) : Cmp}
      %Equal.sym(Cmp, Crdt.lex(flip(Nat.cmp(a2, b2)), flip(Crdt.lex(Nat.cmp(a3, b3), Crdt.lex(Nat.cmp(a4, b4), Crdt.lex(Nat.cmp(a5, b5), Crdt.lex(Nat.cmp(a6, b6), Nat.cmp(a7, b7))))))), flip(Crdt.lex(Nat.cmp(a2, b2), Crdt.lex(Nat.cmp(a3, b3), Crdt.lex(Nat.cmp(a4, b4), Crdt.lex(Nat.cmp(a5, b5), Crdt.lex(Nat.cmp(a6, b6), Nat.cmp(a7, b7))))))), lex_flip(Nat.cmp(a2, b2), Crdt.lex(Nat.cmp(a3, b3), Crdt.lex(Nat.cmp(a4, b4), Crdt.lex(Nat.cmp(a5, b5), Crdt.lex(Nat.cmp(a6, b6), Nat.cmp(a7, b7))))))) : {Crdt.lex(flip(Nat.cmp(a1, b1)), _) == flip(Crdt.lex(Nat.cmp(a1, b1), Crdt.lex(Nat.cmp(a2, b2), Crdt.lex(Nat.cmp(a3, b3), Crdt.lex(Nat.cmp(a4, b4), Crdt.lex(Nat.cmp(a5, b5), Crdt.lex(Nat.cmp(a6, b6), Nat.cmp(a7, b7)))))))) : Cmp}
      %Equal.sym(Cmp, Crdt.lex(flip(Nat.cmp(a1, b1)), flip(Crdt.lex(Nat.cmp(a2, b2), Crdt.lex(Nat.cmp(a3, b3), Crdt.lex(Nat.cmp(a4, b4), Crdt.lex(Nat.cmp(a5, b5), Crdt.lex(Nat.cmp(a6, b6), Nat.cmp(a7, b7)))))))), flip(Crdt.lex(Nat.cmp(a1, b1), Crdt.lex(Nat.cmp(a2, b2), Crdt.lex(Nat.cmp(a3, b3), Crdt.lex(Nat.cmp(a4, b4), Crdt.lex(Nat.cmp(a5, b5), Crdt.lex(Nat.cmp(a6, b6), Nat.cmp(a7, b7)))))))), lex_flip(Nat.cmp(a1, b1), Crdt.lex(Nat.cmp(a2, b2), Crdt.lex(Nat.cmp(a3, b3), Crdt.lex(Nat.cmp(a4, b4), Crdt.lex(Nat.cmp(a5, b5), Crdt.lex(Nat.cmp(a6, b6), Nat.cmp(a7, b7)))))))) : {_ == flip(Crdt.lex(Nat.cmp(a1, b1), Crdt.lex(Nat.cmp(a2, b2), Crdt.lex(Nat.cmp(a3, b3), Crdt.lex(Nat.cmp(a4, b4), Crdt.lex(Nat.cmp(a5, b5), Crdt.lex(Nat.cmp(a6, b6), Nat.cmp(a7, b7)))))))) : Cmp}
      {==}


def op_cmp_eq(+a: Crdt.Op, +b: Crdt.Op, +e: {Crdt.cmp(a, b) == EQ{} : Cmp}) -> {a == b : Crdt.Op}:
  match a b:
    case Crdt.Op{+a1, +a2, +a3, +a4, +a5, +a6, +a7} Crdt.Op{+b1, +b2, +b3, +b4, +b5, +b6, +b7}:
      e0 = lex_eq_l(Nat.cmp(a1, b1), Crdt.lex(Nat.cmp(a2, b2), Crdt.lex(Nat.cmp(a3, b3), Crdt.lex(Nat.cmp(a4, b4), Crdt.lex(Nat.cmp(a5, b5), Crdt.lex(Nat.cmp(a6, b6), Nat.cmp(a7, b7)))))), e)
      +r0 = lex_eq_r(Nat.cmp(a1, b1), Crdt.lex(Nat.cmp(a2, b2), Crdt.lex(Nat.cmp(a3, b3), Crdt.lex(Nat.cmp(a4, b4), Crdt.lex(Nat.cmp(a5, b5), Crdt.lex(Nat.cmp(a6, b6), Nat.cmp(a7, b7)))))), e)
      e1 = lex_eq_l(Nat.cmp(a2, b2), Crdt.lex(Nat.cmp(a3, b3), Crdt.lex(Nat.cmp(a4, b4), Crdt.lex(Nat.cmp(a5, b5), Crdt.lex(Nat.cmp(a6, b6), Nat.cmp(a7, b7))))), r0)
      +r1 = lex_eq_r(Nat.cmp(a2, b2), Crdt.lex(Nat.cmp(a3, b3), Crdt.lex(Nat.cmp(a4, b4), Crdt.lex(Nat.cmp(a5, b5), Crdt.lex(Nat.cmp(a6, b6), Nat.cmp(a7, b7))))), r0)
      e2 = lex_eq_l(Nat.cmp(a3, b3), Crdt.lex(Nat.cmp(a4, b4), Crdt.lex(Nat.cmp(a5, b5), Crdt.lex(Nat.cmp(a6, b6), Nat.cmp(a7, b7)))), r1)
      +r2 = lex_eq_r(Nat.cmp(a3, b3), Crdt.lex(Nat.cmp(a4, b4), Crdt.lex(Nat.cmp(a5, b5), Crdt.lex(Nat.cmp(a6, b6), Nat.cmp(a7, b7)))), r1)
      e3 = lex_eq_l(Nat.cmp(a4, b4), Crdt.lex(Nat.cmp(a5, b5), Crdt.lex(Nat.cmp(a6, b6), Nat.cmp(a7, b7))), r2)
      +r3 = lex_eq_r(Nat.cmp(a4, b4), Crdt.lex(Nat.cmp(a5, b5), Crdt.lex(Nat.cmp(a6, b6), Nat.cmp(a7, b7))), r2)
      e4 = lex_eq_l(Nat.cmp(a5, b5), Crdt.lex(Nat.cmp(a6, b6), Nat.cmp(a7, b7)), r3)
      +r4 = lex_eq_r(Nat.cmp(a5, b5), Crdt.lex(Nat.cmp(a6, b6), Nat.cmp(a7, b7)), r3)
      e5 = lex_eq_l(Nat.cmp(a6, b6), Nat.cmp(a7, b7), r4)
      +r5 = lex_eq_r(Nat.cmp(a6, b6), Nat.cmp(a7, b7), r4)
      e6 = r5
      q0 = nat_cmp_eq(a1, b1, e0)
      q1 = nat_cmp_eq(a2, b2, e1)
      q2 = nat_cmp_eq(a3, b3, e2)
      q3 = nat_cmp_eq(a4, b4, e3)
      q4 = nat_cmp_eq(a5, b5, e4)
      q5 = nat_cmp_eq(a6, b6, e5)
      q6 = nat_cmp_eq(a7, b7, e6)
      %q0 : {Crdt.Op{a1, a2, a3, a4, a5, a6, a7} == Crdt.Op{_, b2, b3, b4, b5, b6, b7} : Crdt.Op}
      %q1 : {Crdt.Op{a1, a2, a3, a4, a5, a6, a7} == Crdt.Op{a1, _, b3, b4, b5, b6, b7} : Crdt.Op}
      %q2 : {Crdt.Op{a1, a2, a3, a4, a5, a6, a7} == Crdt.Op{a1, a2, _, b4, b5, b6, b7} : Crdt.Op}
      %q3 : {Crdt.Op{a1, a2, a3, a4, a5, a6, a7} == Crdt.Op{a1, a2, a3, _, b5, b6, b7} : Crdt.Op}
      %q4 : {Crdt.Op{a1, a2, a3, a4, a5, a6, a7} == Crdt.Op{a1, a2, a3, a4, _, b6, b7} : Crdt.Op}
      %q5 : {Crdt.Op{a1, a2, a3, a4, a5, a6, a7} == Crdt.Op{a1, a2, a3, a4, a5, _, b7} : Crdt.Op}
      %q6 : {Crdt.Op{a1, a2, a3, a4, a5, a6, a7} == Crdt.Op{a1, a2, a3, a4, a5, a6, _} : Crdt.Op}
      {==}

# MERGE

def cons_cong(+x: Crdt.Op, -a: List<&2, Crdt.Op>, -b: List<&2, Crdt.Op>, e: {a == b : List<&2, Crdt.Op>}) -> {Con{x, a} == Con{x, b} : List<&2, Crdt.Op>}:
  %e : {Con{x, a} == Con{x, _} : List<&2, Crdt.Op>}
  {==}

# Commutativity, one self-recursive lemma. c is the comparison of the heads
# and e says so; matching on c then refines e.
def merge_comm(+xs: List<&2, Crdt.Op>, +ys: List<&2, Crdt.Op>, c: Cmp, +e: {Crdt.cmp(Crdt.hd(xs), Crdt.hd(ys)) == c : Cmp}) -> {Crdt.merge(xs, ys, Crdt.cmp(Crdt.hd(xs), Crdt.hd(ys))) == Crdt.merge(ys, xs, Crdt.cmp(Crdt.hd(ys), Crdt.hd(xs))) : List<&2, Crdt.Op>}:
  match xs:
    case Nil{}:
      match ys:
        case Nil{}:
          {==}
        case Con{y, yt}:
          {==}
    case Con{+x, +xt}:
      match ys:
        case Nil{}:
          {==}
        case Con{+y, +yt}:
          match c:
            case LT{}:
              %Equal.sym(Cmp, Crdt.cmp(y, x), flip(Crdt.cmp(x, y)), op_cmp_flip(x, y)) : {Crdt.merge(Con{x, xt}, Con{y, yt}, Crdt.cmp(x, y)) == Crdt.merge(Con{y, yt}, Con{x, xt}, _) : List<&2, Crdt.Op>}
              %Equal.sym(Cmp, Crdt.cmp(x, y), LT{}, e) : {Crdt.merge(Con{x, xt}, Con{y, yt}, _) == Crdt.merge(Con{y, yt}, Con{x, xt}, flip(_)) : List<&2, Crdt.Op>}
              cons_cong(x, Crdt.merge(xt, Con{y, yt}, Crdt.cmp(Crdt.hd(xt), y)), Crdt.merge(Con{y, yt}, xt, Crdt.cmp(y, Crdt.hd(xt))), merge_comm(xt, Con{y, yt}, Crdt.cmp(Crdt.hd(xt), y), {==}))
            case GT{}:
              %Equal.sym(Cmp, Crdt.cmp(y, x), flip(Crdt.cmp(x, y)), op_cmp_flip(x, y)) : {Crdt.merge(Con{x, xt}, Con{y, yt}, Crdt.cmp(x, y)) == Crdt.merge(Con{y, yt}, Con{x, xt}, _) : List<&2, Crdt.Op>}
              %Equal.sym(Cmp, Crdt.cmp(x, y), GT{}, e) : {Crdt.merge(Con{x, xt}, Con{y, yt}, _) == Crdt.merge(Con{y, yt}, Con{x, xt}, flip(_)) : List<&2, Crdt.Op>}
              cons_cong(y, Crdt.merge(Con{x, xt}, yt, Crdt.cmp(x, Crdt.hd(yt))), Crdt.merge(yt, Con{x, xt}, Crdt.cmp(Crdt.hd(yt), x)), merge_comm(Con{x, xt}, yt, Crdt.cmp(x, Crdt.hd(yt)), {==}))
            case EQ{}:
              %Equal.sym(Cmp, Crdt.cmp(y, x), flip(Crdt.cmp(x, y)), op_cmp_flip(x, y)) : {Crdt.merge(Con{x, xt}, Con{y, yt}, Crdt.cmp(x, y)) == Crdt.merge(Con{y, yt}, Con{x, xt}, _) : List<&2, Crdt.Op>}
              %Equal.sym(Cmp, Crdt.cmp(x, y), EQ{}, e) : {Crdt.merge(Con{x, xt}, Con{y, yt}, _) == Crdt.merge(Con{y, yt}, Con{x, xt}, flip(_)) : List<&2, Crdt.Op>}
              %op_cmp_eq(x, y, e) : {Con{x, Crdt.merge(xt, yt, Crdt.cmp(Crdt.hd(xt), Crdt.hd(yt)))} == Con{_, Crdt.merge(yt, xt, Crdt.cmp(Crdt.hd(yt), Crdt.hd(xt)))} : List<&2, Crdt.Op>}
              cons_cong(x, Crdt.merge(xt, yt, Crdt.cmp(Crdt.hd(xt), Crdt.hd(yt))), Crdt.merge(yt, xt, Crdt.cmp(Crdt.hd(yt), Crdt.hd(xt))), merge_comm(xt, yt, Crdt.cmp(Crdt.hd(xt), Crdt.hd(yt)), {==}))

def merge_idem(+xs: List<&2, Crdt.Op>) -> {Crdt.merge(xs, xs, Crdt.cmp(Crdt.hd(xs), Crdt.hd(xs))) == xs : List<&2, Crdt.Op>}:
  match xs:
    case Nil{}:
      {==}
    case Con{+x, +xt}:
      %Equal.sym(Cmp, Crdt.cmp(x, x), EQ{}, op_cmp_refl(x)) : {Crdt.merge(Con{x, xt}, Con{x, xt}, _) == Con{x, xt} : List<&2, Crdt.Op>}
      cons_cong(x, Crdt.merge(xt, xt, Crdt.cmp(Crdt.hd(xt), Crdt.hd(xt))), xt, merge_idem(xt))

# THE FAST MERGE EQUALS THE SPECIFIED ONE

def merge_acc_eq(+xs: List<&2, Crdt.Op>, +ys: List<&2, Crdt.Op>, c: Cmp, +acc: List<&2, Crdt.Op>) -> {Crdt.merge_acc(xs, ys, c, acc) == Crdt.rev_app(acc, Crdt.merge(xs, ys, c)) : List<&2, Crdt.Op>}:
  match xs:
    case Nil{}:
      {==}
    case Con{+x, +xt}:
      match ys:
        case Nil{}:
          {==}
        case Con{+y, +yt}:
          match c:
            case LT{}:
              merge_acc_eq(xt, Con{y, yt}, Crdt.cmp(Crdt.hd(xt), y), Con{x, acc})
            case GT{}:
              merge_acc_eq(Con{x, xt}, yt, Crdt.cmp(x, Crdt.hd(yt)), Con{y, acc})
            case EQ{}:
              merge_acc_eq(xt, yt, Crdt.cmp(Crdt.hd(xt), Crdt.hd(yt)), Con{x, acc})

def union_fast(+xs: List<&2, Crdt.Op>, +ys: List<&2, Crdt.Op>) -> {Crdt.union(xs, ys) == Crdt.union_spec(xs, ys) : List<&2, Crdt.Op>}:
  merge_acc_eq(xs, ys, Crdt.cmp(Crdt.hd(xs), Crdt.hd(ys)), Nil{})
