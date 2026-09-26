import Base
import ../src/json.bend as J

def show_m(m: Maybe<&2, String>) -> String:
  match m:
    case None{}:
      "none"
    case Some{s}:
      s
def show_b(m: Maybe<&2, Bool>) -> String:
  match m:
    case None{}:
      "none"
    case Some{b}:
      match b:
        case True{}:
          "true"
        case False{}:
          "false"
def msg(ok: Bool, name: String, got: String, want: String) -> String:
  match ok:
    case True{}:
      "PASS " ++ name
    case False{}:
      "FAIL " ++ (name ++ ("  got " ++ (got ++ ("  want " ++ want))))
def check(name: String, +got: String, +want: String) -> IO(Unit):
  IO.print(msg(String.eq(got, want), name, got, want))
def str_in.go(m: Maybe<&2, List<&2, J.JField>>, +key: String) -> Maybe<&2, String>:
  match m:
    case None{}:
      None{}
    case Some{+xs}:
      J.str(xs, key)
def str_in(+src: String, +key: String) -> String:
  show_m(str_in.go(J.parse(src), key))
def bool_in.go(m: Maybe<&2, List<&2, J.JField>>, +key: String) -> Maybe<&2, Bool>:
  match m:
    case None{}:
      None{}
    case Some{+xs}:
      J.boolean(xs, key)
def bool_in(+src: String, +key: String) -> String:
  show_b(bool_in.go(J.parse(src), key))
def parses.go(m: Maybe<&2, List<&2, J.JField>>) -> String:
  match m:
    case None{}:
      "no"
    case Some{x}:
      "yes"
def parses(+src: String) -> String:
  parses.go(J.parse(src))
def cd() -> String:
  "{\"type\":\"webauthn.get\",\"challenge\":\"q2Hx-_Ab\",\"origin\":\"http://localhost:8080\",\"crossOrigin\":false,\"other_keys_can_be_added_here\":\"do not compare clientDataJSON against a template. See https:\\/\\/goo.gl\\/yabPex\"}"
def main() -> IO(Unit):
  do IO<Unit>:
    check("chrome clientData type", str_in(cd(), "type"), "webauthn.get")
    check("chrome clientData challenge", str_in(cd(), "challenge"), "q2Hx-_Ab")
    check("chrome clientData origin", str_in(cd(), "origin"), "http://localhost:8080")
    check("chrome clientData crossOrigin", bool_in(cd(), "crossOrigin"), "false")
    check("escaped slash in other key", str_in(cd(), "other_keys_can_be_added_here"), "do not compare clientDataJSON against a template. See https://goo.gl/yabPex")
    check("whitespace everywhere", str_in(" { \"a\" : \"b\" , \"c\" : true } ", "a"), "b")
    check("empty object", parses("{}"), "yes")
    check("escapes", str_in("{\"a\":\"x\\\"y\\\\z\\n\\u0041\"}", "a"), "x\"y\\z\nA")
    check("duplicate key reads as absent", str_in("{\"type\":\"webauthn.get\",\"type\":\"webauthn.create\"}", "type"), "none")
    check("string where bool expected", bool_in("{\"c\":\"false\"}", "c"), "none")
    check("number rejected", parses("{\"a\":1}"), "no")
    check("null rejected", parses("{\"a\":null}"), "no")
    check("nested rejected", parses("{\"a\":{\"b\":\"c\"}}"), "no")
    check("array rejected", parses("{\"a\":[\"b\"]}"), "no")
    check("trailing garbage rejected", parses("{\"a\":\"b\"}x"), "no")
    check("trailing comma rejected", parses("{\"a\":\"b\",}"), "no")
    check("missing colon rejected", parses("{\"a\" \"b\"}"), "no")
    check("unterminated string", parses("{\"a\":\"b}"), "no")
    check("raw newline in string", parses("{\"a\":\"b\nc\"}"), "no")
    check("bad escape", parses("{\"a\":\"\\x\"}"), "no")
    check("surrogate escape rejected", parses("{\"a\":\"\\ud800\"}"), "no")
    check("short unicode escape", parses("{\"a\":\"\\u12\"}"), "no")
    check("truex rejected", parses("{\"a\":truex}"), "no")
    check("tru rejected", parses("{\"a\":tru}"), "no")
    check("two objects rejected", parses("{}{}"), "no")
    check("empty input", parses(""), "no")
    check("json quote", J.q("a\"b\\c\n<"), "a\\\"b\\\\c\\u000a\\u003c")
