// EFFECTS: auth_email, auth_token_info, auth_challenge_new, auth_cred,
//          p256_verify, sha256_hex, random_hex, auth_register_raw,
//          auth_login_raw.
// WHY C:  SQLite, BearSSL, getrandom.
// PRE:    called only by the Bend event loop thread, after db_open.
// POST:   per effect below. Binary values cross as lowercase hex.
// LAWS THAT DEPEND ON THIS: webauthn_reg_ok / webauthn_login_ok cover the
//         checks in Bend; these effects consume challenges and email tokens
//         atomically and re-verify login signatures with the stored key
//         (src/c/db_core.c). auth_register_raw / auth_login_raw must only be
//         called from src/auth.bend's register.go / login_go (tools/lint.sh).
// VERIFIED BY: tests/c/auth_core_test.c, tests/passkey_test.py.
#include "../src/effects/app_common.h"

#ifdef CID(auth_email)

// f: purpose, email, name, origin. Answers an AuthResult code.
Term auth_email_run(Env e, Term *f, IoWork *w) {
  (void)w;
  ASSERT(app_db_ready);
  u64 n1 = 0, n2 = 0, n3 = 0;
  char *email = io_cstr(e, f[1], &n1), *name = io_cstr(e, f[2], &n2), *origin = io_cstr(e, f[3], &n3);
  AuthResult r = AUTH_INVALID;
  if (n1 <= 254u && n2 <= 64u && n3 <= 200u) {
    r = auth_email_token(&app_db, (uint32_t)f[0], (DbText){email, (uint32_t)n1}, (DbText){name, (uint32_t)n2},
                         (DbText){origin, (uint32_t)n3}, app_now_ms());
  }
  free(email);
  free(name);
  free(origin);
  return (Term)(uint32_t)r;
}

static void __attribute__((constructor)) auth_email_use(void) {
  io_eff(CID(auth_email), auth_email_run, 0);
}

#endif

#ifdef CID(auth_token_info)

// f: token (hex). Answers [purpose, email, name], or [] if not valid.
Term auth_token_info_run(Env e, Term *f, IoWork *w) {
  (void)w;
  ASSERT(app_db_ready);
  uint8_t h[32];
  app_token_hash(e, f[0], h);
  uint32_t purpose = 0;
  char email[256], name[128], pb[4];
  if (auth_token_info(&app_db, h, app_now_ms(), &purpose, email, name) != AUTH_OK) return term_pak(CID(Nil), 0);
  pb[0] = (char)('0' + (purpose % 10u));
  const char *v[3] = {pb, email, name};
  uint32_t l[3] = {1u, (uint32_t)strlen(email), (uint32_t)strlen(name)};
  return app_strs(e, CID(Con), CID(Nil), v, l, 3);
}

static void __attribute__((constructor)) auth_token_info_use(void) {
  io_eff(CID(auth_token_info), auth_token_info_run, 0);
}

#endif

#ifdef CID(auth_challenge_new)

// f: purpose, token (hex; "" for login). Answers the challenge as hex, or "".
Term auth_challenge_new_run(Env e, Term *f, IoWork *w) {
  (void)w;
  ASSERT(app_db_ready);
  uint32_t purpose = (uint32_t)f[0];
  uint8_t h[32], out[32];
  app_token_hash(e, f[1], h);
  if (purpose != CHAL_REGISTER && purpose != CHAL_LOGIN) return io_str(e, "", 0);
  AuthResult r = auth_challenge(&app_db, purpose, purpose == CHAL_REGISTER ? h : NULL, app_now_ms(), out);
  if (r != AUTH_OK) return io_str(e, "", 0);
  return app_hex(e, out, 32);
}

static void __attribute__((constructor)) auth_challenge_new_use(void) {
  io_eff(CID(auth_challenge_new), auth_challenge_new_run, 0);
}

#endif

#ifdef CID(auth_cred)

// f: credential id (hex). Answers [user, x (hex), y (hex), count], or [].
Term auth_cred_run(Env e, Term *f, IoWork *w) {
  (void)w;
  ASSERT(app_db_ready);
  uint8_t id[CRED_ID_MAX];
  int32_t n = app_unhex(e, f[0], id, sizeof id);
  uint32_t user = 0, count = 0;
  uint8_t x[32], y[32];
  if (n <= 0 || auth_credential(&app_db, id, (uint32_t)n, &user, x, y, &count) != AUTH_OK) return term_pak(CID(Nil), 0);
  char ub[16], cb[16], xh[64], yh[64];
  int ul = snprintf(ub, sizeof ub, "%u", user), cl = snprintf(cb, sizeof cb, "%u", count);
  ASSERT(ul > 0 && cl > 0);
  hex_encode(x, 32, (uint8_t *)xh);
  hex_encode(y, 32, (uint8_t *)yh);
  const char *v[4] = {ub, xh, yh, cb};
  uint32_t l[4] = {(uint32_t)ul, 64u, 64u, (uint32_t)cl};
  return app_strs(e, CID(Con), CID(Nil), v, l, 4);
}

static void __attribute__((constructor)) auth_cred_use(void) {
  io_eff(CID(auth_cred), auth_cred_run, 0);
}

#endif

#ifdef CID(p256_verify)

// f: x, y, msg, sig (all hex). Answers 1 if the signature is valid.
Term p256_verify_run(Env e, Term *f, IoWork *w) {
  (void)w;
  uint8_t x[32], y[32], msg[4096], sig[80];
  int32_t xn = app_unhex(e, f[0], x, 32), yn = app_unhex(e, f[1], y, 32);
  int32_t mn = app_unhex(e, f[2], msg, sizeof msg), sn = app_unhex(e, f[3], sig, sizeof sig);
  if (xn != 32 || yn != 32 || mn < 0 || sn <= 0) return (Term)0;
  return (Term)(uint32_t)auth_p256_verify(x, y, msg, (uint32_t)mn, sig, (uint32_t)sn);
}

static void __attribute__((constructor)) p256_verify_use(void) {
  io_eff(CID(p256_verify), p256_verify_run, 0);
}

#endif

#ifdef CID(sha256_hex)

// f: bytes (hex). Answers their SHA-256 (hex), or "" if not hex.
Term sha256_hex_run(Env e, Term *f, IoWork *w) {
  (void)w;
  uint8_t buf[4096], out[32];
  int32_t n = app_unhex(e, f[0], buf, sizeof buf);
  if (n < 0) return io_str(e, "", 0);
  auth_sha256(buf, (uint32_t)n, out);
  return app_hex(e, out, 32);
}

static void __attribute__((constructor)) sha256_hex_use(void) {
  io_eff(CID(sha256_hex), sha256_hex_run, 0);
}

#endif

#ifdef CID(random_hex)

// f: n (1..64). Answers n random bytes as hex.
Term random_hex_run(Env e, Term *f, IoWork *w) {
  (void)w;
  uint32_t n = (uint32_t)f[0];
  uint8_t buf[64];
  if (n == 0u || n > 64u || getrandom(buf, n, 0) != (ssize_t)n) return io_str(e, "", 0);
  return app_hex(e, buf, n);
}

static void __attribute__((constructor)) random_hex_use(void) {
  io_eff(CID(random_hex), random_hex_run, 0);
}

#endif

#ifdef CID(auth_register_raw)

// f: token, challenge, id, x, y (hex), count. Answers a session token (hex)
// or fails with the AuthResult code.
Term auth_register_raw_run(Env e, Term *f, IoWork *w) {
  (void)w;
  ASSERT(app_db_ready);
  uint8_t th[32], ch[32], chh[32], id[CRED_ID_MAX], x[32], y[32];
  app_token_hash(e, f[0], th);
  int32_t cn = app_unhex(e, f[1], ch, 32), idn = app_unhex(e, f[2], id, sizeof id);
  int32_t xn = app_unhex(e, f[3], x, 32), yn = app_unhex(e, f[4], y, 32);
  if (cn != 32 || idn <= 0 || xn != 32 || yn != 32) return io_fail(e, AUTH_INVALID, NULL);
  auth_sha256(ch, 32, chh);
  uint32_t user = 0;
  uint8_t session[32], hex[64];
  AuthResult r = auth_register(&app_db, th, chh, id, (uint32_t)idn, x, y, (uint32_t)f[5], app_now_ms(), &user, session);
  if (r != AUTH_OK) return io_fail(e, (uint32_t)r, NULL);
  token_encode(session, hex);
  explicit_bzero(session, sizeof session);
  Term s = io_str(e, (const char *)hex, 64);
  explicit_bzero(hex, sizeof hex);
  return io_done(e, s);
}

static void __attribute__((constructor)) auth_register_raw_use(void) {
  io_eff(CID(auth_register_raw), auth_register_raw_run, 0);
}

#endif

#ifdef CID(auth_login_raw)

// f: challenge, id, msg (authenticator data || SHA-256(clientDataJSON)),
// sig (all hex). Answers a session token (hex) or fails with the code.
Term auth_login_raw_run(Env e, Term *f, IoWork *w) {
  (void)w;
  ASSERT(app_db_ready);
  uint8_t ch[32], chh[32], id[CRED_ID_MAX], msg[4096], sig[80];
  int32_t cn = app_unhex(e, f[0], ch, 32), idn = app_unhex(e, f[1], id, sizeof id);
  int32_t mn = app_unhex(e, f[2], msg, sizeof msg), sn = app_unhex(e, f[3], sig, sizeof sig);
  if (cn != 32 || idn <= 0 || mn < 0 || sn <= 0) return io_fail(e, AUTH_INVALID, NULL);
  auth_sha256(ch, 32, chh);
  uint32_t user = 0;
  uint8_t session[32], hex[64];
  AuthResult r = auth_login(&app_db, chh, id, (uint32_t)idn, msg, (uint32_t)mn, sig, (uint32_t)sn, app_now_ms(), &user, session);
  if (r != AUTH_OK) return io_fail(e, (uint32_t)r, NULL);
  token_encode(session, hex);
  explicit_bzero(session, sizeof session);
  Term s = io_str(e, (const char *)hex, 64);
  explicit_bzero(hex, sizeof hex);
  return io_done(e, s);
}

static void __attribute__((constructor)) auth_login_raw_use(void) {
  io_eff(CID(auth_login_raw), auth_login_raw_run, 0);
}

#endif

#ifdef CID(auth_signup_direct)

// f: email, name, origin. Answers the sign-up token (hex), or fails with
// the AuthResult code. Only used when BLOG_SIGNUP_DIRECT=1.
Term auth_signup_direct_run(Env e, Term *f, IoWork *w) {
  (void)w;
  ASSERT(app_db_ready);
  u64 n1 = 0, n2 = 0, n3 = 0;
  char *email = io_cstr(e, f[0], &n1), *name = io_cstr(e, f[1], &n2), *origin = io_cstr(e, f[2], &n3);
  uint8_t hex[64];
  AuthResult r = AUTH_INVALID;
  if (n1 <= 254u && n2 <= 64u && n3 <= 200u) {
    r = auth_signup_direct(&app_db, (DbText){email, (uint32_t)n1}, (DbText){name, (uint32_t)n2},
                           (DbText){origin, (uint32_t)n3}, app_now_ms(), hex);
  }
  free(email);
  free(name);
  free(origin);
  if (r != AUTH_OK) return io_fail(e, (uint32_t)r, NULL);
  Term s = io_str(e, (const char *)hex, 64);
  explicit_bzero(hex, sizeof hex);
  return io_done(e, s);
}

static void __attribute__((constructor)) auth_signup_direct_use(void) {
  io_eff(CID(auth_signup_direct), auth_signup_direct_run, 0);
}

#endif
