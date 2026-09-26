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

# A Permit for action a under facts f, or None if the policy forbids it.
def authorize(+f: Spec.Facts, +a: Spec.Action) -> Maybe<&2, Permit>:
  authorize.go(Spec.permitted(f, a), f, a, {==})
