# WebAuthn (passkeys): parsing what the browser sends, and the refinement
# types that let a registration or login proceed.
#
# RegOk and LoginOk can only be built when spec/webauthn.bend's
# register_ok / login_ok returned True, and carry that proof. The effects
# that create sessions take them (src/auth.bend), so a session is only ever
# created for a response that passed every check in the spec.
#
# Parsing is strict. We ask for attestation "none", so browsers send a
# canonical attestation object, matched here byte for byte; the credential
# public key must be the canonical 77-byte COSE ES256 (P-256) key. Anything
# else is rejected rather than interpreted.
import Base
import ../spec/webauthn.bend as Spec
import ./bytes.bend as B
import ./json.bend as J
import ./text.bend as Text

# AUTHENTICATOR DATA
# ------------------
# The fixed 37-byte part, and what follows it.
type AuthData is Data:
  AuthData{auth: Spec.Auth, rest: String}

# CREDENTIAL (registration)
# ----------
type Cred is Data:
  Cred{id: String, x: String, y: String}

# ACCEPTANCE
# ----------
type RegOk is Data:
  RegOk{e: Spec.Expect, c: Spec.Client, a: Spec.Auth, cred: Cred, pf: {Spec.register_ok(e, c, a) == True{} : Bool}}

type LoginOk is Data:
  LoginOk{e: Spec.Expect, c: Spec.Client, a: Spec.Auth, sig: Bool, stored: U32, pf: {Spec.login_ok(e, c, a, sig, stored) == True{} : Bool}}

def guard(-A: Data, ok: Bool, r: Maybe<&2, A>) -> Maybe<&2, A>:
  match ok:
    case True{}:
      r
    case False{}:
      None{}

# CLIENT DATA
# -----------
# crossOrigin: absent means false; a string (or a repeat) is invalid.
def cross_of(m: Maybe<&2, J.JVal>, +top: Nat) -> Maybe<&2, Bool>:
  match m:
    case None{}:
      Some{Bool.not(Nat.is_eq(top, 0n))}
    case Some{v}:
      match v:
        case J.JBool{b}:
          Some{Bool.or(b, Bool.not(Nat.is_eq(top, 0n)))}
        case J.JStr{s}:
          None{}

def client_make(t: Maybe<&2, String>, ch: Maybe<&2, String>, o: Maybe<&2, String>, cr: Maybe<&2, Bool>) -> Maybe<&2, Spec.Client>:
  match t ch o cr:
    case Some{a} Some{b} Some{c} Some{d}:
      Some{Spec.Client{a, b, c, d}}
    case _ _ _ _:
      None{}

def client_fields(m: Maybe<&2, List<&2, J.JField>>) -> Maybe<&2, Spec.Client>:
  match m:
    case None{}:
      None{}
    case Some{+xs}:
      client_make(J.str(xs, "type"), J.str(xs, "challenge"), J.str(xs, "origin"), cross_of(J.get(xs, "crossOrigin"), J.count(xs, "topOrigin")))

def client_text(m: Maybe<&2, String>) -> Maybe<&2, Spec.Client>:
  match m:
    case None{}:
      None{}
    case Some{+s}:
      client_fields(J.parse(s))

# clientDataJSON bytes (at most 4096) to Client.
def client_of(+bytes: String) -> Maybe<&2, Spec.Client>:
  guard(Spec.Client, Nat.is_le(String.length(bytes), 4096n), client_text(Text.utf8_decode(bytes)))

def auth_of(+bytes: String) -> Maybe<&2, AuthData>:
  guard(AuthData, Bool.and(Nat.is_le(37n, String.length(bytes)), Nat.is_le(String.length(bytes), 4096n)), Some{AuthData{Spec.Auth{B.hex(String.take(bytes, 32n)), B.byte_at(bytes, 32n), B.be32(String.drop(bytes, 33n))}, String.drop(bytes, 37n)}})

def cose_head() -> String:
  B.bytes_of([165, 1, 2, 3, 38, 32, 1, 33, 88, 32])

def cose_mid() -> String:
  B.bytes_of([34, 88, 32])

# The canonical COSE key: A5 01 02 03 26 20 01 21 58 20 <x> 22 58 20 <y>,
# i.e. {1: 2 (EC2), 3: -7 (ES256), -1: 1 (P-256), -2: x, -3: y}.
def cose_ok(+k: String) -> Bool:
  Bool.and(String.eq(String.take(k, 10n), cose_head()), String.eq(String.take(String.drop(k, 42n), 3n), cose_mid()))

def ed(+flags: U32) -> Bool:
  Spec.flag(flags, 128)

# After aaguid (16), id length (2), id, and the 77-byte key: nothing, unless
# the extension-data flag is set.
def cred_of(+flags: U32, +rest: String) -> Maybe<&2, Cred>:
  +n = U32.to_nat(B.be16(String.drop(rest, 16n)))
  +key = String.drop(rest, Nat.add(18n, n))
  guard(Cred, Bool.and(Nat.is_le(16n, n), Bool.and(Nat.is_le(n, 1023n), Bool.and(Nat.is_le(Nat.add(Nat.add(18n, n), 77n), String.length(rest)), Bool.and(cose_ok(key), Bool.or(ed(flags), Nat.is_eq(String.length(key), 77n)))))), Some{Cred{B.hex(String.take(String.drop(rest, 18n), n)), B.hex(String.take(String.drop(key, 10n), 32n)), B.hex(String.take(String.drop(key, 45n), 32n))}})

# ATTESTATION OBJECT
# ------------------
# {"fmt": "none", "attStmt": {}, "authData": <bytes>} in canonical CBOR.
def att_prefix() -> String:
  B.bytes_of([163, 99, 102, 109, 116, 100, 110, 111, 110, 101, 103, 97, 116, 116, 83, 116, 109, 116, 160, 104, 97, 117, 116, 104, 68, 97, 116, 97])

def bstr.exact(+n: Nat, +d: String) -> Maybe<&2, String>:
  guard(String, Nat.is_eq(String.length(d), n), Some{d})

def bstr.pick(a: Bool, b: Bool, +s: String) -> Maybe<&2, String>:
  match a b:
    case True{} _:
      bstr.exact(U32.to_nat(B.byte_at(s, 1n)), String.drop(s, 2n))
    case _ True{}:
      bstr.exact(U32.to_nat(B.be16(String.drop(s, 1n))), String.drop(s, 3n))
    case _ _:
      None{}

def bstr.go(+h: U32, +s: String) -> Maybe<&2, String>:
  bstr.pick(U32.is_eq(h, 88), U32.is_eq(h, 89), s)

# The byte string after the prefix: 0x58 LEN or 0x59 LEN16, then exactly
# LEN bytes.
def bstr(+s: String) -> Maybe<&2, String>:
  bstr.go(B.byte_at(s, 0n), s)

def attested_data(+att: String) -> Maybe<&2, String>:
  guard(String, Bool.and(Nat.is_le(String.length(att), 4096n), String.eq(String.take(att, 28n), att_prefix())), bstr(String.drop(att, 28n)))

def mk_reg.go(b: Bool, +e: Spec.Expect, +c: Spec.Client, +a: Spec.Auth, +cred: Cred, pf: {Spec.register_ok(e, c, a) == b : Bool}) -> Maybe<&2, RegOk>:
  match b:
    case True{}:
      Some{RegOk{e, c, a, cred, pf}}
    case False{}:
      None{}

def mk_reg(+e: Spec.Expect, +c: Spec.Client, +a: Spec.Auth, +cred: Cred) -> Maybe<&2, RegOk>:
  mk_reg.go(Spec.register_ok(e, c, a), e, c, a, cred, {==})

def mk_login.go(b: Bool, +e: Spec.Expect, +c: Spec.Client, +a: Spec.Auth, +sig: Bool, +stored: U32, pf: {Spec.login_ok(e, c, a, sig, stored) == b : Bool}) -> Maybe<&2, LoginOk>:
  match b:
    case True{}:
      Some{LoginOk{e, c, a, sig, stored, pf}}
    case False{}:
      None{}

def mk_login(+e: Spec.Expect, +c: Spec.Client, +a: Spec.Auth, +sig: Bool, +stored: U32) -> Maybe<&2, LoginOk>:
  mk_login.go(Spec.login_ok(e, c, a, sig, stored), e, c, a, sig, stored, {==})

def client_challenge(+c: Spec.Client) -> String:
  match c:
    case Spec.Client{+k, +ch, +o, +x}:
      ch

def reg_challenge(+r: RegOk) -> String:
  match r:
    case RegOk{+e, +c, +a, +cred, pf}:
      client_challenge(c)

def reg_cred(+r: RegOk) -> Cred:
  match r:
    case RegOk{+e, +c, +a, +cred, pf}:
      cred

def reg_count(+r: RegOk) -> U32:
  match r:
    case RegOk{+e, +c, +a, +cred, pf}:
      Spec.auth_count(a)

def login_challenge(+l: LoginOk) -> String:
  match l:
    case LoginOk{+e, +c, +a, +s, +n, pf}:
      client_challenge(c)

def bind_auth(m: Maybe<&2, String>) -> Maybe<&2, AuthData>:
  match m:
    case None{}:
      None{}
    case Some{+d}:
      auth_of(d)

def register_check.c(+e: Spec.Expect, +c: Spec.Client, +a: Spec.Auth, m: Maybe<&2, Cred>) -> Maybe<&2, RegOk>:
  match m:
    case None{}:
      None{}
    case Some{+cred}:
      mk_reg(e, c, a, cred)

def register_check.a(+e: Spec.Expect, c: Maybe<&2, Spec.Client>, ad: Maybe<&2, AuthData>) -> Maybe<&2, RegOk>:
  match c ad:
    case Some{+cl} Some{+x}:
      match x:
        case AuthData{+a, +rest}:
          register_check.c(e, cl, a, cred_of(Spec.auth_flags(a), rest))
    case _ _:
      None{}

# Registration: attestation object and clientDataJSON (raw bytes) checked
# against the expectation.
def register_check(+e: Spec.Expect, +cd: String, +att: String) -> Maybe<&2, RegOk>:
  register_check.a(e, client_of(cd), bind_auth(attested_data(att)))
