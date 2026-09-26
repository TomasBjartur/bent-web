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

// Actions, matching spec/authz.bend's Action constructors in order.
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
  uint32_t flag;     // A_PUBLISH_POST: 1 publish, 0 unpublish
  DbText slug;       // A_CREATE_BLOG, A_CREATE_POST
  DbText title;      // A_CREATE_BLOG, A_EDIT_BLOG, A_CREATE_POST, A_EDIT_POST
  DbText body_md;    // A_EDIT_POST
  DbText body_html;  // A_EDIT_POST
} DbWrite;

// Read queries. Each has fixed SQL. Any query that can return private data
// (drafts, membership) includes a floor in SQL: the session token hash must
// belong to a member of the blog. Parameters: a, b (integers), text, and
// the caller's session token hash.
enum {
  Q_BLOG_BY_SLUG = 0,   // text=slug -> id, title, slug
  Q_POST_ID,            // a=blog, text=slug -> id  (any state; callers answer 404 unless allowed)
  Q_POSTS_PUBLIC,       // a=blog -> id, slug, title, updated_ms  (published only)
  Q_RECENT_PUBLIC,      // -> blog_slug, post_slug, post_title, blog_title  (published only)
  Q_POST_VIEW,          // a=post -> slug, title, published, blog_slug, blog_title  (published, or member)
  Q_MY_BLOGS,           // -> id, slug, title, role  (the session's user)
  Q_POSTS_MEMBER,       // a=blog -> id, slug, title, published, updated_ms  (member only)
  Q_POST_MD,            // a=post -> body_md, title  (member only)
  Q_USER_BY_EMAIL,      // text=email -> id
  Q_AUTHORS,            // a=blog -> user_id, name, email, role  (member only)
  Q_COUNT
};

#define DB_ROWS_MAX 100u
#define DB_COLS_MAX 8u

// Called once per row; cols[i] is UTF-8 text of length lens[i].
typedef void (*DbRowFn)(void *ctx, uint32_t ncols, const char *const *cols, const uint32_t *lens);

enum {
  ST_BEGIN = 0, ST_COMMIT, ST_ROLLBACK,
  ST_SESSION_USER, ST_SESSION_NEW, ST_ROLE, ST_POST_FACTS,
  ST_USER_NEW, ST_USER_BY_EMAIL,
  ST_BLOG_NEW, ST_MEMBER_NEW, ST_BLOG_TITLE, ST_BLOG_DELETE, ST_MEMBER_DELETE,
  ST_POST_NEW, ST_POST_EDIT, ST_POST_PUBLISH, ST_POST_DELETE, ST_BODY, ST_SESSION_DELETE,
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
// member of its blog (the floor). Returns 1 and sets *html/*len (valid until
// the next call), 0 if not allowed or absent, -1 on error.
int32_t db_body(Db *db, uint32_t post, const uint8_t token_hash[32], uint64_t now_ms,
                const char **html, uint32_t *len);

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

// SHA-256 of a raw session token (BearSSL).
void db_token_hash(const uint8_t token[32], uint8_t out[32]);

#endif
