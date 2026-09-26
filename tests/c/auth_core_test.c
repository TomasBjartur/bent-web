// Tests for the authentication part of src/c/db_core.c: email tokens,
// challenges, registration and login transactions, and P-256 verification
// against real BearSSL signatures.
#include <stdio.h>
#include <string.h>
#include <sys/random.h>
#include <unistd.h>

#include "../../src/c/db_core.h"
#include "../../src/c/token_core.h"
#include "../../vendor/bearssl/inc/bearssl.h"

static int fails = 0;
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #x); fails++; } } while (0)
#define T(s) ((DbText){(s), (uint32_t)strlen(s)})

static Db db;
static const uint64_t NOW = 1700000000000ull;
static const DbText ORIGIN = {"https://blog.example", 20};

// The token in the newest outbox mail to email, via its link.
static int latest_token(const char *email, uint8_t hash[32]) {
  sqlite3_stmt *st;
  sqlite3_prepare_v2(db.conn, "SELECT body FROM outbox WHERE to_email = ?1 ORDER BY id DESC LIMIT 1", -1, &st, NULL);
  sqlite3_bind_text(st, 1, email, -1, SQLITE_STATIC);
  int ok = 0;
  if (sqlite3_step(st) == SQLITE_ROW) {
    const char *body = (const char *)sqlite3_column_text(st, 0);
    const char *p = strstr(body, "/verify?t=");
    uint8_t raw[32];
    if (p && token_decode((const uint8_t *)p + 10, 64, raw)) {
      auth_sha256(raw, 32, hash);
      ok = 1;
    }
  }
  sqlite3_finalize(st);
  return ok;
}

static int outbox_count(void) {
  sqlite3_stmt *st;
  sqlite3_prepare_v2(db.conn, "SELECT count(*) FROM outbox", -1, &st, NULL);
  sqlite3_step(st);
  int n = sqlite3_column_int(st, 0);
  sqlite3_finalize(st);
  return n;
}

typedef struct {
  unsigned char sk_buf[BR_EC_KBUF_PRIV_MAX_SIZE], pk_buf[BR_EC_KBUF_PUB_MAX_SIZE];
  br_ec_private_key sk;
  br_ec_public_key pk;
  uint8_t x[32], y[32];
} Key;

static void keygen(Key *k) {
  br_hmac_drbg_context rng;
  uint8_t seed[32];
  if (getrandom(seed, sizeof seed, 0) != (ssize_t)sizeof seed) abort();
  br_hmac_drbg_init(&rng, &br_sha256_vtable, seed, sizeof seed);
  br_ec_keygen(&rng.vtable, &br_ec_p256_m31, &k->sk, k->sk_buf, BR_EC_secp256r1);
  br_ec_compute_pub(&br_ec_p256_m31, &k->pk, k->pk_buf, &k->sk);
  memcpy(k->x, k->pk.q + 1, 32);
  memcpy(k->y, k->pk.q + 33, 32);
}

static size_t sign(Key *k, const uint8_t *msg, size_t n, uint8_t sig[80]) {
  uint8_t h[32];
  auth_sha256(msg, (uint32_t)n, h);
  return br_ecdsa_i31_sign_asn1(&br_ec_p256_m31, &br_sha256_vtable, h, &k->sk, sig);
}

static uint8_t cred_id[20] = "credential-id-000001";

static AuthResult login_with(const uint8_t chh[32], Key *k, uint32_t count, uint64_t when) {
  uint8_t msg[37 + 32];
  memset(msg, 0xab, sizeof msg);
  msg[32] = 0x05;
  msg[33] = (uint8_t)(count >> 24); msg[34] = (uint8_t)(count >> 16);
  msg[35] = (uint8_t)(count >> 8); msg[36] = (uint8_t)count;
  uint8_t sig[80];
  size_t sl = sign(k, msg, sizeof msg, sig);
  uint32_t u = 0;
  uint8_t s[32];
  return auth_login(&db, chh, cred_id, sizeof cred_id, msg, sizeof msg, sig, (uint32_t)sl, when, &u, s);
}

int main(void) {
  const char *path = "/tmp/claude-auth-core-test.db";
  unlink(path);
  if (db_open(&db, path) != 0) {
    fprintf(stderr, "FAIL: db_open\n");
    return 1;
  }

  // Sign-up: token, outbox mail with link, challenge bound to it, register.
  CHECK(auth_email_token(&db, AUTH_SIGNUP, T("ann@x.io"), T("Ann"), ORIGIN, NOW) == AUTH_OK);
  uint8_t tok[32];
  CHECK(latest_token("ann@x.io", tok));
  uint32_t purpose = 0;
  CHECK(auth_token_check(&db, tok, NOW, &purpose) == AUTH_OK && purpose == AUTH_SIGNUP);
  uint8_t chal[32], chal_hash[32];
  CHECK(auth_challenge(&db, CHAL_REGISTER, tok, NOW, chal) == AUTH_OK);
  auth_sha256(chal, 32, chal_hash);
  Key key;
  keygen(&key);
  uint32_t user = 0;
  uint8_t session[32];
  CHECK(auth_register(&db, tok, chal_hash, cred_id, sizeof cred_id, key.x, key.y, 0, NOW, &user, session) == AUTH_OK);
  CHECK(user != 0u);
  uint8_t sh[32];
  db_token_hash(session, sh);
  CHECK(db_session_user(&db, sh, NOW) == user);
  // The token and the challenge are single-use.
  CHECK(auth_register(&db, tok, chal_hash, cred_id, sizeof cred_id, key.x, key.y, 0, NOW, &user, session) == AUTH_INVALID);
  CHECK(auth_token_check(&db, tok, NOW, &purpose) == AUTH_INVALID);

  // Sign-up again with the same email: taken.
  CHECK(auth_email_token(&db, AUTH_SIGNUP, T("ann@x.io"), T("Ann2"), ORIGIN, NOW) == AUTH_EMAIL_TAKEN);
  CHECK(auth_email_token(&db, AUTH_SIGNUP, T("ANN@x.io"), T("Ann3"), ORIGIN, NOW) == AUTH_EMAIL_TAKEN);

  // Recovery for an unknown email: silent, nothing sent.
  int before = outbox_count();
  CHECK(auth_email_token(&db, AUTH_RECOVER, T("nobody@x.io"), T(""), ORIGIN, NOW) == AUTH_OK);
  CHECK(outbox_count() == before);

  // Rate limit: at most 3 mails per email per hour.
  CHECK(auth_email_token(&db, AUTH_RECOVER, T("ann@x.io"), T(""), ORIGIN, NOW) == AUTH_OK);
  CHECK(auth_email_token(&db, AUTH_RECOVER, T("ann@x.io"), T(""), ORIGIN, NOW + 1) == AUTH_OK);
  CHECK(auth_email_token(&db, AUTH_RECOVER, T("ann@x.io"), T(""), ORIGIN, NOW + 2) == AUTH_RATE_LIMITED);
  CHECK(auth_email_token(&db, AUTH_RECOVER, T("ann@x.io"), T(""), ORIGIN, NOW + 3700000) == AUTH_OK);

  // An origin that could inject into the mail is refused.
  CHECK(auth_email_token(&db, AUTH_SIGNUP, T("bo@x.io"), T("Bo"), T("https://x\n\nClick evil"), NOW) == AUTH_INVALID);

  // Challenge binding: a register challenge for token A cannot complete token B.
  CHECK(auth_email_token(&db, AUTH_SIGNUP, T("cy@x.io"), T("Cy"), ORIGIN, NOW) == AUTH_OK);
  uint8_t tok_c[32];
  CHECK(latest_token("cy@x.io", tok_c));
  CHECK(auth_email_token(&db, AUTH_SIGNUP, T("di@x.io"), T("Di"), ORIGIN, NOW) == AUTH_OK);
  uint8_t tok_d[32];
  CHECK(latest_token("di@x.io", tok_d));
  uint8_t chal_c[32], chal_c_hash[32];
  CHECK(auth_challenge(&db, CHAL_REGISTER, tok_c, NOW, chal_c) == AUTH_OK);
  auth_sha256(chal_c, 32, chal_c_hash);
  uint8_t cred_d[20] = "credential-id-00000d";
  CHECK(auth_register(&db, tok_d, chal_c_hash, cred_d, sizeof cred_d, key.x, key.y, 0, NOW, &user, session) == AUTH_INVALID);
  // An expired token cannot be used.
  CHECK(auth_register(&db, tok_c, chal_c_hash, cred_d, sizeof cred_d, key.x, key.y, 0, NOW + EMAIL_TOKEN_TTL_MS + 1, &user, session) == AUTH_INVALID);
  // A register challenge needs a valid token.
  uint8_t junk[32] = {1};
  CHECK(auth_challenge(&db, CHAL_REGISTER, junk, NOW, chal) == AUTH_INVALID);

  // Login: signature over authData || sha256(clientData) verifies.
  uint8_t msg[64] = "authenticator-data-37-bytes-........";
  uint8_t sig[80];
  size_t sl = sign(&key, msg, sizeof msg, sig);
  CHECK(sl > 0);
  uint32_t cu = 0, cnt = 99;
  uint8_t cx[32], cy[32];
  CHECK(auth_credential(&db, cred_id, sizeof cred_id, &cu, cx, cy, &cnt) == AUTH_OK && cnt == 0u);
  CHECK(auth_p256_verify(cx, cy, msg, sizeof msg, sig, (uint32_t)sl) == 1);
  msg[3] ^= 1;
  CHECK(auth_p256_verify(cx, cy, msg, sizeof msg, sig, (uint32_t)sl) == 0);
  msg[3] ^= 1;
  sig[sl - 1] ^= 1;
  CHECK(auth_p256_verify(cx, cy, msg, sizeof msg, sig, (uint32_t)sl) == 0);
  sig[sl - 1] ^= 1;
  CHECK(auth_p256_verify(cx, cy, msg, sizeof msg, sig, (uint32_t)sl - 1) == 0);
  CHECK(auth_p256_verify(cx, cy, msg, sizeof msg, sig, 0) == 0);
  Key other;
  keygen(&other);
  CHECK(auth_p256_verify(other.x, other.y, msg, sizeof msg, sig, (uint32_t)sl) == 0);
  uint8_t bad_y[32];
  memcpy(bad_y, cy, 32);
  bad_y[31] ^= 1;
  CHECK(auth_p256_verify(cx, bad_y, msg, sizeof msg, sig, (uint32_t)sl) == 0);

  // Login transactions: msg is authenticator data (count at bytes 33..36)
  // followed by a 32-byte clientData hash, signed by the credential's key.
  #define LOGIN(chh, key_, cnt_, when) login_with(chh, &(key_), cnt_, when)
  uint8_t lc[32], lch[32];
  CHECK(auth_challenge(&db, CHAL_LOGIN, NULL, NOW, lc) == AUTH_OK);
  auth_sha256(lc, 32, lch);
  CHECK(LOGIN(lch, key, 5, NOW) == AUTH_OK);
  CHECK(LOGIN(lch, key, 6, NOW) == AUTH_INVALID);  // replay
  CHECK(auth_challenge(&db, CHAL_LOGIN, NULL, NOW, lc) == AUTH_OK);
  auth_sha256(lc, 32, lch);
  CHECK(LOGIN(lch, key, 5, NOW) == AUTH_COUNTER);  // not increasing
  CHECK(auth_challenge(&db, CHAL_LOGIN, NULL, NOW, lc) == AUTH_OK);
  auth_sha256(lc, 32, lch);
  CHECK(LOGIN(lch, key, 0, NOW) == AUTH_COUNTER);  // reset to 0
  CHECK(auth_challenge(&db, CHAL_LOGIN, NULL, NOW, lc) == AUTH_OK);
  auth_sha256(lc, 32, lch);
  CHECK(LOGIN(lch, key, 7, NOW + CHALLENGE_TTL_MS + 1) == AUTH_INVALID);  // expired
  // A register challenge cannot log in.
  CHECK(LOGIN(chal_c_hash, key, 9, NOW) == AUTH_INVALID);
  // Signed by another key (e.g. an attacker's), for this credential id.
  CHECK(auth_challenge(&db, CHAL_LOGIN, NULL, NOW, lc) == AUTH_OK);
  auth_sha256(lc, 32, lch);
  CHECK(LOGIN(lch, other, 9, NOW) == AUTH_INVALID);
  // The failed login rolled back: its challenge is still unused.
  CHECK(LOGIN(lch, key, 9, NOW) == AUTH_OK);

  // Recovery: a new passkey for the existing account.
  CHECK(auth_email_token(&db, AUTH_RECOVER, T("ann@x.io"), T(""), ORIGIN, NOW + 3700001) == AUTH_OK);
  uint8_t tok_r[32];
  CHECK(latest_token("ann@x.io", tok_r));
  CHECK(auth_token_check(&db, tok_r, NOW + 3700001, &purpose) == AUTH_OK && purpose == AUTH_RECOVER);
  CHECK(auth_challenge(&db, CHAL_REGISTER, tok_r, NOW + 3700001, chal) == AUTH_OK);
  auth_sha256(chal, 32, chal_hash);
  Key k2;
  keygen(&k2);
  uint8_t cred_r[20] = "credential-id-00000r";
  uint32_t ruser = 0;
  CHECK(auth_register(&db, tok_r, chal_hash, cred_r, sizeof cred_r, k2.x, k2.y, 0, NOW + 3700001, &ruser, session) == AUTH_OK);
  CHECK(ruser == cu);
  // A duplicate credential id is refused.
  CHECK(auth_email_token(&db, AUTH_SIGNUP, T("ed@x.io"), T("Ed"), ORIGIN, NOW) == AUTH_OK);
  uint8_t tok_e[32];
  CHECK(latest_token("ed@x.io", tok_e));
  CHECK(auth_challenge(&db, CHAL_REGISTER, tok_e, NOW, chal) == AUTH_OK);
  auth_sha256(chal, 32, chal_hash);
  CHECK(auth_register(&db, tok_e, chal_hash, cred_id, sizeof cred_id, k2.x, k2.y, 0, NOW, &user, session) == AUTH_INVALID);

  db_close(&db);
  unlink(path);
  if (fails == 0) printf("auth_core_test: all passed\n");
  return fails != 0;
}
