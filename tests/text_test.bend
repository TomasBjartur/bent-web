# Tests for src/text.bend. Each case prints PASS or FAIL.
import Base
import ../src/text.bend as T

def bytes(xs: List<&2, U32>) -> String:
  match xs:
    case Nil{}:
      ""
    case Con{x, t}:
      SCon{Chr{x}, bytes(t)}

def codes(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{c, t}:
      U32.show(Char.to_u32(c)) ++ ("," ++ codes(t))

def show_m(m: Maybe<&2, String>) -> String:
  match m:
    case None{}:
      "none"
    case Some{s}:
      codes(s)

def msg(ok: Bool, name: String, got: String, want: String) -> String:
  match ok:
    case True{}:
      "PASS " ++ name
    case False{}:
      "FAIL " ++ (name ++ ("  got " ++ (got ++ ("  want " ++ want))))

def check(name: String, +got: String, +want: String) -> IO(Unit):
  IO.print(msg(String.eq(got, want), name, got, want))

def dec(xs: List<&2, U32>) -> String:
  show_m(T.utf8_decode(bytes(xs)))

def show_title(m: Maybe<&2, T.Title>) -> String:
  match m:
    case None{}:
      "none"
    case Some{t}:
      T.Title.text(t)

def show_slug(m: Maybe<&2, T.Slug>) -> String:
  match m:
    case None{}:
      "none"
    case Some{t}:
      T.Slug.text(t)

def form_or(m: Maybe<&2, List<&2, T.Field>>, +key: String) -> Maybe<&2, T.Title>:
  match m:
    case None{}:
      None{}
    case Some{+xs}:
      T.form_title(xs, key)

def show_body(m: Maybe<&2, T.Body>) -> String:
  match m:
    case None{}:
      "none"
    case Some{b}:
      T.Body.text(b)

def body_or(m: Maybe<&2, List<&2, T.Field>>, +key: String) -> Maybe<&2, T.Body>:
  match m:
    case None{}:
      None{}
    case Some{+xs}:
      T.form_body(xs, key)

def body(b: String) -> String:
  show_body(body_or(T.form_parse(b), "body"))

def title(body: String) -> String:
  show_title(form_or(T.form_parse(body), "title"))

def slug_or(m: Maybe<&2, List<&2, T.Field>>, +key: String) -> Maybe<&2, T.Slug>:
  match m:
    case None{}:
      None{}
    case Some{+xs}:
      T.form_slug(xs, key)

def slug(body: String) -> String:
  show_slug(slug_or(T.form_parse(body), "slug"))

def main() -> IO(Unit):
  do IO<Unit>:
    check("ascii", dec([104, 105]), "104,105,")
    check("empty", dec([]), "")
    check("2-byte e-acute", dec([195, 169]), "233,")
    check("3-byte euro", dec([226, 130, 172]), "8364,")
    check("4-byte emoji", dec([240, 159, 152, 128]), "128512,")
    check("mixed", dec([97, 195, 169, 98]), "97,233,98,")
    check("overlong 2-byte slash", dec([192, 175]), "none")
    check("overlong 3-byte", dec([224, 128, 175]), "none")
    check("overlong 4-byte", dec([240, 128, 128, 175]), "none")
    check("surrogate D800", dec([237, 160, 128]), "none")
    check("above 10FFFF", dec([244, 144, 128, 128]), "none")
    check("lead F5", dec([245, 128, 128, 128]), "none")
    check("lone continuation", dec([128]), "none")
    check("truncated 2-byte", dec([195]), "none")
    check("truncated 3-byte", dec([226, 130]), "none")
    check("bad continuation", dec([195, 40]), "none")
    check("max scalar 10FFFF", dec([244, 143, 191, 191]), "1114111,")
    check("form title plain", title("title=Hello+world"), "Hello world")
    check("form title utf8", title("title=Caf%C3%A9"), "Café")
    check("form title with <", title("title=%3Cb%3E"), "<b>")
    check("form title control", title("title=a%01b"), "none")
    check("form title C1 control", title("title=a%C2%85b"), "none")
    check("form title invalid utf8", title("title=%FF"), "none")
    check("form title bad escape", title("title=%G1"), "none")
    check("form title truncated escape", title("title=%4"), "none")
    check("form title empty", title("title="), "none")
    check("form title missing", title("other=x"), "none")
    check("form title repeated", title("title=a&title=b"), "none")
    check("form title among others", title("a=1&title=T&b=2"), "T")
    check("form two equals", title("title=a=b"), "none")
    check("body CRLF becomes LF", body("body=a%0D%0Ab%0D%0A%0D%0Ac"), "a\nb\n\nc")
    check("body lone CR rejected", body("body=a%0Db"), "none")
    check("body tab kept", body("body=a%09b"), "a\tb")
    check("slug ok", slug("slug=my-blog-2"), "my-blog-2")
    check("slug upper", slug("slug=My"), "none")
    check("slug dotdot", slug("slug=.."), "none")
    check("slug slash", slug("slug=a%2Fb"), "none")
