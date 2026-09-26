import Base
import ../src/bytes.bend as B

def show_m(m: Maybe<&2, String>) -> String:
  match m:
    case None{}:
      "none"
    case Some{s}:
      s

def msg(ok: Bool, name: String, got: String, want: String) -> String:
  match ok:
    case True{}:
      "PASS " ++ name
    case False{}:
      "FAIL " ++ (name ++ ("  got " ++ (got ++ ("  want " ++ want))))

def check(name: String, +got: String, +want: String) -> IO(Unit):
  IO.print(msg(String.eq(got, want), name, got, want))

def main() -> IO(Unit):
  do IO<Unit>:
    check("b64 f", B.b64("f"), "Zg")
    check("b64 fo", B.b64("fo"), "Zm8")
    check("b64 foo", B.b64("foo"), "Zm9v")
    check("b64 foobar", B.b64("foobar"), "Zm9vYmFy")
    check("b64 high bytes url alphabet", B.b64(B.bytes_of([251, 255, 191])), "-_-_")
    check("unb64 Zm9vYmFy", show_m(B.unb64("Zm9vYmFy")), "foobar")
    check("unb64 Zm8", show_m(B.unb64("Zm8")), "fo")
    check("unb64 Zg", show_m(B.unb64("Zg")), "f")
    check("unb64 non-canonical Zh", show_m(B.unb64("Zh")), "none")
    check("unb64 non-canonical Zm9", show_m(B.unb64("Zm9")), "none")
    check("unb64 one char", show_m(B.unb64("Z")), "none")
    check("unb64 padding rejected", show_m(B.unb64("Zg==")), "none")
    check("unb64 std alphabet rejected", show_m(B.unb64("+/+/")), "none")
    check("unb64 url alphabet", B.hex(Maybe.default(&2, String, B.unb64("-_-_"), "")), "fbffbf")
    check("hex", B.hex("\u{0}\u{1}ab"), "00016162")
    check("unhex", show_m(B.unhex("6162")), "ab")
    check("unhex odd", show_m(B.unhex("616")), "none")
    check("unhex upper rejected", show_m(B.unhex("6A")), "none")
    check("be16", U32.show(B.be16(B.bytes_of([1, 2]))), "258")
    check("be32", U32.show(B.be32(B.bytes_of([1, 2, 3, 4]))), "16909060")
