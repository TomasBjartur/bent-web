# SPEC: the only HTML a post body can contain.
#
# Human-owned. Code may import this file but must never redefine or weaken
# it. Every change here is a security decision and must be called out in the
# commit message.
#
# A post body is stored only as `html(n, "")` for some Node n (src/markdown
# builds the Node; LAWS.bend: markup_stored). So a post can only ever
# contain what this file can produce: text escaped by spec/html.bend's esc
# (proved safe: html_esc_safe), the fixed tags below with no attributes, and links whose
# URL passed url_ok, with a fixed rel, and images stored on this site (a
# fixed /img/<32 hex> path, see img_src_ok). No scripts, styles, event
# handlers, iframes or images from elsewhere can be expressed.
import Base
import ./http.bend as Http
import ./html.bend as Html

type Tag is Data:
  P{}
  Em{}
  Strong{}
  Code{}
  Pre{}
  H2{}
  H3{}
  Ul{}
  Ol{}
  Li{}
  Quote{}

# A link target: https://, http:// or a path on this site ("/..." but not
# "//..."), at most 2000 characters of RFC 3986 unreserved and reserved
# characters, excluding quotes, backslash, '<', '>' and whitespace.
def url_char(+c: Char) -> Bool:
  +x = Char.to_u32(c)
  Bool.and(Http.in_range(x, 33, 126), Bool.not(Bool.or(U32.is_eq(x, 34), Bool.or(U32.is_eq(x, 39), Bool.or(U32.is_eq(x, 60), Bool.or(U32.is_eq(x, 62), Bool.or(U32.is_eq(x, 92), Bool.or(U32.is_eq(x, 96), Bool.or(U32.is_eq(x, 123), Bool.or(U32.is_eq(x, 125), U32.is_eq(x, 124)))))))))))

def all_url_chars(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{+h, t}:
      Bool.and(url_char(h), all_url_chars(t))

def url_ok(+s: String) -> Bool:
  Bool.and(Nat.is_le(String.length(s), 2000n), Bool.and(all_url_chars(s), Bool.or(String.starts_with(s, "https://"), Bool.or(String.starts_with(s, "http://"), Bool.and(String.starts_with(s, "/"), Bool.not(String.starts_with(s, "//")))))))

# An image source: exactly "/img/" and 32 lowercase hex digits, the key of
# an image uploaded here (served with its checked type, nosniff and a
# sandboxing CSP). No other site's images: they could track readers.
def hex_char(+c: Char) -> Bool:
  +x = Char.to_u32(c)
  Bool.or(Http.in_range(x, 48, 57), Http.in_range(x, 97, 102))

def all_hex(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{+h, t}:
      Bool.and(hex_char(h), all_hex(t))

def img_src_ok(+s: String) -> Bool:
  Bool.and(Nat.is_eq(String.length(s), 37n), Bool.and(String.starts_with(s, "/img/"), all_hex(String.drop(s, 5n))))

type Node is Data:
  Empty{}
  Text{s: String}
  Br{}
  El{tag: Tag, kids: Node}
  Link{href: String, ok: {url_ok(href) == True{} : Bool}, kids: Node}
  Img{src: String, ok: {img_src_ok(src) == True{} : Bool}, alt: String}
  Seq{a: Node, b: Node}

def name(t: Tag) -> String:
  match t:
    case P{}:
      "p"
    case Em{}:
      "em"
    case Strong{}:
      "strong"
    case Code{}:
      "code"
    case Pre{}:
      "pre"
    case H2{}:
      "h2"
    case H3{}:
      "h3"
    case Ul{}:
      "ul"
    case Ol{}:
      "ol"
    case Li{}:
      "li"
    case Quote{}:
      "blockquote"

# The serialization of n, in front of rest.
def html(n: Node, rest: String) -> String:
  match n:
    case Empty{}:
      rest
    case Text{s}:
      Html.esc(s, rest)
    case Br{}:
      "<br>" ++ rest
    case El{+t, kids}:
      "<" ++ (name(t) ++ (">" ++ html(kids, "</" ++ (name(t) ++ (">" ++ rest)))))
    case Link{+href, ok, kids}:
      "<a href=\"" ++ Html.esc(href, "\" rel=\"nofollow noopener ugc\">" ++ html(kids, "</a>" ++ rest))
    case Img{+src, ok, alt}:
      "<img src=\"" ++ Html.esc(src, "\" alt=\"" ++ Html.esc(alt, "\" loading=\"lazy\">" ++ rest))
    case Seq{a, b}:
      html(a, html(b, rest))
