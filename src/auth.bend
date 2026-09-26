# Sign-up, log in and recovery, with passkeys (WebAuthn) and emailed links.
#
# The only effects that create sessions are auth_register_raw and
# auth_login_raw, called only from `register` and `login_go` here
# (tools/lint.sh checks this), which take a RegOk / LoginOk: a session is
# only created for a response that passed every check in spec/webauthn.bend.
# C then consumes the challenge (and email token) and creates the session
# in one transaction, re-verifying a login signature with the stored key.
import Base
import ../spec/webauthn.bend as WSpec
import ./bytes.bend as B
import ./db.bend as Db
import ./html.bend as Html
import ./json.bend as J
import ./pages.bend as Pages
import ./text.bend as Text
import ./webauthn.bend as WA

# EFFECTS (src/effects/db.c)
# -------

# CONFIGURATION
# -------------
# origin: e.g. "https://blog.example" (what browsers report).
# rp_id: e.g. "blog.example". rp_hash: SHA-256 of rp_id, hex.
# direct: test mode without a mail sender (BLOG_SIGNUP_DIRECT=1): sign-up
# goes straight to creating a passkey; the email is not verified and there
# is no recovery.
type Conf is Data:
  Conf{origin: String, rp_id: String, rp_hash: String, direct: Bool}

def origin(+c: Conf) -> String:
  match c:
    case Conf{+o, +r, +h, +d}:
      o

def direct(+c: Conf) -> Bool:
  match c:
    case Conf{+o, +r, +h, +d}:
      d

def auth_email(purpose: U32, email: String, name: String, origin: String) -> IO(U32):
  import "./effects/auth.c"

def auth_signup_direct(email: String, name: String, origin: String) -> IO(Result<&1, &1, U32 & String, String>):
  import "./effects/auth.c"

def auth_token_info(token: String) -> IO(List<&2, String>):
  import "./effects/auth.c"

def auth_challenge_new(purpose: U32, token: String) -> IO(String):
  import "./effects/auth.c"

def auth_cred(id: String) -> IO(List<&2, String>):
  import "./effects/auth.c"

def p256_verify(x: String, y: String, msg: String, sig: String) -> IO(U32):
  import "./effects/auth.c"

def sha256_hex(bytes: String) -> IO(String):
  import "./effects/auth.c"

def random_hex(n: U32) -> IO(String):
  import "./effects/auth.c"

def auth_register_raw(token: String, challenge: String, id: String, x: String, y: String, count: U32) -> IO(Result<&1, &1, U32 & String, String>):
  import "./effects/auth.c"

def auth_login_raw(challenge: String, id: String, msg: String, sig: String) -> IO(Result<&1, &1, U32 & String, String>):
  import "./effects/auth.c"

def expect(+c: Conf) -> WSpec.Expect:
  match c:
    case Conf{+o, +r, +h, +d}:
      WSpec.Expect{o, h}

def rp_id(+c: Conf) -> String:
  match c:
    case Conf{+o, +r, +h, +d}:
      r

def conf(+origin: String, +rp_id: String, +direct: Bool) -> IO(Conf):
  do IO<Conf>:
    +h : String <- sha256_hex(B.hex(rp_id))
    return Conf{origin, rp_id, h, direct}

# RESPONSES
# ---------
def done(r: Socket & Result<&1, &1, U32 & String, Unit>) -> IO(Unit):
  (s, x) = r
  Socket.close(s)

def one(x: String) -> List<&2, String>:
  Con{x, Nil{}}

def respond(s: Socket, +token: String, status: U32, ctype: U32, body: String, cookie: String) -> IO(Unit):
  do IO<Unit>:
    r : Socket & Result<&1, &1, U32 & String, Unit> <- Db.page(s, status, ctype, one(body), Nil{}, token, cookie, "")
    done(r)

def html(s: Socket, +token: String, status: U32, +signed: Bool, title: String, body: String) -> IO(Unit):
  respond(s, token, status, 0, Pages.layout(title, signed, body), "")

def text(s: Socket, +token: String, status: U32, body: String) -> IO(Unit):
  respond(s, token, status, 1, body, "")

def json(s: Socket, +token: String, body: String) -> IO(Unit):
  respond(s, token, 200, 3, body, "")

def form(+body: String) -> List<&2, Text.Field>:
  Maybe.default(&2, List<&2, Text.Field>, Text.form_parse(body), Nil{})

def e(s: String) -> String:
  Html.esc(s, "")

def col(r: List<&2, String>, n: Nat) -> String:
  Pages.col(r, n)

# PAGES
# -----
def signup_page() -> String:
  "<h1>Create an account</h1><p>We email you a link to confirm your address. Then you create a passkey: no password, ever.</p><form method=\"post\" action=\"/signup\"><label>Email <input name=\"email\" type=\"email\" required maxlength=\"254\" autocomplete=\"email\"></label><label>Name <input name=\"name\" required maxlength=\"64\" autocomplete=\"name\"></label><button>Email me a link</button></form><p><a href=\"/login\">I already have an account</a></p>"

def sent_page() -> String:
  "<h1>Check your email</h1><p>If that address can be used, a link is on its way. It works once, for 30 minutes.</p>"

def login_page() -> String:
  "<h1>Log in</h1><p><button id=\"passkey-login\">Log in with a passkey</button></p><p id=\"passkey-status\" class=\"crumb\"></p><h2>Lost your passkey?</h2><form method=\"post\" action=\"/recover\"><label>Email <input name=\"email\" type=\"email\" required maxlength=\"254\" autocomplete=\"email\"></label><button>Email me a link</button></form><p><a href=\"/signup\">Create an account</a></p><script src=\"/s/passkey.js\"></script>"

def verify_title(b: Bool) -> String:
  match b:
    case True{}:
      "Finish creating your account"
    case False{}:
      "Add a new passkey"

def verify_page(+token: String, +email: String, +purpose: String) -> String:
  "<h1>" ++ (verify_title(String.eq(purpose, "1")) ++ ("</h1><p>For <strong>" ++ (e(email) ++ ("</strong>. Your device will ask you to confirm with a fingerprint, face or PIN.</p><p><button id=\"passkey-register\" data-token=\"" ++ (e(token) ++ "\">Create a passkey</button></p><p id=\"passkey-status\" class=\"crumb\"></p><script src=\"/s/passkey.js\"></script>")))))

# SIGN UP AND RECOVERY
# --------------------
def h_signup_page(s: Socket, +token: String, +who: U32) -> IO(Unit):
  html(s, token, 200, U32.is_ne(who, 0), "Create an account", signup_page())

def h_login_page(s: Socket, +token: String, +who: U32) -> IO(Unit):
  html(s, token, 200, U32.is_ne(who, 0), "Log in", login_page())

def h_signup_direct(s: Socket, +token: String, r: Result<&1, &1, U32 & String, String>) -> IO(Unit):
  match r:
    case Done{+t}:
      do IO<Unit>:
        x : Socket & Result<&1, &1, U32 & String, Unit> <- Db.page(s, 303, 0, one(""), Nil{}, token, "", "/verify?t=" ++ t)
        done(x)
    case Fail{err}:
      html(s, token, 409, False{}, "Not available", "<h1>That did not work</h1><p>This email may already have an account, or too many attempts were made. Try again later.</p>")

def h_signup3(b: Bool, s: Socket, +c: Conf, +token: String, +email: String, +name: String) -> IO(Unit):
  match b:
    case True{}:
      do IO<Unit>:
        r : Result<&1, &1, U32 & String, String> <- auth_signup_direct(email, name, origin(c))
        h_signup_direct(s, token, r)
    case False{}:
      do IO<Unit>:
        code : U32 <- auth_email(1, email, name, origin(c))
        html(s, token, 200, False{}, "Check your email", sent_page())

def h_signup2(s: Socket, +c: Conf, +token: String, em: Maybe<&2, Text.Email>, nm: Maybe<&2, Text.Name>) -> IO(Unit):
  match em nm:
    case Some{x} Some{y}:
      h_signup3(direct(c), s, c, token, Text.Email.text(x), Text.Name.text(y))
    case _ _:
      html(s, token, 400, False{}, "Error", Pages.error_body(400))

def h_signup(s: Socket, +c: Conf, +token: String, +body: String) -> IO(Unit):
  +xs = form(body)
  h_signup2(s, c, token, Text.form_email(xs, "email"), Text.form_name(xs, "name"))

def h_recover2(s: Socket, +c: Conf, +token: String, em: Maybe<&2, Text.Email>) -> IO(Unit):
  match em:
    case Some{x}:
      do IO<Unit>:
        code : U32 <- auth_email(2, Text.Email.text(x), "", origin(c))
        html(s, token, 200, False{}, "Check your email", sent_page())
    case None{}:
      html(s, token, 400, False{}, "Error", Pages.error_body(400))

def h_recover(s: Socket, +c: Conf, +token: String, +body: String) -> IO(Unit):
  h_recover2(s, c, token, Text.form_email(form(body), "email"))

def h_verify2(s: Socket, +token: String, +t: String, info: List<&2, String>) -> IO(Unit):
  match info:
    case Nil{}:
      html(s, token, 404, False{}, "Link expired", "<h1>This link has expired or was already used</h1><p><a href=\"/login\">Ask for a new one</a></p>")
    case Con{+p, +rest}:
      html(s, token, 200, False{}, "Create a passkey", verify_page(t, col(rest, 0n), p))

def h_verify.go(s: Socket, +token: String, +t: String) -> IO(Unit):
  do IO<Unit>:
    info : List<&2, String> <- auth_token_info(t)
    h_verify2(s, token, t, info)

# GET /verify?t=<token>. Viewing the page does not use up the link (mail
# scanners open links); creating the passkey does.
def h_verify(s: Socket, +token: String, +query: String) -> IO(Unit):
  +t = Maybe.default(&2, String, Text.form_raw(form(query), "t"), "")
  h_verify.go(s, token, t)

# PASSKEY REGISTRATION
# --------------------
def b64_of_hex(+h: String) -> String:
  B.b64(Maybe.default(&2, String, B.unhex(h), ""))

def display.go(b: Bool, +name: String, +email: String) -> String:
  match b:
    case True{}:
      email
    case False{}:
      name

def display(+name: String, +email: String) -> String:
  display.go(String.is_empty(name), name, email)

def reg_options_json(+c: Conf, +chal: String, +uid: String, +email: String, +name: String) -> String:
  "{\"challenge\":\"" ++ (b64_of_hex(chal) ++ ("\",\"rpId\":\"" ++ (J.q(rp_id(c)) ++ ("\",\"rpName\":\"bent\",\"userId\":\"" ++ (b64_of_hex(uid) ++ ("\",\"userName\":\"" ++ (J.q(email) ++ ("\",\"userDisplay\":\"" ++ (J.q(display(name, email)) ++ "\"}")))))))))

def h_reg_options4(bad: Bool, s: Socket, +c: Conf, +token: String, +email: String, +name: String, +chal: String) -> IO(Unit):
  match bad:
    case True{}:
      text(s, token, 403, "expired\n")
    case False{}:
      do IO<Unit>:
        +uid : String <- random_hex(16)
        json(s, token, reg_options_json(c, chal, uid, email, name))

def h_reg_options3(s: Socket, +c: Conf, +token: String, +email: String, +name: String, +chal: String) -> IO(Unit):
  h_reg_options4(String.is_empty(chal), s, c, token, email, name, chal)

def h_reg_options2(s: Socket, +c: Conf, +token: String, +t: String, info: List<&2, String>) -> IO(Unit):
  match info:
    case Nil{}:
      text(s, token, 403, "expired\n")
    case Con{p, +rest}:
      do IO<Unit>:
        +chal : String <- auth_challenge_new(1, t)
        h_reg_options3(s, c, token, col(rest, 0n), col(rest, 1n), chal)

def h_reg_options.go(s: Socket, +c: Conf, +token: String, +t: String) -> IO(Unit):
  do IO<Unit>:
    info : List<&2, String> <- auth_token_info(t)
    h_reg_options2(s, c, token, t, info)

def h_reg_options(s: Socket, +c: Conf, +token: String, +body: String) -> IO(Unit):
  +t = Maybe.default(&2, String, Text.form_raw(form(body), "t"), "")
  h_reg_options.go(s, c, token, t)

def register.go(+t: String, +r: WA.RegOk, cred: WA.Cred) -> IO(Result<&1, &1, U32 & String, String>):
  match cred:
    case WA.Cred{+id, +x, +y}:
      auth_register_raw(t, B.hex(Maybe.default(&2, String, B.unb64(WA.reg_challenge(r)), "")), id, x, y, WA.reg_count(r))

# Creates the account (or adds the passkey) and a session. Only reachable
# with a RegOk.
def register(+t: String, +r: WA.RegOk) -> IO(Result<&1, &1, U32 & String, String>):
  register.go(t, r, WA.reg_cred(r))

def signed_in(s: Socket, +token: String, r: Result<&1, &1, U32 & String, String>) -> IO(Unit):
  match r:
    case Done{+session}:
      respond(s, token, 200, 1, "/dash", session)
    case Fail{err}:
      text(s, token, 403, "rejected\n")

def h_register2(s: Socket, +token: String, +t: String, m: Maybe<&2, WA.RegOk>) -> IO(Unit):
  match m:
    case None{}:
      text(s, token, 400, "rejected\n")
    case Some{+r}:
      do IO<Unit>:
        res : Result<&1, &1, U32 & String, String> <- register(t, r)
        signed_in(s, token, res)

def unb64(m: Maybe<&2, String>) -> String:
  match m:
    case None{}:
      ""
    case Some{+s}:
      Maybe.default(&2, String, B.unb64(s), "")

def h_register(s: Socket, +c: Conf, +token: String, +body: String) -> IO(Unit):
  +xs = form(body)
  h_register2(s, token, Maybe.default(&2, String, Text.form_raw(xs, "t"), ""), WA.register_check(expect(c), unb64(Text.form_raw(xs, "cd")), unb64(Text.form_raw(xs, "att"))))

# PASSKEY LOGIN
# -------------
def h_login_options2(s: Socket, +c: Conf, +token: String, +chal: String) -> IO(Unit):
  json(s, token, "{\"challenge\":\"" ++ (b64_of_hex(chal) ++ ("\",\"rpId\":\"" ++ (J.q(rp_id(c)) ++ "\"}"))))

def h_login_options(s: Socket, +c: Conf, +token: String) -> IO(Unit):
  do IO<Unit>:
    +chal : String <- auth_challenge_new(2, "")
    h_login_options2(s, c, token, chal)

# Creates a session. Only reachable with a LoginOk.
def login_go(+l: WA.LoginOk, +id: String, +msg: String, +sig: String) -> IO(Result<&1, &1, U32 & String, String>):
  auth_login_raw(B.hex(Maybe.default(&2, String, B.unb64(WA.login_challenge(l)), "")), id, msg, sig)

def h_login5(s: Socket, +token: String, +id: String, +msg: String, +sig: String, m: Maybe<&2, WA.LoginOk>) -> IO(Unit):
  match m:
    case None{}:
      text(s, token, 403, "rejected\n")
    case Some{+l}:
      do IO<Unit>:
        res : Result<&1, &1, U32 & String, String> <- login_go(l, id, msg, sig)
        signed_in(s, token, res)

# With the credential's key and counter: verify the signature over
# authData || SHA-256(clientDataJSON), then check everything.
def h_login4(s: Socket, +c: Conf, +token: String, +id: String, +cl: WSpec.Client, +a: WSpec.Auth, +msg: String, +sig: String, +x: String, +y: String, +stored: U32) -> IO(Unit):
  do IO<Unit>:
    +ok : U32 <- p256_verify(x, y, msg, sig)
    h_login5(s, token, id, msg, sig, WA.mk_login(expect(c), cl, a, U32.is_eq(ok, 1), stored))

def h_login3(s: Socket, +c: Conf, +token: String, +id: String, +cl: WSpec.Client, +a: WSpec.Auth, +ad: String, +sig: String, +cdh: String, cred: List<&2, String>) -> IO(Unit):
  match cred:
    case Nil{}:
      text(s, token, 403, "rejected\n")
    case Con{+u, +rest}:
      h_login4(s, c, token, id, cl, a, B.hex(ad) ++ cdh, B.hex(sig), col(rest, 0n), col(rest, 1n), Maybe.default(&2, U32, U32.read(col(rest, 2n)), 4294967295))

def h_login2(s: Socket, +c: Conf, +token: String, +id: String, +cd: String, +ad: String, +sig: String, cl: Maybe<&2, WSpec.Client>, a: Maybe<&2, WA.AuthData>) -> IO(Unit):
  match cl a:
    case Some{+client} Some{+x}:
      match x:
        case WA.AuthData{+auth, rest}:
          do IO<Unit>:
            +cdh : String <- sha256_hex(B.hex(cd))
            cred : List<&2, String> <- auth_cred(id)
            h_login3(s, c, token, id, client, auth, ad, sig, cdh, cred)
    case _ _:
      text(s, token, 400, "rejected\n")

def h_login(s: Socket, +c: Conf, +token: String, +body: String) -> IO(Unit):
  +xs = form(body)
  +cd = unb64(Text.form_raw(xs, "cd"))
  +ad = unb64(Text.form_raw(xs, "ad"))
  h_login2(s, c, token, B.hex(unb64(Text.form_raw(xs, "id"))), cd, ad, unb64(Text.form_raw(xs, "sig")), WA.client_of(cd), WA.auth_of(ad))

# THE BROWSER SIDE
# ----------------
def passkey_js() -> String:
  "'use strict';\n(() => {\nconst enc = (buf) => { const b = new Uint8Array(buf); let s = ''; for (let i = 0; i < b.length; i++) s += String.fromCharCode(b[i]); return btoa(s).replace(/\\+/g, '-').replace(/\\//g, '_').replace(/=+$/, ''); };\nconst dec = (s) => { const t = atob(s.replace(/-/g, '+').replace(/_/g, '/')); const b = new Uint8Array(t.length); for (let i = 0; i < t.length; i++) b[i] = t.charCodeAt(i); return b; };\nconst post = (url, data) => fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams(data), credentials: 'same-origin' });\nconst status = (msg) => { const el = document.getElementById('passkey-status'); if (el) el.textContent = msg; };\nconst finish = async (res) => { if (res.ok) { location.assign(await res.text()); } else { status('That did not work. Please try again.'); } };\nconst reg = document.getElementById('passkey-register');\nif (reg) reg.addEventListener('click', async () => {\n  try {\n    const t = reg.dataset.token;\n    const r = await post('/passkey/register/options', { t });\n    if (!r.ok) { status('This link has expired. Ask for a new one.'); return; }\n    const o = await r.json();\n    const cred = await navigator.credentials.create({ publicKey: { challenge: dec(o.challenge), rp: { id: o.rpId, name: o.rpName }, user: { id: dec(o.userId), name: o.userName, displayName: o.userDisplay }, pubKeyCredParams: [{ type: 'public-key', alg: -7 }], authenticatorSelection: { residentKey: 'required', userVerification: 'required' }, attestation: 'none', timeout: 120000 } });\n    await finish(await post('/passkey/register', { t, cd: enc(cred.response.clientDataJSON), att: enc(cred.response.attestationObject) }));\n  } catch (err) { status('Cancelled or not supported on this device.'); }\n});\nconst login = document.getElementById('passkey-login');\nif (login) login.addEventListener('click', async () => {\n  try {\n    const r = await post('/passkey/login/options', {});\n    const o = await r.json();\n    const cred = await navigator.credentials.get({ publicKey: { challenge: dec(o.challenge), rpId: o.rpId, userVerification: 'required', timeout: 120000 } });\n    await finish(await post('/passkey/login', { id: enc(cred.rawId), cd: enc(cred.response.clientDataJSON), ad: enc(cred.response.authenticatorData), sig: enc(cred.response.signature) }));\n  } catch (err) { status('Cancelled or not supported on this device.'); }\n});\n})();\n"
