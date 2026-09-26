# SPEC: when a passkey registration or login is accepted.
#
# Human-owned. Code may import this file but must never redefine or weaken
# it. Every change here is a security decision and must be called out in the
# commit message. (W3C WebAuthn Level 3, sections 7.1 and 7.2.)
#
# Not here, and enforced in C (src/c/db_core.c, tested): the challenge was
# issued by this server, is unexpired and unused, has the right purpose (and
# for registration is bound to the emailed link being used), and is consumed
# in the same transaction that creates the session. The login transaction
# also re-verifies the signature with the key it reads from the database.
import Base

# What the browser reported (clientDataJSON).
# cross: crossOrigin was true, or a topOrigin was present (an iframe).
type Client is Data:
  Client{kind: String, challenge: String, origin: String, cross: Bool}

# What the authenticator reported (authenticator data).
# rp_hash: SHA-256 of the RP ID, as lowercase hex.
type Auth is Data:
  Auth{rp_hash: String, flags: U32, count: U32}

# What this server expects: its origin, and the hash of its RP ID.
type Expect is Data:
  Expect{origin: String, rp_hash: String}

def flag(+flags: U32, +bit: U32) -> Bool:
  U32.is_ne((flags .&. bit : U32), 0)

# User present, user verified (PIN or biometric), attested credential data.
def up(+f: U32) -> Bool:
  flag(f, 1)

def uv(+f: U32) -> Bool:
  flag(f, 4)

def at(+f: U32) -> Bool:
  flag(f, 64)

def client_ok(+e: Expect, +c: Client, +kind: String) -> Bool:
  match e c:
    case Expect{+origin, +rp} Client{+k, +ch, +o, +cross}:
      Bool.and(String.eq(k, kind), Bool.and(String.eq(o, origin), Bool.not(cross)))

def auth_ok(+e: Expect, +a: Auth) -> Bool:
  match e a:
    case Expect{+origin, +rp} Auth{+h, +f, +n}:
      Bool.and(String.eq(h, rp), Bool.and(up(f), uv(f)))

def auth_flags(+a: Auth) -> U32:
  match a:
    case Auth{+h, +f, +n}:
      f

def auth_count(+a: Auth) -> U32:
  match a:
    case Auth{+h, +f, +n}:
      n

# The signature counter advances, or the authenticator has none (both 0).
def counter_ok(+stored: U32, +new: U32) -> Bool:
  Bool.or(Bool.and(U32.is_eq(stored, 0), U32.is_eq(new, 0)), U32.is_gt(new, stored))

def register_ok(+e: Expect, +c: Client, +a: Auth) -> Bool:
  Bool.and(client_ok(e, c, "webauthn.create"), Bool.and(auth_ok(e, a), at(auth_flags(a))))

# sig: the assertion signature verified with the credential's public key.
def login_ok(+e: Expect, +c: Client, +a: Auth, +sig: Bool, +stored: U32) -> Bool:
  Bool.and(client_ok(e, c, "webauthn.get"), Bool.and(auth_ok(e, a), Bool.and(sig, counter_ok(stored, auth_count(a)))))
