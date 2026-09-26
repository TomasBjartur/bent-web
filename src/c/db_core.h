// CORE: the database. Plain C over SQLite (no Bend), testable standalone.
// WHY C:  SQLite; and the fact re-check that makes Bend's authorization
//         proofs hold against the real database (see db_apply).
// LAWS THAT DEPEND ON THIS: authz_permit_ok says a Permit's action is
//         allowed *given its facts*. db_apply makes those facts true at
//         write time: every fact is re-read inside the write transaction,
//         and any mismatch aborts (DB_STALE).
// VERIFIED BY: tests/c/db_core_test.c (unit, incl. stale-fact and forged-
//         fact cases, under ASan+UBSan); schema constraints and triggers
//         (src/db/schema.sql) as a floor.
#ifndef BLOG_DB_CORE_H
#define BLOG_DB_CORE_H

#include <stdint.h>

#include "../../vendor/sqlite/sqlite3.h"

// Roles, matching spec/authz.bend and the member.role column.
#define ROLE_NONE 0u
#define ROLE_OWNER 1u
#define ROLE_AUTHOR 2u

// Actions: the kinds src/db.bend's act_of gives spec/authz.bend's Actions.
enum {
  A_CREATE_BLOG = 0,
  A_EDIT_BLOG,
  A_DELETE_BLOG,
  A_ADD_AUTHOR,
  A_REMOVE_AUTHOR,
  A_CREATE_POST,
  A_EDIT_POST,
  A_PUBLISH_POST,
  A_DELETE_POST,
  A_SYNC_OPS,  // not a policy action: EditPost's facts, used by db_sync
  A_LIKE_POST,       // target = post, flag = 1 like, 0 unlike
  A_COMMENT,         // target = post, flag = parent comment (0: none), body_md/html
  A_DELETE_COMMENT,  // target = comment, user = its author (checked in SQL)
  A_UPLOAD_IMAGE,    // not through db_apply: see db_upload
  A_KINDS
};

typedef enum {
  DB_OK = 0,
  DB_STALE = 1,     // a fact is not (or no longer) true: re-load and retry
  DB_DENIED = 2,    // the floor check failed (should be unreachable)
  DB_CONFLICT = 3,  // a constraint failed (e.g. duplicate slug)
  DB_ERROR = 4,     // SQLite error
} DbResult;

// The facts a decision was made on (spec/authz.bend: Facts, flattened).
typedef struct {
  uint32_t who;        // user id, 0 = anonymous
  uint32_t blog;       // the blog the request is about, 0 = none
  uint32_t role;       // who's role in blog: ROLE_*
  uint32_t has_post;   // 1 if the request is about a post
  uint32_t post;
  uint32_t post_blog;
  uint32_t post_pub;   // 0 or 1
} DbFacts;

typedef struct {
  const char *ptr;
  uint32_t len;
} DbText;

// A write (spec/authz.bend: Action, flattened, plus its data).
typedef struct {
  uint32_t kind;     // A_*
  uint32_t target;   // blog id (blog actions) or post id (post actions)
  uint32_t user;     // A_ADD_AUTHOR, A_REMOVE_AUTHOR
  uint32_t flag;     // A_PUBLISH_POST: 1 publish, 0 unpublish, 2 schedule (user =
                     // minutes since 1970, slug = the address), 3 cancel the schedule
  DbText slug;       // A_CREATE_BLOG, A_CREATE_POST; A_PUBLISH_POST: the address
                     // for a never-published draft (see db_publish_rename);
                     // A_EDIT_POST with flag 1: the tags, "a,b,c" (see db_set_tags)
  DbText title;      // A_CREATE_BLOG, A_EDIT_BLOG, A_CREATE_POST, A_EDIT_POST;
                     // A_EDIT_BLOG flag 1 (set) and 2 (verified): the custom domain,
                     // with slug = its verification token; flag 3 removes it
  DbText body_md;    // A_EDIT_POST
  DbText body_html;  // A_EDIT_POST
} DbWrite;

// Read queries. Each has fixed SQL. Any query that can return private data
// (drafts, membership) includes a floor in SQL: the session token hash must
// belong to a member of the blog. Parameters: a, b (integers), text, and
// the caller's session token hash.
enum {
  Q_BLOG_BY_SLUG = 0,   // text=slug -> id, title, slug, owner name
  Q_POST_ID,            // a=blog, text=slug -> id  (any state; callers answer 404 unless allowed)
  Q_POSTS_PUBLIC,       // a=blog -> slug, title, author, date, excerpt, minutes, author_id, rfc822 date
                        //    (published only)
  Q_RECENT_PUBLIC,      // -> blog_slug, post_slug, title, blog_title, author, date, excerpt, minutes, author_id,
                        //    rfc822 date  (published only)
  Q_POST_VIEW,          // a=post -> slug, title, published, blog_slug, blog_title, author, date, minutes,
                        //    author_id  (published, or member)
  Q_MY_BLOGS,           // -> id, slug, title, role, published count, draft count  (the session's user)
  Q_POSTS_MEMBER,       // a=blog -> id, slug, title, published, date, author, scheduled date or ''
                        //    (member only)
  Q_POST_MD,            // a=post -> body_md, title, published, blog_slug, post_slug, scheduled
                        //    ("YYYY-MM-DDTHH:MMZ" or '')  (member only)
  Q_USER_BY_EMAIL,      // text=email -> id
  Q_AUTHORS,            // a=blog -> user_id, name, email, role  (member only)
  Q_OPS,                // a=post -> ops as one wire text  (member only)
  Q_OP_COUNT,           // a=post -> number of ops  (member only)
  Q_AUTHOR_PUBLIC,      // a=user -> name  (only if they have a published post)
  Q_POSTS_BY_AUTHOR,    // a=user -> as Q_RECENT_PUBLIC  (published only)
  Q_SEARCH,             // text=FTS5 query -> as Q_RECENT_PUBLIC, excerpt = marked snippet, no rfc822
  Q_POST_SOCIAL,        // a=post -> likes, liked by the session's user (0/1), comments  (published, or member)
  Q_COMMENTS,           // a=post -> id, depth, author_id, author, date, deleted, mine (0/1), parent
                        //    in thread order (published, or member)
  Q_COMMENT_INFO,       // a=comment -> post_id, author_id, author, date, deleted  (published, or member)
  Q_POST_TAGS,          // a=post -> tag  (published, or member)
  Q_POSTS_BY_TAG,       // text=tag -> as Q_RECENT_PUBLIC  (published only)
  Q_BLOG_DOMAIN,        // a=blog -> domain, token, verified (0/1)  (member only)
  Q_BLOG_BY_DOMAIN,     // text=host -> slug  (verified domains only)
  Q_COUNT
};

#define DB_ROWS_MAX 300u

// COMMENTS: at most COMMENT_RATE_MAX per user per window (else DB_CONFLICT),
// and POST_COMMENTS_MAX per post.
#define COMMENT_RATE_MAX 5u
#define COMMENT_RATE_WINDOW_MS 60000ull
#define POST_COMMENTS_MAX 5000u

// IMAGES: JPEG, PNG, GIF or WebP (by their first bytes), at most
// IMG_BYTES_MAX each, IMG_PER_POST_MAX per post, IMG_RATE_MAX per user per
// IMG_RATE_WINDOW_MS. Keys: 16 random bytes as 32 lowercase hex digits.
#define IMG_BYTES_MAX (1024u * 1024u)
#define IMG_PER_POST_MAX 300u
#define IMG_RATE_MAX 60u
#define IMG_RATE_WINDOW_MS 600000ull
#define IMG_KEY_BYTES 16u

// TAGS: at most TAGS_MAX per post, each 1..TAG_BYTES_MAX of a-z 0-9 '-'.
#define TAGS_MAX 5u
#define TAG_BYTES_MAX 32u
#define DB_COLS_MAX 10u

// Called once per row; cols[i] is UTF-8 text of length lens[i].
typedef void (*DbRowFn)(void *ctx, uint32_t ncols, const char *const *cols, const uint32_t *lens);
typedef void (*DbOutFn)(void *ctx, const char *p, uint32_t n);

enum {
  ST_BEGIN = 0, ST_COMMIT, ST_ROLLBACK,
  ST_SESSION_USER, ST_SESSION_NEW, ST_ROLE, ST_POST_FACTS,
  ST_USER_NEW, ST_USER_BY_EMAIL,
  ST_BLOG_NEW, ST_MEMBER_NEW, ST_BLOG_TITLE, ST_BLOG_DELETE, ST_MEMBER_DELETE,
  ST_POST_NEW, ST_POST_EDIT, ST_POST_PUBLISH, ST_POST_DELETE, ST_BODY, ST_SESSION_DELETE,
  ST_TOKEN_RECENT, ST_TOKEN_NEW, ST_TOKEN_GET, ST_TOKEN_USE, ST_OUTBOX_NEW, ST_USER_ID_BY_EMAIL,
  ST_CHAL_NEW, ST_CHAL_USE, ST_CRED_GET, ST_CRED_NEW, ST_CRED_COUNT,
  ST_OP_NEW, ST_OP_SINCE, ST_OP_COUNT, ST_SLUG_TAKEN, ST_POST_RENAME,
  ST_DOMAIN_SET, ST_DOMAIN_TAKE, ST_DOMAIN_OK, ST_DOMAIN_CLEAR, ST_IMG_POST_COUNT, ST_IMG_RECENT, ST_IMG_NEW, ST_IMG_GET, ST_TAGS_CLEAR, ST_TAG_ADD, ST_SCHEDULE, ST_UNSCHEDULE, ST_DUE, ST_PUBLISH_DUE, ST_LIKE_ADD, ST_LIKE_DEL, ST_COMMENT_RECENT, ST_COMMENT_COUNT, ST_COMMENT_NEW, ST_COMMENT_DEL, ST_COMMENT_BODY,
  ST_COUNT
};

typedef struct {
  sqlite3 *conn;
  sqlite3_stmt *st[ST_COUNT];
  sqlite3_stmt *q[Q_COUNT];
} Db;

// Runs read query q. Returns the number of rows (at most DB_ROWS_MAX), or
// -1 on error.
int32_t db_query(Db *db, uint32_t q, uint32_t a, uint32_t b, DbText text,
                 const uint8_t token_hash[32], uint64_t now_ms, DbRowFn fn, void *ctx);

// The stored HTML body of post, if published or if the session's user is a
// member of its blog (the floor): passed to out, then the statement is
// reset (a statement left stepping holds a read snapshot: other processes'
// writes then make every write here fail, and checkpoints cannot finish).
// Returns 1 if the body was passed, 0 if not allowed or absent, -1 on error.
int32_t db_body(Db *db, uint32_t post, const uint8_t token_hash[32], uint64_t now_ms,
                DbOutFn out, void *ctx);

// The same for a comment's stored HTML (not deleted; its post published or
// the session a member of the post's blog).
// The image type for these bytes, or NULL if not an accepted image.
const char *db_image_type(const uint8_t *p, uint32_t n);

// Stores an image for a post, as a write: the floor (a member of the post's
// blog), then in one IMMEDIATE transaction the facts are re-checked, the
// quotas, and the type. key: IMG_KEY_BYTES random bytes (the caller's);
// key_hex gets the key as 32 hex digits and a NUL.
DbResult db_upload(Db *db, const uint8_t token_hash[32], uint64_t now_ms, const DbFacts *f, uint32_t post,
                   const uint8_t *bytes, uint32_t n, const uint8_t key[IMG_KEY_BYTES], char key_hex[2u * IMG_KEY_BYTES + 1u]);

// An image by its key (32 hex digits): passes type and bytes to out.
// Returns 1 if found, 0 if not, -1 on error.
typedef void (*DbImageFn)(void *ctx, const char *type, const uint8_t *p, uint32_t n);
int32_t db_image(Db *db, const char *key_hex, uint32_t key_len, DbImageFn out, void *ctx);

// Publishes scheduled posts that are due (at most DUE_BATCH_MAX a call),
// each in its own IMMEDIATE transaction. Returns how many, or -1.
#define DUE_BATCH_MAX 20u
int32_t db_publish_due(Db *db, uint64_t now_ms);

int32_t db_comment_body(Db *db, uint32_t comment, const uint8_t token_hash[32], uint64_t now_ms,
                        DbOutFn out, void *ctx);

// Opens (creating if needed) the database at path and prepares every
// statement. Returns 0 on success.
int32_t db_open(Db *db, const char *path);
void db_close(Db *db);

// The user a session token hash belongs to, if unexpired; 0 otherwise.
uint32_t db_session_user(Db *db, const uint8_t token_hash[32], uint64_t now_ms);

// Creates a session for user, returning its raw token in token_out (the
// database stores only its hash). Returns 0 on success.
int32_t db_session_new(Db *db, uint32_t user, uint64_t now_ms, uint64_t ttl_ms, uint8_t token_out[32]);

// Deletes the session with this token hash (logout). Returns 0 on success.
int32_t db_session_end(Db *db, const uint8_t token_hash[32]);

// Loads facts for (who, blog, post). post 0 means no post; blog 0 with a
// post means "the post's blog".
DbResult db_load_facts(Db *db, uint32_t who, uint32_t blog, uint32_t post, DbFacts *out);

// Re-checks every fact against the database inside one IMMEDIATE
// transaction, applies a minimal policy floor, performs the write, commits.
// new_id receives the id of a created blog or post.
DbResult db_apply(Db *db, const uint8_t token_hash[32], uint64_t now_ms,
                  const DbFacts *facts, const DbWrite *w, uint32_t *new_id);

// Creates a user (sign-up); returns the id or 0 on failure.
uint32_t db_user_new(Db *db, DbText email, DbText name, uint64_t now_ms);

// COLLABORATIVE EDITING
// ---------------------

#define SYNC_OPS_MAX 20000u         // operations per request
#define POST_OPS_MAX 4000000u       // operations per post
#define SYNC_OUT_MAX (8u * 1024u * 1024u)


// Syncs a post's operations in one IMMEDIATE transaction: re-checks the
// facts as for an edit (the session's user is a member of the post's
// blog), inserts `ops` (wire format "c.r.k.pc.pr.s.ch;" repeated; checked
// for syntax and ranges here, for meaning in Bend), then writes
// "<max seq>\n" and every operation with seq > since, in seq order, to out.
DbResult db_sync(Db *db, const uint8_t token_hash[32], uint64_t now_ms, const DbFacts *facts,
                 uint32_t post, const char *ops, uint32_t ops_len, uint64_t since, DbOutFn out, void *ctx);


// AUTHENTICATION
// --------------

typedef enum {
  AUTH_OK = 0,
  AUTH_INVALID = 1,      // token/challenge unknown, used or expired
  AUTH_RATE_LIMITED = 2,
  AUTH_EMAIL_TAKEN = 3,
  AUTH_COUNTER = 4,      // signature counter did not advance (cloned key?)
  AUTH_ERROR = 5,
} AuthResult;

#define AUTH_SIGNUP 1u
#define AUTH_RECOVER 2u
#define CHAL_REGISTER 1u
#define CHAL_LOGIN 2u
#define EMAIL_TOKEN_TTL_MS (30ull * 60ull * 1000ull)
#define CHALLENGE_TTL_MS (5ull * 60ull * 1000ull)
#define EMAIL_TOKENS_PER_HOUR 3u
#define CRED_ID_MAX 1023u

// Issues an emailed link: for AUTH_SIGNUP, email and name of the account to
// create (fails AUTH_EMAIL_TAKEN if registered); for AUTH_RECOVER, the
// account with that email, if any. Writes the token and an outbox row with
// the link `origin`/verify?t=<token> in one transaction. For AUTH_RECOVER
// with no such account nothing is written and AUTH_OK is returned (no
// account enumeration). At most EMAIL_TOKENS_PER_HOUR per email.
AuthResult auth_email_token(Db *db, uint32_t purpose, DbText email, DbText name, DbText origin, uint64_t now_ms);

// As auth_email_token for AUTH_SIGNUP, and also writes the token (64 hex
// characters) to token_hex: for test deployments with no mail sender
// (BLOG_SIGNUP_DIRECT), where sign-up continues straight to the passkey.
AuthResult auth_signup_direct(Db *db, DbText email, DbText name, DbText origin, uint64_t now_ms, uint8_t token_hex[64]);

// Whether an email token is valid (unused, unexpired); fills purpose.
AuthResult auth_token_check(Db *db, const uint8_t token_hash[32], uint64_t now_ms, uint32_t *purpose);

// A valid email token's purpose, email and name (NUL-terminated).
AuthResult auth_token_info(Db *db, const uint8_t token_hash[32], uint64_t now_ms, uint32_t *purpose,
                           char email[256], char name[128]);

// A new challenge. For CHAL_REGISTER it is bound to an email token, which
// must be valid. Writes the raw challenge to out.
AuthResult auth_challenge(Db *db, uint32_t purpose, const uint8_t *token_hash, uint64_t now_ms, uint8_t out[32]);

// Looks up a credential by id: its owner, public key and counter.
AuthResult auth_credential(Db *db, const uint8_t *id, uint32_t id_len, uint32_t *user,
                           uint8_t x[32], uint8_t y[32], uint32_t *count);

// Completes a registration in one transaction: consumes the email token and
// its bound challenge, creates the user (sign-up) or uses the account
// (recovery), stores the credential, and creates a session.
AuthResult auth_register(Db *db, const uint8_t token_hash[32], const uint8_t challenge_hash[32],
                         const uint8_t *id, uint32_t id_len, const uint8_t x[32], const uint8_t y[32],
                         uint32_t count, uint64_t now_ms, uint32_t *user, uint8_t session[32]);

// Completes a login in one transaction: consumes the login challenge,
// re-verifies the signature over msg (authenticator data followed by the
// SHA-256 of clientDataJSON) with the public key stored for this
// credential, advances the credential's counter to the one inside the
// signed authenticator data (it must increase, or stay 0 for authenticators
// without counters), and creates a session.
AuthResult auth_login(Db *db, const uint8_t challenge_hash[32], const uint8_t *id, uint32_t id_len,
                      const uint8_t *msg, uint32_t msg_len, const uint8_t *sig, uint32_t sig_len,
                      uint64_t now_ms, uint32_t *user, uint8_t session[32]);

// SHA-256 (BearSSL).
void auth_sha256(const uint8_t *p, uint32_t n, uint8_t out[32]);

// ECDSA P-256 / SHA-256 verification of an ASN.1 (DER) signature over msg,
// with public key (x, y). Returns 1 if valid. Uses BearSSL's portable m31
// curve implementation.
int32_t auth_p256_verify(const uint8_t x[32], const uint8_t y[32], const uint8_t *msg, uint32_t msg_len,
                         const uint8_t *sig, uint32_t sig_len);

// SHA-256 of a raw session token (BearSSL).
void db_token_hash(const uint8_t token[32], uint8_t out[32]);

#endif
