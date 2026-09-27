# Authorization. A Permit can only be built when spec/authz.bend's policy
# returned True for its facts and action, and it carries that proof.
#
# The only effect that writes to the database takes a Permit (src/db.c), and
# it re-checks the Permit's facts against the database inside its write
# transaction. So: Bend proves the decision follows the policy given the
# facts, and the write effect checks the facts are true when the write
# happens.
import Base
import ../spec/authz.bend as Spec

type Permit is Data:
  Permit{facts: Spec.Facts, action: Spec.Action, pf: {Spec.permitted(facts, action) == True{} : Bool}}

def authorize.go(b: Bool, +f: Spec.Facts, +a: Spec.Action, e: {Spec.permitted(f, a) == b : Bool}) -> Maybe<&2, Permit>:
  match b:
    case True{}:
      Some{Permit{f, a, e}}
    case False{}:
      None{}

# What the write effects take (src/db.bend apply, upload): a Permit, and
# the proof that its user's write budget (spent this minute, as loaded by
# the effect itself) is not used up. So no write, by any route, can skip
# the budget (LAWS.bend authz_writes_budgeted).
type WritePermit is Data:
  WritePermit{permit: Permit, spent: U32, pf: {Spec.within_budget(spent) == True{} : Bool}}

def authorize_write.go(b: Bool, +p: Permit, +spent: U32, e: {Spec.within_budget(spent) == b : Bool}) -> Maybe<&2, WritePermit>:
  match b:
    case True{}:
      Some{WritePermit{p, spent, e}}
    case False{}:
      None{}

def authorize_write(+p: Permit, +spent: U32) -> Maybe<&2, WritePermit>:
  authorize_write.go(Spec.within_budget(spent), p, spent, {==})

# A Permit for action a under facts f, or None if the policy forbids it.
def authorize(+f: Spec.Facts, +a: Spec.Action) -> Maybe<&2, Permit>:
  authorize.go(Spec.permitted(f, a), f, a, {==})
