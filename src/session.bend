# The session cookie. Pure.
import Base
import ./http.bend as Http

def cookie_of(h: Http.Hdrs) -> String:
  match h:
    case Http.Hdrs{host, cookie, clen, ctype, origin, site, ds}:
      match cookie:
        case None{}:
          ""
        case Some{v}:
          Http.Hval.text(v)

def trim(s: String) -> String:
  String.trim(s)

def sids.pick(b: Bool, +x: String, r: List<&2, String>) -> List<&2, String>:
  match b:
    case True{}:
      String.drop(x, 4n) <> r
    case False{}:
      r

# The values of every "sid=" pair.
def sids(xs: List<&2, String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{+x, t}:
      sids.pick(String.starts_with(String.trim(x), "sid="), String.trim(x), sids(t))

def one_sid(xs: List<&2, String>) -> String:
  match xs:
    case Con{x, t}:
      match t:
        case Nil{}:
          x
        case Con{y, u}:
          ""
    case Nil{}:
      ""

# The session token from the Cookie header: the sid value if exactly one sid
# pair is present, else "". (C validates its format; anything else matches
# no session.)
def token(h: Http.Hdrs) -> String:
  one_sid(sids(String.split(cookie_of(h), ';')))
