// CORE: the database. See db_core.h for the contract.
#include "db_core.h"

#include <errno.h>
#include <string.h>
#include <sys/random.h>

#include "../../vendor/bearssl/inc/bearssl_hash.h"
#include "assert.h"

// The schema, embedded at build time from src/db/schema.sql.
static const char DB_SCHEMA[] = {
#embed "../db/schema.sql"
  , 0
};

static const char *const DB_SQL[ST_COUNT] = {
  [ST_BEGIN] = "BEGIN IMMEDIATE",
  [ST_COMMIT] = "COMMIT",
  [ST_ROLLBACK] = "ROLLBACK",
  [ST_SESSION_USER] = "SELECT user_id FROM session WHERE token_hash = ?1 AND expires_ms > ?2",
  [ST_SESSION_NEW] = "INSERT INTO session(token_hash, user_id, created_ms, expires_ms) VALUES (?1, ?2, ?3, ?4)",
  [ST_ROLE] = "SELECT role FROM member WHERE blog_id = ?1 AND user_id = ?2",
  [ST_POST_FACTS] = "SELECT blog_id, published FROM post WHERE id = ?1",
  [ST_USER_NEW] = "INSERT INTO user(email, name, created_ms) VALUES (?1, ?2, ?3)",
  [ST_USER_BY_EMAIL] = "SELECT id FROM user WHERE email = ?1",
  [ST_BLOG_NEW] = "INSERT INTO blog(slug, title, owner_id, created_ms) VALUES (?1, ?2, ?3, ?4)",
  [ST_MEMBER_NEW] = "INSERT INTO member(blog_id, user_id, role) VALUES (?1, ?2, ?3)",
  [ST_BLOG_TITLE] = "UPDATE blog SET title = ?2 WHERE id = ?1",
  [ST_BLOG_DELETE] = "DELETE FROM blog WHERE id = ?1",
  [ST_MEMBER_DELETE] = "DELETE FROM member WHERE blog_id = ?1 AND user_id = ?2 AND role = 2",
  [ST_POST_NEW] = ("INSERT INTO post(blog_id, slug, title, body_md, body_html, published, created_ms, updated_ms) "
                   "VALUES (?1, ?2, ?3, '', '', 0, ?4, ?4)"),
  [ST_POST_EDIT] = "UPDATE post SET title = ?2, body_md = ?3, body_html = ?4, updated_ms = ?5 WHERE id = ?1",
  [ST_POST_PUBLISH] = "UPDATE post SET published = ?2, updated_ms = ?3 WHERE id = ?1",
  [ST_POST_DELETE] = "DELETE FROM post WHERE id = ?1",
};

int32_t db_open(Db *db, const char *path) {
  ASSERT(db != NULL && path != NULL);
  memset(db, 0, sizeof *db);
  int rc = sqlite3_open_v2(path, &db->conn, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, NULL);
  if (rc != SQLITE_OK) return -1;
  int on = 1;
  if (sqlite3_db_config(db->conn, SQLITE_DBCONFIG_DEFENSIVE, 1, &on) != SQLITE_OK) return -1;
  if (sqlite3_db_config(db->conn, SQLITE_DBCONFIG_TRUSTED_SCHEMA, 0, NULL) != SQLITE_OK) return -1;
  if (sqlite3_db_config(db->conn, SQLITE_DBCONFIG_ENABLE_FKEY, 1, &on) != SQLITE_OK || on != 1) return -1;
  sqlite3_busy_timeout(db->conn, 2000);
  const char *pragmas =
    "PRAGMA journal_mode = WAL;"
    "PRAGMA synchronous = NORMAL;"
    "PRAGMA foreign_keys = ON;"
    "PRAGMA cell_size_check = ON;";
  if (sqlite3_exec(db->conn, pragmas, NULL, NULL, NULL) != SQLITE_OK) return -1;
  if (sqlite3_exec(db->conn, DB_SCHEMA, NULL, NULL, NULL) != SQLITE_OK) return -1;
  for (uint32_t i = 0; i < ST_COUNT; i++) {
    ASSERT(DB_SQL[i] != NULL);
    if (sqlite3_prepare_v3(db->conn, DB_SQL[i], -1, SQLITE_PREPARE_PERSISTENT, &db->st[i], NULL) != SQLITE_OK) {
      return -1;
    }
  }
  return 0;
}

void db_close(Db *db) {
  for (uint32_t i = 0; i < ST_COUNT; i++) sqlite3_finalize(db->st[i]);
  sqlite3_close(db->conn);
  memset(db, 0, sizeof *db);
}

void db_token_hash(const uint8_t token[32], uint8_t out[32]) {
  br_sha256_context c;
  br_sha256_init(&c);
  br_sha256_update(&c, token, 32);
  br_sha256_out(&c, out);
}

// Runs a statement that returns at most one row with one integer column.
// Returns 1 and sets *out if a row came back, 0 if none, -1 on error.
static int32_t db_one_u32(sqlite3_stmt *st, uint32_t *out) {
  int rc = sqlite3_step(st);
  int32_t r = -1;
  if (rc == SQLITE_ROW) {
    sqlite3_int64 v = sqlite3_column_int64(st, 0);
    if (v >= 0 && v <= (sqlite3_int64)UINT32_MAX) {
      *out = (uint32_t)v;
      r = 1;
    }
  } else if (rc == SQLITE_DONE) {
    r = 0;
  }
  sqlite3_reset(st);
  sqlite3_clear_bindings(st);
  return r;
}

// Runs a statement that returns no rows. Returns SQLITE_DONE on success.
static int db_exec(sqlite3_stmt *st) {
  int rc = sqlite3_step(st);
  sqlite3_reset(st);
  sqlite3_clear_bindings(st);
  return rc;
}

uint32_t db_session_user(Db *db, const uint8_t token_hash[32], uint64_t now_ms) {
  sqlite3_stmt *st = db->st[ST_SESSION_USER];
  sqlite3_bind_blob(st, 1, token_hash, 32, SQLITE_STATIC);
  sqlite3_bind_int64(st, 2, (sqlite3_int64)now_ms);
  uint32_t user = 0;
  if (db_one_u32(st, &user) != 1) return 0;
  return user;
}

int32_t db_session_new(Db *db, uint32_t user, uint64_t now_ms, uint64_t ttl_ms, uint8_t token_out[32]) {
  ASSERT(user != 0u && ttl_ms > 0u);
  if (getrandom(token_out, 32, 0) != 32) return -1;
  uint8_t hash[32];
  db_token_hash(token_out, hash);
  sqlite3_stmt *st = db->st[ST_SESSION_NEW];
  sqlite3_bind_blob(st, 1, hash, 32, SQLITE_TRANSIENT);
  sqlite3_bind_int64(st, 2, user);
  sqlite3_bind_int64(st, 3, (sqlite3_int64)now_ms);
  sqlite3_bind_int64(st, 4, (sqlite3_int64)(now_ms + ttl_ms));
  return db_exec(st) == SQLITE_DONE ? 0 : -1;
}

static uint32_t db_role(Db *db, uint32_t blog, uint32_t user) {
  if (blog == 0u || user == 0u) return ROLE_NONE;
  sqlite3_stmt *st = db->st[ST_ROLE];
  sqlite3_bind_int64(st, 1, blog);
  sqlite3_bind_int64(st, 2, user);
  uint32_t role = ROLE_NONE;
  if (db_one_u32(st, &role) != 1) return ROLE_NONE;
  ASSERT(role == ROLE_OWNER || role == ROLE_AUTHOR);
  return role;
}

// Returns 1 and fills blog/pub if the post exists, 0 if not, -1 on error.
static int32_t db_post_facts(Db *db, uint32_t post, uint32_t *blog, uint32_t *pub) {
  sqlite3_stmt *st = db->st[ST_POST_FACTS];
  sqlite3_bind_int64(st, 1, post);
  int rc = sqlite3_step(st);
  int32_t r = -1;
  if (rc == SQLITE_ROW) {
    *blog = (uint32_t)sqlite3_column_int64(st, 0);
    *pub = (uint32_t)sqlite3_column_int64(st, 1);
    ASSERT(*pub <= 1u);
    r = 1;
  } else if (rc == SQLITE_DONE) {
    r = 0;
  }
  sqlite3_reset(st);
  sqlite3_clear_bindings(st);
  return r;
}

DbResult db_load_facts(Db *db, uint32_t who, uint32_t blog, uint32_t post, DbFacts *out) {
  memset(out, 0, sizeof *out);
  out->who = who;
  if (post != 0u) {
    uint32_t pb = 0, pub = 0;
    int32_t r = db_post_facts(db, post, &pb, &pub);
    if (r < 0) return DB_ERROR;
    if (r == 1) {
      out->has_post = 1;
      out->post = post;
      out->post_blog = pb;
      out->post_pub = pub;
      if (blog == 0u) blog = pb;
    }
  }
  out->blog = blog;
  out->role = db_role(db, blog, who);
  return DB_OK;
}

// Is every fact still true? Called inside the write transaction.
static DbResult db_facts_hold(Db *db, const uint8_t token_hash[32], uint64_t now_ms, const DbFacts *f) {
  if (f->who == 0u) return DB_STALE;
  if (db_session_user(db, token_hash, now_ms) != f->who) return DB_STALE;
  if (db_role(db, f->blog, f->who) != f->role) return DB_STALE;
  if (f->has_post) {
    uint32_t pb = 0, pub = 0;
    int32_t r = db_post_facts(db, f->post, &pb, &pub);
    if (r < 0) return DB_ERROR;
    if (r == 0 || pb != f->post_blog || pub != f->post_pub) return DB_STALE;
  }
  return DB_OK;
}

// The floor: a minimal restatement of spec/authz.bend for writes. It must
// never be what decides (the proved policy does); it is defense in depth
// against a forged or mis-flattened Permit.
static int32_t db_floor(const DbFacts *f, const DbWrite *w) {
  switch (w->kind) {
    case A_CREATE_BLOG:
      return f->who != 0u;
    case A_EDIT_BLOG:
    case A_DELETE_BLOG:
      return w->target == f->blog && f->role == ROLE_OWNER;
    case A_ADD_AUTHOR:
      return w->target == f->blog && f->role == ROLE_OWNER && w->user != 0u;
    case A_REMOVE_AUTHOR:
      return w->target == f->blog && f->role == ROLE_OWNER && w->user != f->who;
    case A_CREATE_POST:
      return w->target == f->blog && f->role != ROLE_NONE;
    case A_EDIT_POST:
    case A_PUBLISH_POST:
    case A_DELETE_POST:
      return f->has_post && w->target == f->post && f->post_blog == f->blog && f->role != ROLE_NONE;
    default:
      return 0;
  }
}

static void bind_text(sqlite3_stmt *st, int i, DbText t) {
  sqlite3_bind_text(st, i, t.ptr != NULL ? t.ptr : "", (int)t.len, SQLITE_STATIC);
}

static DbResult db_rc(int rc) {
  if (rc == SQLITE_DONE) return DB_OK;
  if ((rc & 0xff) == SQLITE_CONSTRAINT) return DB_CONFLICT;
  return DB_ERROR;
}

// Performs the write. Called inside the transaction after the checks.
static DbResult db_do(Db *db, uint64_t now_ms, const DbFacts *f, const DbWrite *w, uint32_t *new_id) {
  sqlite3_stmt *st;
  DbResult r;
  switch (w->kind) {
    case A_CREATE_BLOG:
      st = db->st[ST_BLOG_NEW];
      bind_text(st, 1, w->slug);
      bind_text(st, 2, w->title);
      sqlite3_bind_int64(st, 3, f->who);
      sqlite3_bind_int64(st, 4, (sqlite3_int64)now_ms);
      if ((r = db_rc(db_exec(st))) != DB_OK) return r;
      *new_id = (uint32_t)sqlite3_last_insert_rowid(db->conn);
      st = db->st[ST_MEMBER_NEW];
      sqlite3_bind_int64(st, 1, *new_id);
      sqlite3_bind_int64(st, 2, f->who);
      sqlite3_bind_int64(st, 3, ROLE_OWNER);
      return db_rc(db_exec(st));
    case A_EDIT_BLOG:
      st = db->st[ST_BLOG_TITLE];
      sqlite3_bind_int64(st, 1, w->target);
      bind_text(st, 2, w->title);
      return db_rc(db_exec(st));
    case A_DELETE_BLOG:
      st = db->st[ST_BLOG_DELETE];
      sqlite3_bind_int64(st, 1, w->target);
      return db_rc(db_exec(st));
    case A_ADD_AUTHOR:
      st = db->st[ST_MEMBER_NEW];
      sqlite3_bind_int64(st, 1, w->target);
      sqlite3_bind_int64(st, 2, w->user);
      sqlite3_bind_int64(st, 3, ROLE_AUTHOR);
      return db_rc(db_exec(st));
    case A_REMOVE_AUTHOR:
      st = db->st[ST_MEMBER_DELETE];
      sqlite3_bind_int64(st, 1, w->target);
      sqlite3_bind_int64(st, 2, w->user);
      return db_rc(db_exec(st));
    case A_CREATE_POST:
      st = db->st[ST_POST_NEW];
      sqlite3_bind_int64(st, 1, w->target);
      bind_text(st, 2, w->slug);
      bind_text(st, 3, w->title);
      sqlite3_bind_int64(st, 4, (sqlite3_int64)now_ms);
      if ((r = db_rc(db_exec(st))) != DB_OK) return r;
      *new_id = (uint32_t)sqlite3_last_insert_rowid(db->conn);
      return DB_OK;
    case A_EDIT_POST:
      st = db->st[ST_POST_EDIT];
      sqlite3_bind_int64(st, 1, w->target);
      bind_text(st, 2, w->title);
      bind_text(st, 3, w->body_md);
      bind_text(st, 4, w->body_html);
      sqlite3_bind_int64(st, 5, (sqlite3_int64)now_ms);
      return db_rc(db_exec(st));
    case A_PUBLISH_POST:
      st = db->st[ST_POST_PUBLISH];
      sqlite3_bind_int64(st, 1, w->target);
      sqlite3_bind_int64(st, 2, w->flag != 0u);
      sqlite3_bind_int64(st, 3, (sqlite3_int64)now_ms);
      return db_rc(db_exec(st));
    case A_DELETE_POST:
      st = db->st[ST_POST_DELETE];
      sqlite3_bind_int64(st, 1, w->target);
      return db_rc(db_exec(st));
    default:
      return DB_DENIED;
  }
}

DbResult db_apply(Db *db, const uint8_t token_hash[32], uint64_t now_ms,
                  const DbFacts *f, const DbWrite *w, uint32_t *new_id) {
  ASSERT(db != NULL && f != NULL && w != NULL && new_id != NULL);
  *new_id = 0;
  if (w->kind >= A_KINDS) return DB_DENIED;
  if (!db_floor(f, w)) return DB_DENIED;
  if (db_exec(db->st[ST_BEGIN]) != SQLITE_DONE) return DB_ERROR;
  DbResult r = db_facts_hold(db, token_hash, now_ms, f);
  if (r == DB_OK) r = db_do(db, now_ms, f, w, new_id);
  if (r == DB_OK && db_exec(db->st[ST_COMMIT]) == SQLITE_DONE) return DB_OK;
  int rb = db_exec(db->st[ST_ROLLBACK]);
  ASSERT(rb == SQLITE_DONE);
  return r == DB_OK ? DB_ERROR : r;
}

uint32_t db_user_new(Db *db, DbText email, DbText name, uint64_t now_ms) {
  sqlite3_stmt *st = db->st[ST_USER_NEW];
  bind_text(st, 1, email);
  bind_text(st, 2, name);
  sqlite3_bind_int64(st, 3, (sqlite3_int64)now_ms);
  if (db_exec(st) != SQLITE_DONE) return 0;
  return (uint32_t)sqlite3_last_insert_rowid(db->conn);
}
