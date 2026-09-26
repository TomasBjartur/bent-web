#!/usr/bin/env python3
"""End-to-end passkey tests with a software authenticator.

A pure-Python P-256 / ECDSA implementation (independent of BearSSL) plays
the authenticator; the test builds real WebAuthn payloads (canonical CBOR
attestation objects, COSE keys, authenticator data, DER signatures) and
drives sign-up, login and recovery against build/server, then attacks it.
usage: tests/passkey_test.py
"""
import base64, hashlib, json, os, re, secrets, socket, sqlite3, struct, subprocess, sys, tempfile, time, urllib.parse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORT = 8098
ORIGIN = f"http://localhost:{PORT}"
RP_ID = "localhost"
fails = 0


def check(name, ok, detail=""):
    global fails
    fails += 0 if ok else 1
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else f"   {detail}"))


# P-256 ---------------------------------------------------------------------
P = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
A = P - 3
G = (0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296,
     0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5)


def add(p1, p2):
    if p1 is None:
        return p2
    if p2 is None:
        return p1
    (x1, y1), (x2, y2) = p1, p2
    if x1 == x2 and (y1 + y2) % P == 0:
        return None
    if p1 == p2:
        l = (3 * x1 * x1 + A) * pow(2 * y1, P - 2, P) % P
    else:
        l = (y2 - y1) * pow(x2 - x1, P - 2, P) % P
    x3 = (l * l - x1 - x2) % P
    return (x3, (l * (x1 - x3) - y1) % P)


def mul(k, pt):
    r = None
    while k:
        if k & 1:
            r = add(r, pt)
        pt = add(pt, pt)
        k >>= 1
    return r


def der_int(v):
    b = v.to_bytes(32, "big").lstrip(b"\0") or b"\0"
    if b[0] & 0x80:
        b = b"\0" + b
    return b"\x02" + bytes([len(b)]) + b


class Key:
    def __init__(self):
        self.d = secrets.randbelow(N - 1) + 1
        self.x, self.y = mul(self.d, G)

    def sign(self, msg):
        e = int.from_bytes(hashlib.sha256(msg).digest(), "big")
        while True:
            k = secrets.randbelow(N - 1) + 1
            r = mul(k, G)[0] % N
            s = pow(k, N - 2, N) * (e + r * self.d) % N
            if r and s:
                body = der_int(r) + der_int(s)
                return b"\x30" + bytes([len(body)]) + body

    def cose(self, alg=b"\x26"):
        return (b"\xa5\x01\x02\x03" + alg + b"\x20\x01\x21\x58\x20" + self.x.to_bytes(32, "big")
                + b"\x22\x58\x20" + self.y.to_bytes(32, "big"))


# WebAuthn payloads ----------------------------------------------------------
def b64(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def unb64(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def client_data(kind, challenge_b64, origin=ORIGIN, cross=False, extra=None, raw_tail=""):
    d = {"type": kind, "challenge": challenge_b64, "origin": origin, "crossOrigin": cross}
    if extra:
        d.update(extra)
    s = json.dumps(d, separators=(",", ":"))
    return (s[:-1] + raw_tail + "}").encode()


def auth_data(flags, count, rp=RP_ID, attested=b""):
    return hashlib.sha256(rp.encode()).digest() + bytes([flags]) + struct.pack(">I", count) + attested


def attestation(ad, fmt=b"none"):
    head = b"\x58" + bytes([len(ad)]) if len(ad) < 256 else b"\x59" + struct.pack(">H", len(ad))
    return (b"\xa3\x63fmt" + bytes([0x60 + len(fmt)]) + fmt + b"\x67attStmt\xa0\x68authData" + head + ad)


def attested(cred_id, key, alg=b"\x26"):
    return b"\0" * 16 + struct.pack(">H", len(cred_id)) + cred_id + key.cose(alg)


# HTTP -----------------------------------------------------------------------
def req(method, path, form=None, sid=None, site="same-origin"):
    body = urllib.parse.urlencode(form).encode() if form is not None else b""
    h = f"{method} {path} HTTP/1.1\r\nHost: localhost\r\n"
    if sid:
        h += f"Cookie: sid={sid}\r\n"
    if site:
        h += f"Sec-Fetch-Site: {site}\r\n"
    if method == "POST":
        h += f"Content-Type: application/x-www-form-urlencoded\r\nContent-Length: {len(body)}\r\n"
    s = socket.create_connection(("127.0.0.1", PORT), timeout=20)
    s.sendall(h.encode() + b"\r\n" + body)
    out = b""
    try:
        while True:
            b = s.recv(65536)
            if not b:
                break
            out += b
    except (ConnectionResetError, socket.timeout):
        pass
    s.close()
    head, _, rb = out.partition(b"\r\n\r\n")
    status = int(head.split(b" ")[1]) if head.startswith(b"HTTP/1.1 ") else 0
    m = re.search(rb"Set-Cookie: sid=([0-9a-f]{64});", head)
    return status, rb.decode("utf-8", "replace"), (m.group(1).decode() if m else None)


def latest_link(db, email):
    row = db.execute("SELECT body FROM outbox WHERE to_email = ? ORDER BY id DESC LIMIT 1", (email,)).fetchone()
    return re.search(r"/verify\?t=([0-9a-f]{64})", row[0]).group(1) if row else None


def mail_count(db, email):
    return db.execute("SELECT count(*) FROM outbox WHERE to_email = ?", (email,)).fetchone()[0]


# Flows ----------------------------------------------------------------------
def reg_options(t):
    st, body, _ = req("POST", "/passkey/register/options", {"t": t})
    return st, (json.loads(body) if st == 200 else None)


def register(t, key, cred_id, **kw):
    st, o = reg_options(t)
    if st != 200:
        return st, None
    cd = client_data(kw.get("kind", "webauthn.create"), kw.get("challenge", o["challenge"]), kw.get("origin", ORIGIN), kw.get("cross", False), kw.get("extra"))
    ad = auth_data(kw.get("flags", 0x45), 0, kw.get("rp", RP_ID), kw.get("attested", attested(cred_id, key, kw.get("alg", b"\x26"))) + kw.get("trailer", b""))
    att = attestation(ad, kw.get("fmt", b"none"))
    st, body, sid = req("POST", "/passkey/register", {"t": t, "cd": b64(cd), "att": b64(att)}, site=kw.get("site", "same-origin"))
    return st, sid


def login_payload(key, cred_id, count, **kw):
    st, body, _ = req("POST", "/passkey/login/options", {})
    o = json.loads(body)
    cd = client_data(kw.get("kind", "webauthn.get"), kw.get("challenge", o["challenge"]), kw.get("origin", ORIGIN), kw.get("cross", False), kw.get("extra"), kw.get("raw_tail", ""))
    ad = auth_data(kw.get("flags", 0x05), count, kw.get("rp", RP_ID))
    signer = kw.get("signer", key)
    sig = signer.sign(ad + hashlib.sha256(kw.get("signed_cd", cd)).digest())
    return {"id": b64(kw.get("id", cred_id)), "cd": b64(cd), "ad": b64(ad), "sig": b64(sig)}


def login(key, cred_id, count, **kw):
    st, body, sid = req("POST", "/passkey/login", login_payload(key, cred_id, count, **kw))
    return st, sid


def main():
    tmp = tempfile.mkdtemp()
    dbpath = os.path.join(tmp, "blog.db")
    env = dict(os.environ, PORT=str(PORT), BLOG_DB=dbpath, BLOG_ORIGIN=ORIGIN, BLOG_RP_ID=RP_ID)
    srv = subprocess.Popen([os.path.join(ROOT, "build/server")], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        for _ in range(50):
            try:
                socket.create_connection(("127.0.0.1", PORT), timeout=0.2).close()
                break
            except OSError:
                time.sleep(0.1)
        run(sqlite3.connect(dbpath))
    finally:
        srv.terminate()
        srv.wait()
    print(f"\n{fails} failure(s)")
    sys.exit(1 if fails else 0)


def run(db):
    # Sign-up.
    st, body, _ = req("POST", "/signup", {"email": "Ann@Example.com", "name": "Ann", "handle": "Ann"})
    check("signup: generic answer", st == 200 and "Check your email" in body, st)
    t = latest_link(db, "ann@example.com")
    check("signup: link mailed (address lower-cased)", t is not None)
    st, body, _ = req("GET", f"/verify?t={t}")
    check("verify page", st == 200 and f'data-token="{t}"' in body and "ann@example.com" in body, st)
    st, _, _ = req("GET", f"/verify?t={t}")
    check("viewing the link twice does not use it up", st == 200, st)
    st, o = reg_options(t)
    check("register options", st == 200 and o["rpId"] == RP_ID and o["userName"] == "ann@example.com" and len(unb64(o["challenge"])) == 32, (st, o))
    key, cid = Key(), secrets.token_bytes(16)
    st, sid = register(t, key, cid)
    check("register passkey -> session", st == 200 and sid is not None, st)
    st, body, _ = req("GET", "/dash", sid=sid)
    check("signed in after sign-up", st == 200 and "Your blogs" in body, st)
    st, _ = register(t, key, secrets.token_bytes(16))
    check("link cannot be used twice", st == 403, st)
    st, _, _ = req("GET", f"/verify?t={t}")
    check("used link shows expired", st == 404, st)

    # Login.
    st, sid2 = login(key, cid, 1)
    check("login", st == 200 and sid2 is not None and sid2 != sid, st)
    st, body, _ = req("GET", "/dash", sid=sid2)
    check("signed in after login", st == 200, st)
    payload = login_payload(key, cid, 2)
    st, _, s1 = req("POST", "/passkey/login", payload)
    st2, _, _ = req("POST", "/passkey/login", payload)
    check("replayed assertion rejected", st == 200 and st2 == 403, (st, st2))
    st, _ = login(key, cid, 2)
    check("counter not advancing rejected", st == 403, st)
    st, _ = login(key, cid, 0)
    check("counter reset to 0 rejected", st == 403, st)

    # Login attacks (each with a fresh challenge and an advancing counter).
    n = [10]

    def attempt(name, **kw):
        n[0] += 1
        st, sid_ = login(key, cid, n[0], **kw)
        check(name, st in (400, 403) and sid_ is None, st)

    attempt("wrong origin", origin="https://evil.example")
    attempt("origin with a trailing slash", origin=ORIGIN + "/")
    attempt("wrong type (create)", kind="webauthn.create")
    attempt("cross-origin iframe", cross=True)
    attempt("topOrigin present", extra={"topOrigin": "https://evil.example"})
    attempt("wrong RP ID hash", rp="evil.example")
    attempt("user not verified (UV off)", flags=0x01)
    attempt("user not present (UP off)", flags=0x04)
    attempt("signed by another key", signer=Key())
    attempt("signature over different clientData", signed_cd=b'{"type":"webauthn.get"}')
    attempt("unknown credential id", id=secrets.token_bytes(16))
    attempt("challenge not issued by us", challenge=b64(secrets.token_bytes(32)))
    attempt("duplicate type key", raw_tail=',"type":"webauthn.get"')
    attempt("duplicate origin key", raw_tail=f',"origin":"{ORIGIN}"')
    attempt("trailing garbage after clientData", raw_tail='}')
    n[0] += 1
    p = login_payload(key, cid, n[0])
    p["sig"] = p["sig"][:-4]
    st, _, _ = req("POST", "/passkey/login", p)
    check("truncated signature", st in (400, 403), st)
    n[0] += 1
    st, _, _ = req("POST", "/passkey/login", login_payload(key, cid, n[0]), site=None)
    check("login without Sec-Fetch-Site (CSRF)", st == 403, st)
    n[0] += 1
    st, sid3 = login(key, cid, n[0])
    check("honest login still works after attacks", st == 200 and sid3, st)

    # Registration attacks.
    def fresh(email):
        req("POST", "/signup", {"email": email, "name": "X", "handle": "x" + secrets.token_hex(4)})
        return latest_link(db, email)

    for name, kw in [
        ("reg: attestation fmt packed", {"fmt": b"packed"}),
        ("reg: RSA key (alg -257) rejected", {"alg": b"\x39\x01\x00"}),
        ("reg: trailing bytes without ED flag", {"trailer": b"\x00"}),
        ("reg: no AT flag", {"flags": 0x05}),
        ("reg: no UV flag", {"flags": 0x41}),
        ("reg: wrong origin", {"origin": "https://evil.example"}),
        ("reg: wrong type", {"kind": "webauthn.get"}),
        ("reg: cross-origin", {"cross": True}),
        ("reg: wrong RP", {"rp": "evil.example"}),
        ("reg: challenge not issued by us", {"challenge": b64(secrets.token_bytes(32))}),
        ("reg: no Sec-Fetch-Site (CSRF)", {"site": None}),
    ]:
        email = f"r{secrets.token_hex(4)}@example.com"
        tt = fresh(email)
        st, s_ = register(tt, Key(), secrets.token_bytes(16), **kw)
        check(name, st in (400, 403) and s_ is None, st)

    # A login challenge cannot be used to register (purpose and binding).
    email = "bind@example.com"
    tt = fresh(email)
    _, lb, _ = req("POST", "/passkey/login/options", {})
    st, s_ = register(tt, Key(), secrets.token_bytes(16), challenge=json.loads(lb)["challenge"])
    check("reg: login challenge rejected", st == 403 and s_ is None, st)
    # A register challenge for link A cannot complete link B.
    ta, tb = fresh("a2@example.com"), fresh("b2@example.com")
    _, oa = reg_options(ta)
    st, s_ = register(tb, Key(), secrets.token_bytes(16), challenge=oa["challenge"])
    check("reg: challenge from another link rejected", st == 403 and s_ is None, st)
    # Duplicate credential id (someone else's).
    tt = fresh("dup@example.com")
    st, s_ = register(tt, Key(), cid)
    check("reg: existing credential id rejected", st == 403 and s_ is None, st)

    # Handles are unique: Ann took "ann" (typed "Ann"); every variant of it
    # is refused, before any email or passkey.
    check("handle stored lowercased", db.execute("SELECT handle FROM user WHERE email = 'Ann@Example.com'").fetchall() == [("ann",)])
    for h in ["ann", "ANN", "@Ann", " ann "]:
        st, body, _ = req("POST", "/signup", {"email": f"other{len(h)}{h.strip('@ ')}@example.com", "name": "Ann", "handle": h})
        check(f"taken handle {h!r} refused", st == 409 and "username is taken" in body, (st, body[-200:]))
    for h in ["an", "1ann", "ann-b", "annа", "a" * 31]:
        st, _, _ = req("POST", "/signup", {"email": "new@example.com", "name": "N", "handle": h})
        check(f"bad handle {h!r} refused", st == 400, st)
    check("same display name is fine (the handle tells them apart)",
          req("POST", "/signup", {"email": "ann2@example.com", "name": "Ann", "handle": "ann_two"})[0] == 200)

    # Enumeration and rate limits.
    before = mail_count(db, "ann@example.com")
    st, body, _ = req("POST", "/signup", {"email": "ann@example.com", "name": "Imposter", "handle": "imposter"})
    check("signup with a taken email: same answer", st == 200 and "Check your email" in body)
    check("signup with a taken email: no mail", mail_count(db, "ann@example.com") == before)
    st, body, _ = req("POST", "/recover", {"email": "nobody@example.com"})
    check("recover unknown email: same answer", st == 200 and "Check your email" in body)
    check("recover unknown email: no mail", mail_count(db, "nobody@example.com") == 0)
    for _ in range(4):
        req("POST", "/recover", {"email": "ann@example.com"})
    check("recover rate limited to 3/hour", mail_count(db, "ann@example.com") == before + 2, mail_count(db, "ann@example.com") - before)

    # Recovery: a new passkey for the same account; both keys work.
    tr = latest_link(db, "ann@example.com")
    k2, cid2 = Key(), secrets.token_bytes(16)
    st, s_ = register(tr, k2, cid2)
    check("recovery registers a new passkey", st == 200 and s_, st)
    st, s_ = login(k2, cid2, 1)
    check("login with the new passkey", st == 200 and s_, st)
    n[0] += 1
    st, s_ = login(key, cid, n[0])
    check("old passkey still works", st == 200 and s_, st)
    uids = db.execute("SELECT DISTINCT user_id FROM credential WHERE id IN (?, ?)", (cid, cid2)).fetchall()
    check("both passkeys belong to the same account", len(uids) == 1)

    # Input validation on sign-up.
    for bad in ["no-at-sign", "a@b@c", "<x>@y.z", "a b@c.d", "@x.io", "x@", "a@b.c\r\nBcc: v@x"]:
        st, _, _ = req("POST", "/signup", {"email": bad, "name": "X", "handle": "xyz"})
        check(f"bad email rejected: {bad!r}", st == 400, st)
    st, _, _ = req("POST", "/signup", {"email": "ok@example.com", "name": "a\x01b", "handle": "okay"})
    check("control char in name rejected", st == 400, st)
    body = db.execute("SELECT body FROM outbox ORDER BY id DESC LIMIT 1").fetchone()[0]
    check("mail link uses the configured origin", body.count(ORIGIN + "/verify?t=") == 1)


main()
