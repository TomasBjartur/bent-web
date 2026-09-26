# User text: UTF-8 decoding, form (application/x-www-form-urlencoded)
# parsing, and refined text values.
#
# Title, Body and Slug are refinement types: they can only be built after
# spec/text.bend's predicate returned True, and they carry that proof. The
# decoder below can have bugs that reject or garble input, but no bug can
# produce a Title with a control character or an invalid scalar, because
# the refinement check runs on its output.
import Base
import ../spec/text.bend as Spec
import ../spec/http.bend as Http

# REFINED VALUES
# --------------

type Title is Data:
  Title{text: String, pf: {Spec.title_ok(text) == True{} : Bool}}

type Body is Data:
  Body{text: String, pf: {Spec.body_ok(text) == True{} : Bool}}

type Slug is Data:
  Slug{text: String, pf: {Spec.slug_ok(text) == True{} : Bool}}

type Email is Data:
  Email{text: String, pf: {Spec.email_ok(text) == True{} : Bool}}

type Name is Data:
  Name{text: String, pf: {Spec.name_ok(text) == True{} : Bool}}

# FORMS
# -----
# A form field: its name, and its value as raw bytes (percent-decoded, not
# yet UTF-8 decoded).
type Field is Data:
  Field{name: String, value: String}

def mk_title.go(b: Bool, +s: String, e: {Spec.title_ok(s) == b : Bool}) -> Maybe<&2, Title>:
  match b:
    case True{}:
      Some{Title{s, e}}
    case False{}:
      None{}

def mk_title(+s: String) -> Maybe<&2, Title>:
  mk_title.go(Spec.title_ok(s), s, {==})

def mk_body.go(b: Bool, +s: String, e: {Spec.body_ok(s) == b : Bool}) -> Maybe<&2, Body>:
  match b:
    case True{}:
      Some{Body{s, e}}
    case False{}:
      None{}

def mk_body(+s: String) -> Maybe<&2, Body>:
  mk_body.go(Spec.body_ok(s), s, {==})

def mk_slug.go(b: Bool, +s: String, e: {Spec.slug_ok(s) == b : Bool}) -> Maybe<&2, Slug>:
  match b:
    case True{}:
      Some{Slug{s, e}}
    case False{}:
      None{}

def mk_slug(+s: String) -> Maybe<&2, Slug>:
  mk_slug.go(Spec.slug_ok(s), s, {==})

def Title.text(t: Title) -> String:
  match t:
    case Title{s, p}:
      s

def Body.text(t: Body) -> String:
  match t:
    case Body{s, p}:
      s

def Slug.text(t: Slug) -> String:
  match t:
    case Slug{s, p}:
      s

# UTF-8
# -----
def byte(+c: Char) -> U32:
  (Char.to_u32(c) .&. 255 : U32)

# A continuation byte: 10xxxxxx.
def cont(+c: Char) -> Bool:
  U32.is_eq((Char.to_u32(c) .&. 192 : U32), 128)

def cbits(+c: Char) -> U32:
  (Char.to_u32(c) .&. 63 : U32)

def lead_pick(a: Bool, b: Bool, c: Bool, d: Bool, e: Bool) -> Nat:
  match a b c d e:
    case True{} _ _ _ _:
      0n
    case False{} True{} _ _ _:
      4n
    case False{} False{} True{} _ _:
      1n
    case False{} False{} False{} True{} _:
      2n
    case False{} False{} False{} False{} True{}:
      3n
    case _ _ _ _ _:
      4n

# Lead byte class: 0 ASCII, 1 starts 2 bytes (C2..DF), 2 starts 3 bytes
# (E0..EF), 3 starts 4 bytes (F0..F4), 4 invalid (80..C1, F5..FF, and any
# non-byte).
def lead_class(+c: Char) -> Nat:
  +x = Char.to_u32(c)
  lead_pick(U32.is_lt(x, 128), U32.is_lt(x, 194), U32.is_lt(x, 224), U32.is_lt(x, 240), U32.is_lt(x, 245))

def cons_if(ok: Bool, +cp: U32, r: Maybe<&2, String>) -> Maybe<&2, String>:
  match ok r:
    case True{} Some{s}:
      Some{SCon{Chr{cp}, s}}
    case _ _:
      None{}

def cp2(+b: Char, +c1: Char) -> U32:
  (((byte(b) .&. 31) << 6n) .|. cbits(c1) : U32)

def ok2(+b: Char, +c1: Char) -> Bool:
  Bool.and(cont(c1), U32.is_ge(cp2(b, c1), 128))

def cp3(+b: Char, +c1: Char, +c2: Char) -> U32:
  (((byte(b) .&. 15) << 12n) .|. ((cbits(c1) << 6n) .|. cbits(c2)) : U32)

def ok3(+b: Char, +c1: Char, +c2: Char) -> Bool:
  +cp = cp3(b, c1, c2)
  Bool.and(Bool.and(cont(c1), cont(c2)), Bool.and(U32.is_ge(cp, 2048), Bool.or(U32.is_lt(cp, 55296), U32.is_gt(cp, 57343))))

def cp4(+b: Char, +c1: Char, +c2: Char, +c3: Char) -> U32:
  (((byte(b) .&. 7) << 18n) .|. ((cbits(c1) << 12n) .|. ((cbits(c2) << 6n) .|. cbits(c3))) : U32)

def ok4(+b: Char, +c1: Char, +c2: Char, +c3: Char) -> Bool:
  +cp = cp4(b, c1, c2, c3)
  Bool.and(Bool.and(cont(c1), Bool.and(cont(c2), cont(c3))), Bool.and(U32.is_ge(cp, 65536), U32.is_le(cp, 1114111)))

# Decodes bytes. n is fuel (at least the number of bytes left); k is the
# lead class of b, the current byte; t follows it.
def dec(n: Nat, k: Nat, +b: Char, t: String) -> Maybe<&2, String>:
  match n:
    case 0n:
      None{}
    case 1n+p:
      match k:
        case 0n:
          match t:
            case SNil{}:
              Some{SCon{Chr{byte(b)}, ""}}
            case SCon{+d, t2}:
              cons_if(True{}, byte(b), dec(p, lead_class(d), d, t2))
        case 1n:
          match t:
            case SNil{}:
              None{}
            case SCon{+c1, t2}:
              match t2:
                case SNil{}:
                  cons_if(ok2(b, c1), cp2(b, c1), Some{""})
                case SCon{+d, t3}:
                  cons_if(ok2(b, c1), cp2(b, c1), dec(p, lead_class(d), d, t3))
        case 2n:
          match t:
            case SNil{}:
              None{}
            case SCon{+c1, t2}:
              match t2:
                case SNil{}:
                  None{}
                case SCon{+c2, t3}:
                  match t3:
                    case SNil{}:
                      cons_if(ok3(b, c1, c2), cp3(b, c1, c2), Some{""})
                    case SCon{+d, t4}:
                      cons_if(ok3(b, c1, c2), cp3(b, c1, c2), dec(p, lead_class(d), d, t4))
        case 3n:
          match t:
            case SNil{}:
              None{}
            case SCon{+c1, t2}:
              match t2:
                case SNil{}:
                  None{}
                case SCon{+c2, t3}:
                  match t3:
                    case SNil{}:
                      None{}
                    case SCon{+c3, t4}:
                      match t4:
                        case SNil{}:
                          cons_if(ok4(b, c1, c2, c3), cp4(b, c1, c2, c3), Some{""})
                        case SCon{+d, t5}:
                          cons_if(ok4(b, c1, c2, c3), cp4(b, c1, c2, c3), dec(p, lead_class(d), d, t5))
        case _:
          None{}

# Bytes (one Char per byte) to code points, or None if not valid UTF-8.
def utf8_decode(s: String) -> Maybe<&2, String>:
  match s:
    case SNil{}:
      Some{""}
    case SCon{+b, +t}:
      dec(Nat.add(String.length(t), 1n), lead_class(b), b, t)

def hex_pick(a: Bool, b: Bool, c: Bool, d: Bool, e: Bool, f: Bool, +x: U32) -> Maybe<&2, U32>:
  match a b c d e f:
    case True{} _ _ _ _ _:
      None{}
    case False{} True{} _ _ _ _:
      Some{(x - 48 : U32)}
    case False{} False{} True{} _ _ _:
      None{}
    case False{} False{} False{} True{} _ _:
      Some{(x - 55 : U32)}
    case False{} False{} False{} False{} True{} _:
      None{}
    case False{} False{} False{} False{} False{} True{}:
      Some{(x - 87 : U32)}
    case _ _ _ _ _ _:
      None{}

# PERCENT DECODING
# ----------------
def hex_val(+c: Char) -> Maybe<&2, U32>:
  +x = Char.to_u32(c)
  hex_pick(U32.is_lt(x, 48), U32.is_le(x, 57), U32.is_lt(x, 65), U32.is_le(x, 70), U32.is_lt(x, 97), U32.is_le(x, 102), x)

def byte_of(h: Maybe<&2, U32>, l: Maybe<&2, U32>) -> Maybe<&2, U32>:
  match h l:
    case Some{+a} Some{+b}:
      Some{((a << 4n) .|. b : U32)}
    case _ _:
      None{}

def cons_byte(m: Maybe<&2, U32>, r: Maybe<&2, String>) -> Maybe<&2, String>:
  match m r:
    case Some{+x} Some{s}:
      Some{SCon{Chr{x}, s}}
    case _ _:
      None{}

# 0 ordinary, 1 '+', 2 '%'.
def pct_class(+c: Char) -> Nat:
  U32.to_nat((Bool.to_u32(Char.is_eq(c, '+')) + (2 * Bool.to_u32(Char.is_eq(c, '%'))) : U32))

# Percent-decodes s ("+" is a space); None on a malformed escape.
def pct(n: Nat, k: Nat, +c: Char, t: String) -> Maybe<&2, String>:
  match n:
    case 0n:
      None{}
    case 1n+p:
      match k:
        case 0n:
          match t:
            case SNil{}:
              Some{SCon{c, ""}}
            case SCon{+d, t2}:
              cons_byte(Some{Char.to_u32(c)}, pct(p, pct_class(d), d, t2))
        case 1n:
          match t:
            case SNil{}:
              Some{" "}
            case SCon{+d, t2}:
              cons_byte(Some{32}, pct(p, pct_class(d), d, t2))
        case _:
          match t:
            case SNil{}:
              None{}
            case SCon{+h1, t2}:
              match t2:
                case SNil{}:
                  None{}
                case SCon{+h2, t3}:
                  match t3:
                    case SNil{}:
                      cons_byte(byte_of(hex_val(h1), hex_val(h2)), Some{""})
                    case SCon{+d, t4}:
                      cons_byte(byte_of(hex_val(h1), hex_val(h2)), pct(p, pct_class(d), d, t4))

def pct_decode(s: String) -> Maybe<&2, String>:
  match s:
    case SNil{}:
      Some{""}
    case SCon{+c, +t}:
      pct(Nat.add(String.length(t), 1n), pct_class(c), c, t)

def field_of(n: Maybe<&2, String>, v: Maybe<&2, String>) -> Maybe<&2, Field>:
  match n v:
    case Some{a} Some{b}:
      Some{Field{a, b}}
    case _ _:
      None{}

def field_split(xs: List<&2, String>) -> Maybe<&2, Field>:
  match xs:
    case Con{+n, t}:
      match t:
        case Nil{}:
          field_of(pct_decode(n), Some{""})
        case Con{+v, u}:
          match u:
            case Nil{}:
              field_of(pct_decode(n), pct_decode(v))
            case Con{w, z}:
              None{}
    case Nil{}:
      None{}

def field_parse(+pair: String) -> Maybe<&2, Field>:
  field_split(String.split(pair, '='))

def fields_cons(a: Maybe<&2, Field>, b: Maybe<&2, List<&2, Field>>) -> Maybe<&2, List<&2, Field>>:
  match a b:
    case Some{x} Some{xs}:
      Some{x <> xs}
    case _ _:
      None{}

def fields_go(xs: List<&2, String>) -> Maybe<&2, List<&2, Field>>:
  match xs:
    case Nil{}:
      Some{Nil{}}
    case Con{+x, t}:
      fields_cons(field_parse(x), fields_go(t))

def form_limit.go(b: Bool, m: Maybe<&2, List<&2, Field>>) -> Maybe<&2, List<&2, Field>>:
  match b:
    case True{}:
      m
    case False{}:
      None{}

def form_limit(+n: Nat, m: Maybe<&2, List<&2, Field>>) -> Maybe<&2, List<&2, Field>>:
  form_limit.go(Nat.is_le(n, 64n), m)

def form_parse.split(+parts: List<&2, String>) -> Maybe<&2, List<&2, Field>>:
  form_limit(List.length(&2, String, parts), fields_go(parts))

def form_parse.go(e: Bool, +body: String) -> Maybe<&2, List<&2, Field>>:
  match e:
    case True{}:
      Some{Nil{}}
    case False{}:
      form_parse.split(String.split(body, '&'))

# Parses an urlencoded body into at most 64 fields, or None.
def form_parse(+body: String) -> Maybe<&2, List<&2, Field>>:
  form_parse.go(String.is_empty(body), body)

# The value of the field named key, only if it occurs exactly once (so a
# repeated field can never be read two different ways).
def count_key(xs: List<&2, Field>, +key: String) -> Nat:
  match xs:
    case Nil{}:
      0n
    case Con{f, t}:
      match f:
        case Field{n, v}:
          Nat.add(U32.to_nat(Bool.to_u32(String.eq(n, key))), count_key(t, key))

def first_pick(b: Bool, +v: String, r: Maybe<&2, String>) -> Maybe<&2, String>:
  match b:
    case True{}:
      Some{v}
    case False{}:
      r

def first_key(xs: List<&2, Field>, +key: String) -> Maybe<&2, String>:
  match xs:
    case Nil{}:
      None{}
    case Con{f, t}:
      match f:
        case Field{+n, +v}:
          first_pick(String.eq(n, key), v, first_key(t, key))

def form_get.go(once: Bool, +xs: List<&2, Field>, +key: String) -> Maybe<&2, String>:
  match once:
    case True{}:
      first_key(xs, key)
    case False{}:
      None{}

def form_get(+xs: List<&2, Field>, +key: String) -> Maybe<&2, String>:
  form_get.go(Nat.is_eq(count_key(xs, key), 1n), xs, key)

def decode_of(m: Maybe<&2, String>) -> Maybe<&2, String>:
  match m:
    case None{}:
      None{}
    case Some{s}:
      utf8_decode(s)

def title_of(m: Maybe<&2, String>) -> Maybe<&2, Title>:
  match m:
    case None{}:
      None{}
    case Some{+s}:
      mk_title(s)

def body_of(m: Maybe<&2, String>) -> Maybe<&2, Body>:
  match m:
    case None{}:
      None{}
    case Some{+s}:
      mk_body(s)

def slug_of(m: Maybe<&2, String>) -> Maybe<&2, Slug>:
  match m:
    case None{}:
      None{}
    case Some{+s}:
      mk_slug(s)

# A form field decoded and refined, or None if absent, repeated, not UTF-8,
# or not within spec.
def form_title(+xs: List<&2, Field>, +key: String) -> Maybe<&2, Title>:
  title_of(decode_of(form_get(xs, key)))

def strip_cr.go(b: Bool, +line: String) -> String:
  match b:
    case True{}:
      String.take(line, Nat.sub(String.length(line), 1n))
    case False{}:
      line

# Browsers submit textarea line breaks as CRLF (HTML spec); stored bodies
# use LF. A CR not followed by LF stays, and is then rejected by the spec.
def strip_cr(+line: String) -> String:
  strip_cr.go(String.ends_with(line, "\r"), line)

def strip_crs(xs: List<&2, String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{+x, t}:
      strip_cr(x) <> strip_crs(t)

def crlf_to_lf(+s: String) -> String:
  String.join(strip_crs(String.split(s, '\n')), "\n")

def lf_of(m: Maybe<&2, String>) -> Maybe<&2, String>:
  match m:
    case None{}:
      None{}
    case Some{+s}:
      Some{crlf_to_lf(s)}

def form_body(+xs: List<&2, Field>, +key: String) -> Maybe<&2, Body>:
  body_of(lf_of(decode_of(form_get(xs, key))))

def form_slug(+xs: List<&2, Field>, +key: String) -> Maybe<&2, Slug>:
  slug_of(form_get(xs, key))

def mk_email.go(b: Bool, +s: String, e: {Spec.email_ok(s) == b : Bool}) -> Maybe<&2, Email>:
  match b:
    case True{}:
      Some{Email{s, e}}
    case False{}:
      None{}

def mk_email(+s: String) -> Maybe<&2, Email>:
  mk_email.go(Spec.email_ok(s), s, {==})

def mk_name.go(b: Bool, +s: String, e: {Spec.name_ok(s) == b : Bool}) -> Maybe<&2, Name>:
  match b:
    case True{}:
      Some{Name{s, e}}
    case False{}:
      None{}

def mk_name(+s: String) -> Maybe<&2, Name>:
  mk_name.go(Spec.name_ok(s), s, {==})

def Email.text(t: Email) -> String:
  match t:
    case Email{s, p}:
      s

def Name.text(t: Name) -> String:
  match t:
    case Name{s, p}:
      s

def email_of(m: Maybe<&2, String>) -> Maybe<&2, Email>:
  match m:
    case None{}:
      None{}
    case Some{+s}:
      mk_email(String.to_lower(s))

def name_of(m: Maybe<&2, String>) -> Maybe<&2, Name>:
  match m:
    case None{}:
      None{}
    case Some{+s}:
      mk_name(s)

# Email addresses are lower-cased (the database compares them without case
# anyway, and this gives each address one spelling).
def form_email(+xs: List<&2, Field>, +key: String) -> Maybe<&2, Email>:
  email_of(decode_of(form_get(xs, key)))

def form_name(+xs: List<&2, Field>, +key: String) -> Maybe<&2, Name>:
  name_of(decode_of(form_get(xs, key)))

# A raw form value (bytes), only if present exactly once.
def form_raw(+xs: List<&2, Field>, +key: String) -> Maybe<&2, String>:
  form_get(xs, key)

# SLUGS FROM TITLES
# -----------------
# An address made from a title, for forms that leave it empty: ASCII
# letters (lowered) and digits kept, every run of anything else one dash,
# at most 64 characters, no dash at either end; "post" if nothing is left.
# The result still goes through mk_slug, so this needs no proof.
def slug_map(+c: Char) -> U32:
  +x = Char.to_u32(c)
  ((Bool.to_u32(Bool.or(Http.in_range(x, 97, 122), Http.in_range(x, 48, 57))) * x) + (Bool.to_u32(Http.in_range(x, 65, 90)) * (x + 32)) : U32)

def slugify.dash(acc: String) -> String:
  match acc:
    case SNil{}:
      SNil{}
    case SCon{h, t}:
      SCon{Char.from_u32(45), SCon{h, t}}

def slugify.push(dash: Bool, +x: U32, acc: String) -> String:
  match dash:
    case True{}:
      SCon{Char.from_u32(x), slugify.dash(acc)}
    case False{}:
      SCon{Char.from_u32(x), acc}

def slugify.add(sep: Bool, +x: U32, dash: Bool, acc: String) -> String:
  match sep:
    case True{}:
      acc
    case False{}:
      slugify.push(dash, x, acc)

# acc holds the slug so far, reversed; dash: a separator is pending.
def slugify.go(s: String, dash: Bool, acc: String) -> String:
  match s:
    case SNil{}:
      acc
    case SCon{+h, t}:
      slugify.go(t, U32.is_eq(slug_map(h), 0), slugify.add(U32.is_eq(slug_map(h), 0), slug_map(h), dash, acc))

# Runs of separators are one dash and there is none in front, so only a
# cut at 64 can leave one at the end (reversed: in front).
def drop_dash(+r: String) -> String:
  String.drop(r, U32.to_nat(Bool.to_u32(String.starts_with(r, "-"))))

def or_else.go(b: Bool, +s: String, d: String) -> String:
  match b:
    case True{}:
      d
    case False{}:
      s

def or_else(+s: String, d: String) -> String:
  or_else.go(String.is_empty(s), s, d)

def slugify(s: String) -> String:
  or_else(String.reverse(drop_dash(String.reverse(String.take(String.reverse(slugify.go(s, False{}, SNil{})), 64n)))), "post")

def form_slug_or.go(empty: Bool, +raw: String, +title: String) -> Maybe<&2, Slug>:
  match empty:
    case True{}:
      mk_slug(slugify(title))
    case False{}:
      mk_slug(raw)

# The form's address field, or one made from its title field if empty.
def form_slug_or(+xs: List<&2, Field>, +key: String, +title_key: String) -> Maybe<&2, Slug>:
  +raw = Maybe.default(&2, String, form_get(xs, key), "")
  form_slug_or.go(String.is_empty(raw), raw, Maybe.default(&2, String, decode_of(form_get(xs, title_key)), ""))

# SEARCH QUERIES
# --------------
# A search box's text as an FTS5 expression that can only mean "all these
# words": each word is quoted ("..." with " doubled, so nothing inside is
# syntax), at most 8 words of at most ~126 characters, the last one a prefix
# ("word"*). Separators: space, tab, newline. "" if there are no words.
def fts.is_sep(+c: Char) -> Bool:
  +x = Char.to_u32(c)
  Bool.or(U32.is_eq(x, 32), Bool.or(U32.is_eq(x, 9), Bool.or(U32.is_eq(x, 10), U32.is_eq(x, 13))))

# A word is kept reversed; a quote goes in twice.
def fts.push(q: Bool, +h: Char, w: String) -> String:
  match q:
    case True{}:
      SCon{h, SCon{h, w}}
    case False{}:
      SCon{h, w}

# A full word (126 characters, a doubled quote counting 2) takes no more:
# the cap applies before quoting, so a doubled quote is never split.
def fts.full(full: Bool, +h: Char, w: String) -> String:
  match full:
    case True{}:
      w
    case False{}:
      fts.push(U32.is_eq(Char.to_u32(h), 34), h, w)

def fts.word(sep: Bool, +h: Char, +w: String) -> String:
  match sep:
    case True{}:
      SNil{}
    case False{}:
      fts.full(Nat.is_le(126n, String.length(w)), h, w)

def fts.term(+w: String) -> String:
  "\"" ++ (String.reverse(w) ++ "\"")

def fts.join(+out: String, +t: String) -> String:
  or_else.go(String.is_empty(out), out ++ (" " ++ t), t)

def fts.add(ok: Bool, +w: String, +out: String) -> String:
  match ok:
    case True{}:
      fts.join(out, fts.term(w))
    case False{}:
      out

def fts.count(ok: Bool, +n: U32) -> U32:
  match ok:
    case True{}:
      (n + 1 : U32)
    case False{}:
      n

def fts.room(+w: String, +n: U32) -> Bool:
  Bool.and(Bool.not(String.is_empty(w)), U32.is_lt(n, 8))

def fts.last(ok: Bool, +w: String, +out: String) -> String:
  match ok:
    case True{}:
      fts.join(out, fts.term(w) ++ "*")
    case False{}:
      out

# At a separator the word so far is added (if any, and if there is room).
def fts.go(s: String, +w: String, +out: String, +n: U32) -> String:
  match s:
    case SNil{}:
      fts.last(fts.room(w, n), w, out)
    case SCon{+h, t}:
      fts.go(t, fts.word(fts.is_sep(h), h, w), fts.add(Bool.and(fts.is_sep(h), fts.room(w, n)), w, out), fts.count(Bool.and(fts.is_sep(h), fts.room(w, n)), n))

def fts_query(s: String) -> String:
  fts.go(s, SNil{}, "", 0)
