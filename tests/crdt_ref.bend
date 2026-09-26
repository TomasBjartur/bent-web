# The reference CRDT as a program: reads a file of operations (wire format)
# and prints the document text as src/crdt.bend defines it, between
# markers. Used by tests/fugue_diff.mjs (differential fuzzing of the
# browser implementation). usage: crdt_ref <file>
import Base
import ../src/crdt.bend as C

def show(m: Maybe<&2, List<&2, C.Op>>) -> String:
  match m:
    case None{}:
      "<<INVALID>>"
    case Some{+xs}:
      "<<TEXT>>" ++ (C.text(xs) ++ "<<END>>")

def got(r: File & Result<&1, &1, U32 & String, String>) -> IO(Unit):
  (f, res) = r
  match res:
    case Fail{e}:
      IO.print("<<READ ERROR>>")
    case Done{+s}:
      IO.print(show(C.decode(s)))

def path_of(xs: List<String>) -> String:
  match xs:
    case Nil{}:
      ""
    case Con{x, t}:
      x

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    f : File <- IO.try(File, File.open(path_of(args), "r"))
    r : File & Result<&1, &1, U32 & String, String> <- File.read(f, 67108864)
    got(r)
