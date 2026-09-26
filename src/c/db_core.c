// CORE: the database. See db_core.h for the contract.
#ifndef _DEFAULT_SOURCE
#define _DEFAULT_SOURCE  // explicit_bzero
#endif
#include "db_core.h"

#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/random.h>

#include "../../vendor/bearssl/inc/bearssl_ec.h"
#include "../../vendor/bearssl/inc/bearssl_hash.h"
#include "assert.h"
#include "token_core.h"
#include "ops_core.h"

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
  [ST_POST_NEW] = ("INSERT INTO post(blog_id, slug, title, body_md, body_html, published, created_ms, updated_ms, author_id) "
                   "VALUES (?1, ?2, ?3, '', '', 0, ?4, ?4, ?5)"),
  [ST_POST_EDIT] = "UPDATE post SET title = ?2, body_md = ?3, body_html = ?4, updated_ms = ?5 WHERE id = ?1",
  [ST_POST_PUBLISH] = ("UPDATE post SET published = ?2, updated_ms = ?3, "
                       "published_ms = CASE WHEN ?2 = 1 THEN coalesce(published_ms, ?3) ELSE published_ms END WHERE id = ?1"),
  [ST_POST_DELETE] = "DELETE FROM post WHERE id = ?1",
  [ST_SESSION_DELETE] = "DELETE FROM session WHERE token_hash = ?1",
  [ST_OP_NEW] = ("INSERT OR IGNORE INTO op(post_id, ctr, rep, kind, pctr, prep, side, ch) "
                 "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)"),
  [ST_OP_SINCE] = ("SELECT seq, ctr, rep, kind, pctr, prep, side, ch FROM op WHERE post_id = ?1 AND seq > ?2 "
                   "ORDER BY seq"),
  [ST_OP_COUNT] = "SELECT count(*) FROM op WHERE post_id = ?1",
  [ST_SLUG_TAKEN] = ("SELECT 1 FROM post WHERE blog_id = (SELECT blog_id FROM post WHERE id = ?1) "
                     "AND slug = ?2 AND id <> ?1"),
  [ST_POST_RENAME] = ("UPDATE post SET slug = ?2 WHERE id = ?1 AND published_ms IS NULL "
                      "AND substr(slug, 1, 6) = 'draft-'"),
  [ST_TOKEN_RECENT] = "SELECT count(*) FROM email_token WHERE email = ?1 AND created_ms > ?2",
  [ST_TOKEN_NEW] = ("INSERT INTO email_token(hash, purpose, email, name, user_id, created_ms, expires_ms) "
                    "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)"),
  [ST_TOKEN_GET] = "SELECT purpose, email, name, user_id FROM email_token WHERE hash = ?1 AND used = 0 AND expires_ms > ?2",
  [ST_TOKEN_USE] = "UPDATE email_token SET used = 1 WHERE hash = ?1 AND used = 0 AND expires_ms > ?2",
  [ST_OUTBOX_NEW] = "INSERT INTO outbox(to_email, subject, body, created_ms) VALUES (?1, ?2, ?3, ?4)",
  [ST_USER_ID_BY_EMAIL] = "SELECT id FROM user WHERE email = ?1",
  [ST_CHAL_NEW] = "INSERT INTO challenge(hash, purpose, token_hash, expires_ms) VALUES (?1, ?2, ?3, ?4)",
  [ST_CHAL_USE] = ("UPDATE challenge SET used = 1 WHERE hash = ?1 AND purpose = ?2 AND used = 0 AND expires_ms > ?3 "
                   "AND (token_hash IS ?4)"),
  [ST_CRED_GET] = "SELECT user_id, x, y, sign_count FROM credential WHERE id = ?1",
  [ST_CRED_NEW] = "INSERT INTO credential(id, user_id, x, y, sign_count, created_ms) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
  [ST_CRED_COUNT] = ("UPDATE credential SET sign_count = ?2 WHERE id = ?1 AND "
                     "(sign_count < ?2 OR (sign_count = 0 AND ?2 = 0))"),
  [ST_LIKE_ADD] = "INSERT OR IGNORE INTO post_like(post_id, user_id, created_ms) VALUES (?1, ?2, ?3)",
  [ST_LIKE_DEL] = "DELETE FROM post_like WHERE post_id = ?1 AND user_id = ?2",
  [ST_COMMENT_RECENT] = "SELECT count(*) FROM comment WHERE author_id = ?1 AND created_ms > ?2",
  [ST_COMMENT_COUNT] = "SELECT count(*) FROM comment WHERE post_id = ?1",
  // A reply's parent must be a live comment on the same post.
  [ST_COMMENT_NEW] = ("INSERT INTO comment(post_id, parent_id, author_id, body_md, body_html, created_ms) "
                      "SELECT ?1, nullif(?2, 0), ?3, ?4, ?5, ?6 WHERE ?2 = 0 OR EXISTS "
                      "(SELECT 1 FROM comment WHERE id = ?2 AND post_id = ?1 AND deleted = 0)"),
  // Matches only that comment, on that post, by that author: the claimed
  // author is checked here. Replies stay; the text goes.
  [ST_COMMENT_DEL] = ("UPDATE comment SET deleted = 1, body_md = '', body_html = '' "
                      "WHERE id = ?1 AND post_id = ?2 AND author_id = ?3 AND deleted = 0"),
  [ST_COMMENT_BODY] = ("SELECT c.body_html FROM comment c JOIN post p ON p.id = c.post_id WHERE c.id = ?1 AND c.deleted = 0 "
                       "AND (p.published = 1 OR EXISTS (SELECT 1 FROM member m JOIN session s ON s.user_id = m.user_id "
                       "WHERE m.blog_id = p.blog_id AND s.token_hash = ?2 AND s.expires_ms > ?3))"),
  [ST_BODY] = ("SELECT p.body_html FROM post p WHERE p.id = ?1 AND (p.published = 1 OR EXISTS (SELECT 1 FROM member m JOIN session s ON s.user_id = m.user_id WHERE m.blog_id = p.blog_id AND s.token_hash = ?2 AND s.expires_ms > ?3))"),
};

// Query parameters: ?1 = a, ?2 = b, ?3 = text, ?8 = token hash, ?9 = now.
#define MEMBER_OF(blog) \
  "EXISTS (SELECT 1 FROM member m JOIN session s ON s.user_id = m.user_id " \
  "WHERE m.blog_id = " blog " AND s.token_hash = ?8 AND s.expires_ms > ?9)"

// Shared SQL pieces for what the pages show about a post p of blog b.
#define POST_AUTHOR "coalesce((SELECT name FROM user WHERE id = p.author_id), '')"
#define POST_DATE "strftime('%Y-%m-%d', coalesce(p.published_ms, p.updated_ms) / 1000, 'unixepoch')"
#define POST_EXCERPT \
  "substr(trim(replace(replace(replace(replace(replace(replace(p.body_md, char(13), ''), char(10), ' '), '#', ''), '*', ''), '>', ''), '`', '')), 1, 240)"
#define POST_MINUTES "max(1, (length(p.body_md) + 999) / 1100)"

// RFC 822 date for RSS, e.g. "Sat, 26 Sep 2026 18:20:35 +0000".
#define POST_RFC822_AT(t) \
  "substr('SunMonTueWedThuFriSat', 1 + 3 * strftime('%w', " t " / 1000, 'unixepoch'), 3) || ', ' || " \
  "strftime('%d ', " t " / 1000, 'unixepoch') || " \
  "substr('JanFebMarAprMayJunJulAugSepOctNovDec', 3 * strftime('%m', " t " / 1000, 'unixepoch') - 2, 3) || " \
  "strftime(' %Y %H:%M:%S +0000', " t " / 1000, 'unixepoch')"
#define POST_RFC822 POST_RFC822_AT("coalesce(p.published_ms, p.updated_ms)")
#define COMMENT_DATE "strftime('%Y-%m-%d', c.created_ms / 1000, 'unixepoch')"
#define FEED_COLS "b.slug, p.slug, p.title, b.title, " POST_AUTHOR ", " POST_DATE ", " POST_EXCERPT ", " POST_MINUTES ", p.author_id, " POST_RFC822

static const char *const DB_Q[Q_COUNT] = {
  [Q_BLOG_BY_SLUG] = ("SELECT b.id, b.title, b.slug, coalesce((SELECT name FROM user WHERE id = b.owner_id), '') "
                      "FROM blog b WHERE b.slug = ?3"),
  [Q_POST_ID] = "SELECT id FROM post WHERE blog_id = ?1 AND slug = ?3",
  [Q_POSTS_PUBLIC] = ("SELECT p.slug, p.title, " POST_AUTHOR ", " POST_DATE ", " POST_EXCERPT ", " POST_MINUTES ", p.author_id, " POST_RFC822 " "
                      "FROM post p JOIN blog b ON b.id = p.blog_id WHERE p.blog_id = ?1 AND p.published = 1 "
                      "ORDER BY p.published_ms DESC LIMIT 100"),
  [Q_RECENT_PUBLIC] = ("SELECT " FEED_COLS " FROM post p JOIN blog b ON b.id = p.blog_id WHERE p.published = 1 "
                       "ORDER BY p.published_ms DESC LIMIT 30"),
  [Q_POST_VIEW] = ("SELECT p.slug, p.title, p.published, b.slug, b.title, " POST_AUTHOR ", " POST_DATE ", " POST_MINUTES ", p.author_id "
                   "FROM post p JOIN blog b ON b.id = p.blog_id "
                   "WHERE p.id = ?1 AND (p.published = 1 OR " MEMBER_OF("p.blog_id") ")"),
  [Q_MY_BLOGS] = ("SELECT b.id, b.slug, b.title, m.role, "
                  "(SELECT count(*) FROM post WHERE blog_id = b.id AND published = 1), "
                  "(SELECT count(*) FROM post WHERE blog_id = b.id AND published = 0) "
                  "FROM blog b JOIN member m ON m.blog_id = b.id "
                  "JOIN session s ON s.user_id = m.user_id WHERE s.token_hash = ?8 AND s.expires_ms > ?9 "
                  "ORDER BY b.title LIMIT 100"),
  [Q_POSTS_MEMBER] = ("SELECT p.id, p.slug, p.title, p.published, strftime('%Y-%m-%d', p.updated_ms / 1000, 'unixepoch'), "
                      POST_AUTHOR " FROM post p JOIN blog b ON b.id = p.blog_id WHERE p.blog_id = ?1 AND "
                      MEMBER_OF("?1") " ORDER BY p.updated_ms DESC LIMIT 100"),
  [Q_POST_MD] = ("SELECT p.body_md, p.title, p.published, b.slug, p.slug FROM post p JOIN blog b ON b.id = p.blog_id "
                 "WHERE p.id = ?1 AND " MEMBER_OF("p.blog_id")),
  [Q_USER_BY_EMAIL] = "SELECT id FROM user WHERE email = ?3",
  [Q_AUTHORS] = ("SELECT u.id, u.name, u.email, m.role FROM member m JOIN user u ON u.id = m.user_id "
                 "WHERE m.blog_id = ?1 AND " MEMBER_OF("?1") " ORDER BY m.role, u.name LIMIT 100"),
  [Q_OPS] = ("SELECT coalesce(group_concat(ctr || '.' || rep || '.' || kind || '.' || pctr || '.' || prep || '.' || side || '.' || ch || ';', ''), '') "
             "FROM (SELECT * FROM op o WHERE o.post_id = ?1 AND " MEMBER_OF("(SELECT blog_id FROM post WHERE id = ?1)") " ORDER BY o.seq)"),
  [Q_OP_COUNT] = ("SELECT count(*) FROM op WHERE post_id = ?1 AND " MEMBER_OF("(SELECT blog_id FROM post WHERE id = ?1)")),
  // Names are shown only for people who have published something: user
  // ids are sequential, so otherwise anyone could list every account.
  [Q_AUTHOR_PUBLIC] = ("SELECT u.name FROM user u WHERE u.id = ?1 AND EXISTS "
                       "(SELECT 1 FROM post p WHERE p.author_id = u.id AND p.published = 1)"),
  // ?3 is an FTS5 expression built by Text.fts_query (quoted terms only).
  // The snippet marks matches with bytes 1 and 2, which stored text never
  // contains (bodies have no control characters but newline and tab).
  [Q_SEARCH] = ("SELECT b.slug, p.slug, p.title, b.title, " POST_AUTHOR ", " POST_DATE ", "
                "snippet(post_fts, 1, char(1), char(2), '…', 24), " POST_MINUTES ", p.author_id "
                "FROM post_fts JOIN post p ON p.id = post_fts.rowid JOIN blog b ON b.id = p.blog_id "
                "WHERE post_fts MATCH ?3 AND p.published = 1 ORDER BY rank LIMIT 30"),
  [Q_POST_SOCIAL] = ("SELECT (SELECT count(*) FROM post_like WHERE post_id = p.id), "
                     "EXISTS (SELECT 1 FROM post_like l JOIN session s ON s.user_id = l.user_id "
                     "WHERE l.post_id = p.id AND s.token_hash = ?8 AND s.expires_ms > ?9), "
                     "(SELECT count(*) FROM comment WHERE post_id = p.id AND deleted = 0) "
                     "FROM post p WHERE p.id = ?1 AND (p.published = 1 OR " MEMBER_OF("p.blog_id") ")"),
  // Threads in order (a path of zero-padded ids), at most 50 deep.
  [Q_COMMENTS] = ("WITH RECURSIVE t(id, depth, path) AS ("
                  "SELECT id, 0, printf('%010d', id) FROM comment WHERE post_id = ?1 AND parent_id IS NULL "
                  "UNION ALL SELECT c.id, t.depth + 1, t.path || printf('%010d', c.id) FROM comment c JOIN t ON c.parent_id = t.id "
                  "WHERE t.depth < 50) "
                  "SELECT c.id, t.depth, c.author_id, coalesce(u.name, ''), " COMMENT_DATE ", c.deleted, "
                  "EXISTS (SELECT 1 FROM session s WHERE s.user_id = c.author_id AND s.token_hash = ?8 AND s.expires_ms > ?9), "
                  "coalesce(c.parent_id, 0) "
                  "FROM t JOIN comment c ON c.id = t.id LEFT JOIN user u ON u.id = c.author_id "
                  "WHERE EXISTS (SELECT 1 FROM post p WHERE p.id = ?1 AND (p.published = 1 OR " MEMBER_OF("p.blog_id") ")) "
                  "ORDER BY t.path LIMIT 300"),
  [Q_COMMENT_INFO] = ("SELECT c.post_id, c.author_id, coalesce(u.name, ''), " COMMENT_DATE ", c.deleted "
                      "FROM comment c JOIN post p ON p.id = c.post_id LEFT JOIN user u ON u.id = c.author_id "
                      "WHERE c.id = ?1 AND (p.published = 1 OR " MEMBER_OF("p.blog_id") ")"),
  [Q_POSTS_BY_AUTHOR] = ("SELECT " FEED_COLS " FROM post p JOIN blog b ON b.id = p.blog_id "
                         "WHERE p.author_id = ?1 AND p.published = 1 ORDER BY p.published_ms DESC LIMIT 100"),
};

// Schema migrations, in order; PRAGMA user_version counts those applied.
// Each runs in its own transaction. Never edit one that has shipped.
static const char *const DB_MIGRATIONS[] = {
  // v1: post authors, and when a post was first published (feeds sort by
  // it, so editing an old post does not move it to the top).
  "ALTER TABLE post ADD COLUMN author_id INTEGER REFERENCES user(id);"
  "ALTER TABLE post ADD COLUMN published_ms INTEGER;"
  "UPDATE post SET published_ms = updated_ms WHERE published = 1;"
  "CREATE INDEX IF NOT EXISTS post_feed ON post(published, published_ms DESC);"
  "CREATE INDEX IF NOT EXISTS post_blog_feed ON post(blog_id, published, published_ms DESC);",
  // v2: every post has an author (older posts: the blog's owner), for
  // author pages.
  "UPDATE post SET author_id = (SELECT owner_id FROM blog WHERE blog.id = post.blog_id) WHERE author_id IS NULL;"
  "CREATE INDEX IF NOT EXISTS post_author_feed ON post(author_id, published, published_ms DESC);",
  // v3: full-text search (FTS5, built into SQLite). Indexes every post;
  // searches return published posts only (drafts' words do slightly
  // affect ranking statistics, never results or snippets).
  "CREATE VIRTUAL TABLE post_fts USING fts5(title, body_md, content='post', content_rowid='id',"
  " tokenize='unicode61 remove_diacritics 2');"
  "CREATE TRIGGER post_fts_ai AFTER INSERT ON post BEGIN"
  " INSERT INTO post_fts(rowid, title, body_md) VALUES (new.id, new.title, new.body_md); END;"
  "CREATE TRIGGER post_fts_ad AFTER DELETE ON post BEGIN"
  " INSERT INTO post_fts(post_fts, rowid, title, body_md) VALUES ('delete', old.id, old.title, old.body_md); END;"
  "CREATE TRIGGER post_fts_au AFTER UPDATE OF title, body_md ON post BEGIN"
  " INSERT INTO post_fts(post_fts, rowid, title, body_md) VALUES ('delete', old.id, old.title, old.body_md);"
  " INSERT INTO post_fts(rowid, title, body_md) VALUES (new.id, new.title, new.body_md); END;"
  "INSERT INTO post_fts(post_fts) VALUES ('rebuild');",
  // v4: likes and comments. A deleted comment keeps its row (and replies)
  // with its text removed.
  "CREATE TABLE post_like (post_id INTEGER NOT NULL REFERENCES post(id) ON DELETE CASCADE,"
  " user_id INTEGER NOT NULL REFERENCES user(id) ON DELETE CASCADE, created_ms INTEGER NOT NULL,"
  " PRIMARY KEY (post_id, user_id)) WITHOUT ROWID;"
  "CREATE TABLE comment (id INTEGER PRIMARY KEY, post_id INTEGER NOT NULL REFERENCES post(id) ON DELETE CASCADE,"
  " parent_id INTEGER REFERENCES comment(id) ON DELETE CASCADE, author_id INTEGER NOT NULL REFERENCES user(id),"
  " body_md TEXT NOT NULL CHECK (length(body_md) <= 10000), body_html TEXT NOT NULL,"
  " created_ms INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0, 1)));"
  "CREATE INDEX comment_post ON comment(post_id, parent_id);"
  "CREATE INDEX comment_parent ON comment(parent_id);"
  "CREATE INDEX comment_author_time ON comment(author_id, created_ms);",
};
#define DB_MIGRATION_COUNT (sizeof DB_MIGRATIONS / sizeof DB_MIGRATIONS[0])

static int32_t db_migrate(Db *db) {
  sqlite3_stmt *st;
  if (sqlite3_prepare_v2(db->conn, "PRAGMA user_version", -1, &st, NULL) != SQLITE_OK) return -1;
  int64_t v = sqlite3_step(st) == SQLITE_ROW ? sqlite3_column_int64(st, 0) : -1;
  sqlite3_finalize(st);
  if (v < 0 || (uint64_t)v > DB_MIGRATION_COUNT) return -1;
  for (uint64_t i = (uint64_t)v; i < DB_MIGRATION_COUNT; i++) {
    char set[64];
    int n = snprintf(set, sizeof set, "PRAGMA user_version = %llu;", (unsigned long long)(i + 1u));
    ASSERT(n > 0 && (size_t)n < sizeof set);
    if (sqlite3_exec(db->conn, "BEGIN IMMEDIATE", NULL, NULL, NULL) != SQLITE_OK) return -1;
    if (sqlite3_exec(db->conn, DB_MIGRATIONS[i], NULL, NULL, NULL) != SQLITE_OK ||
        sqlite3_exec(db->conn, set, NULL, NULL, NULL) != SQLITE_OK) {
      fprintf(stderr, "db_migrate: migration %llu: %s\n", (unsigned long long)(i + 1u), sqlite3_errmsg(db->conn));
      sqlite3_exec(db->conn, "ROLLBACK", NULL, NULL, NULL);
      return -1;
    }
    if (sqlite3_exec(db->conn, "COMMIT", NULL, NULL, NULL) != SQLITE_OK) return -1;
  }
  return 0;
}

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
    "PRAGMA cell_size_check = ON;"
    "PRAGMA optimize = 0x10002;";
  if (sqlite3_exec(db->conn, pragmas, NULL, NULL, NULL) != SQLITE_OK) return -1;
  if (sqlite3_exec(db->conn, DB_SCHEMA, NULL, NULL, NULL) != SQLITE_OK) return -1;
  if (db_migrate(db) != 0) return -1;
  for (uint32_t i = 0; i < ST_COUNT; i++) {
    ASSERT(DB_SQL[i] != NULL);
    if (sqlite3_prepare_v3(db->conn, DB_SQL[i], -1, SQLITE_PREPARE_PERSISTENT, &db->st[i], NULL) != SQLITE_OK) {
      fprintf(stderr, "db_open: statement %u: %s\n", i, sqlite3_errmsg(db->conn));
      return -1;
    }
  }
  for (uint32_t i = 0; i < Q_COUNT; i++) {
    ASSERT(DB_Q[i] != NULL);
    if (sqlite3_prepare_v3(db->conn, DB_Q[i], -1, SQLITE_PREPARE_PERSISTENT, &db->q[i], NULL) != SQLITE_OK) {
      fprintf(stderr, "db_open: query %u: %s\n", i, sqlite3_errmsg(db->conn));
      return -1;
    }
  }
  return 0;
}

void db_close(Db *db) {
  for (uint32_t i = 0; i < ST_COUNT; i++) sqlite3_finalize(db->st[i]);
  for (uint32_t i = 0; i < Q_COUNT; i++) sqlite3_finalize(db->q[i]);
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

int32_t db_session_end(Db *db, const uint8_t token_hash[32]) {
  sqlite3_stmt *st = db->st[ST_SESSION_DELETE];
  sqlite3_bind_blob(st, 1, token_hash, 32, SQLITE_STATIC);
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
    case A_SYNC_OPS:
      return f->has_post && w->target == f->post && f->post_blog == f->blog && f->role != ROLE_NONE;
    case A_LIKE_POST:
    case A_COMMENT:
      return f->who != 0u && f->has_post && w->target == f->post && f->post_pub == 1u;
    case A_DELETE_COMMENT:
      return f->who != 0u && f->has_post && f->post_blog == f->blog &&
             ((w->user != 0u && w->user == f->who) || f->role != ROLE_NONE);
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

// A draft made by "Write" has a placeholder address (draft-<hex>). When it
// is first published it takes the address its title gives (slug), or the
// first free of slug-2 .. slug-50 in its blog; if none is free it keeps
// the placeholder. Only never-published drafts are renamed, so a published
// address never changes. PRE: slug is a valid slug (Bend's Slug), at most
// DB_RENAME_BASE_MAX bytes, so a suffix keeps it within 64.
#define DB_RENAME_BASE_MAX 60u
#define DB_RENAME_TRIES 50u

static DbResult db_publish_rename(Db *db, uint32_t post, DbText slug) {
  if (slug.len == 0u || slug.len > DB_RENAME_BASE_MAX) return DB_OK;
  char cand[DB_RENAME_BASE_MAX + 8u];
  for (uint32_t i = 1; i <= DB_RENAME_TRIES; i++) {
    int n = i == 1u ? snprintf(cand, sizeof cand, "%.*s", (int)slug.len, slug.ptr)
                    : snprintf(cand, sizeof cand, "%.*s-%u", (int)slug.len, slug.ptr, i);
    ASSERT(n > 0 && (size_t)n < sizeof cand);
    sqlite3_stmt *st = db->st[ST_SLUG_TAKEN];
    sqlite3_bind_int64(st, 1, post);
    sqlite3_bind_text(st, 2, cand, n, SQLITE_STATIC);
    int rc = db_exec(st);
    if (rc == SQLITE_ROW) continue;
    if (rc != SQLITE_DONE) return DB_ERROR;
    st = db->st[ST_POST_RENAME];
    sqlite3_bind_int64(st, 1, post);
    sqlite3_bind_text(st, 2, cand, n, SQLITE_STATIC);
    return db_rc(db_exec(st));
  }
  return DB_OK;
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
      sqlite3_bind_int64(st, 5, f->who);
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
      if (w->flag != 0u && (r = db_publish_rename(db, w->target, w->slug)) != DB_OK) return r;
      st = db->st[ST_POST_PUBLISH];
      sqlite3_bind_int64(st, 1, w->target);
      sqlite3_bind_int64(st, 2, w->flag != 0u);
      sqlite3_bind_int64(st, 3, (sqlite3_int64)now_ms);
      return db_rc(db_exec(st));
    case A_DELETE_POST:
      st = db->st[ST_POST_DELETE];
      sqlite3_bind_int64(st, 1, w->target);
      return db_rc(db_exec(st));
    case A_LIKE_POST:
      st = db->st[w->flag != 0u ? ST_LIKE_ADD : ST_LIKE_DEL];
      sqlite3_bind_int64(st, 1, w->target);
      sqlite3_bind_int64(st, 2, f->who);
      if (w->flag != 0u) sqlite3_bind_int64(st, 3, (sqlite3_int64)now_ms);
      return db_rc(db_exec(st));
    case A_COMMENT: {
      uint32_t n = 0;
      st = db->st[ST_COMMENT_RECENT];
      sqlite3_bind_int64(st, 1, f->who);
      sqlite3_bind_int64(st, 2, (sqlite3_int64)(now_ms - COMMENT_RATE_WINDOW_MS));
      if (db_one_u32(st, &n) != 1) return DB_ERROR;
      if (n >= COMMENT_RATE_MAX) return DB_CONFLICT;
      st = db->st[ST_COMMENT_COUNT];
      sqlite3_bind_int64(st, 1, w->target);
      if (db_one_u32(st, &n) != 1) return DB_ERROR;
      if (n >= POST_COMMENTS_MAX) return DB_CONFLICT;
      st = db->st[ST_COMMENT_NEW];
      sqlite3_bind_int64(st, 1, w->target);
      sqlite3_bind_int64(st, 2, w->flag);
      sqlite3_bind_int64(st, 3, f->who);
      bind_text(st, 4, w->body_md);
      bind_text(st, 5, w->body_html);
      sqlite3_bind_int64(st, 6, (sqlite3_int64)now_ms);
      if ((r = db_rc(db_exec(st))) != DB_OK) return r;
      if (sqlite3_changes(db->conn) != 1) return DB_STALE;  // no such parent on this post
      *new_id = (uint32_t)sqlite3_last_insert_rowid(db->conn);
      return DB_OK;
    }
    case A_DELETE_COMMENT:
      st = db->st[ST_COMMENT_DEL];
      sqlite3_bind_int64(st, 1, w->target);
      sqlite3_bind_int64(st, 2, f->post);
      sqlite3_bind_int64(st, 3, w->user);
      if ((r = db_rc(db_exec(st))) != DB_OK) return r;
      return sqlite3_changes(db->conn) == 1 ? DB_OK : DB_STALE;  // not that author's live comment
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
  if (db_exec(db->st[ST_BEGIN]) != SQLITE_DONE) {
    fprintf(stderr, "db_apply: begin: %s\n", sqlite3_errmsg(db->conn));
    return DB_ERROR;
  }
  DbResult r = db_facts_hold(db, token_hash, now_ms, f);
  if (r == DB_OK) r = db_do(db, now_ms, f, w, new_id);
  if (r == DB_OK && db_exec(db->st[ST_COMMIT]) == SQLITE_DONE) return DB_OK;
  if (r == DB_OK || r == DB_ERROR) fprintf(stderr, "db_apply: action %u: %s\n", w->kind, sqlite3_errmsg(db->conn));
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

int32_t db_query(Db *db, uint32_t q, uint32_t a, uint32_t b, DbText text,
                 const uint8_t token_hash[32], uint64_t now_ms, DbRowFn fn, void *ctx) {
  if (q >= Q_COUNT) return -1;
  sqlite3_stmt *st = db->q[q];
  int n = sqlite3_bind_parameter_count(st);
  // Bind only the parameters this statement uses (by name position).
  for (int i = 1; i <= n; i++) {
    const char *name = sqlite3_bind_parameter_name(st, i);
    if (name == NULL) continue;  // an index below the highest that the SQL does not use
    ASSERT(name[0] == '?' && name[1] != 0 && name[2] == 0);
    switch (name[1]) {
      case '1': sqlite3_bind_int64(st, i, a); break;
      case '2': sqlite3_bind_int64(st, i, b); break;
      case '3': bind_text(st, i, text); break;
      case '8': sqlite3_bind_blob(st, i, token_hash, 32, SQLITE_STATIC); break;
      case '9': sqlite3_bind_int64(st, i, (sqlite3_int64)now_ms); break;
      default: ASSERT(0);
    }
  }
  int32_t rows = 0;
  int rc;
  while (rows < (int32_t)DB_ROWS_MAX && (rc = sqlite3_step(st)) == SQLITE_ROW) {
    int nc = sqlite3_column_count(st);
    ASSERT(nc > 0 && (uint32_t)nc <= DB_COLS_MAX);
    const char *cols[DB_COLS_MAX];
    uint32_t lens[DB_COLS_MAX];
    for (int i = 0; i < nc; i++) {
      const unsigned char *t = sqlite3_column_text(st, i);
      int len = sqlite3_column_bytes(st, i);
      ASSERT(len >= 0);
      cols[i] = t != NULL ? (const char *)t : "";
      lens[i] = (uint32_t)len;
    }
    fn(ctx, (uint32_t)nc, cols, lens);
    rows++;
  }
  sqlite3_reset(st);
  sqlite3_clear_bindings(st);
  return rows;
}

int32_t db_comment_body(Db *db, uint32_t comment, const uint8_t token_hash[32], uint64_t now_ms,
                        DbOutFn out, void *ctx) {
  sqlite3_stmt *st = db->st[ST_COMMENT_BODY];
  sqlite3_bind_int64(st, 1, comment);
  sqlite3_bind_blob(st, 2, token_hash, 32, SQLITE_STATIC);
  sqlite3_bind_int64(st, 3, (sqlite3_int64)now_ms);
  int rc = sqlite3_step(st);
  int32_t r = rc == SQLITE_DONE ? 0 : -1;
  if (rc == SQLITE_ROW) {
    const unsigned char *t = sqlite3_column_text(st, 0);
    int n = sqlite3_column_bytes(st, 0);
    ASSERT(n >= 0);
    out(ctx, t != NULL ? (const char *)t : "", (uint32_t)n);
    r = 1;
  }
  sqlite3_reset(st);
  sqlite3_clear_bindings(st);
  return r;
}

int32_t db_body(Db *db, uint32_t post, const uint8_t token_hash[32], uint64_t now_ms,
                DbOutFn out, void *ctx) {
  sqlite3_stmt *st = db->st[ST_BODY];
  sqlite3_bind_int64(st, 1, post);
  sqlite3_bind_blob(st, 2, token_hash, 32, SQLITE_STATIC);
  sqlite3_bind_int64(st, 3, (sqlite3_int64)now_ms);
  int rc = sqlite3_step(st);
  int32_t r = rc == SQLITE_DONE ? 0 : -1;
  if (rc == SQLITE_ROW) {
    const unsigned char *t = sqlite3_column_text(st, 0);
    int n = sqlite3_column_bytes(st, 0);
    ASSERT(n >= 0);
    out(ctx, t != NULL ? (const char *)t : "", (uint32_t)n);
    r = 1;
  }
  sqlite3_reset(st);
  sqlite3_clear_bindings(st);
  return r;
}

// AUTHENTICATION
// --------------

void auth_sha256(const uint8_t *p, uint32_t n, uint8_t out[32]) {
  br_sha256_context c;
  br_sha256_init(&c);
  br_sha256_update(&c, p, n);
  br_sha256_out(&c, out);
}

int32_t auth_p256_verify(const uint8_t x[32], const uint8_t y[32], const uint8_t *msg, uint32_t msg_len,
                         const uint8_t *sig, uint32_t sig_len) {
  if (sig_len == 0u || sig_len > 72u) return 0;
  uint8_t point[65];
  point[0] = 0x04;
  memcpy(point + 1, x, 32);
  memcpy(point + 33, y, 32);
  br_ec_public_key pk = {BR_EC_secp256r1, point, sizeof point};
  uint8_t h[32];
  auth_sha256(msg, msg_len, h);
  uint32_t ok = br_ecdsa_i31_vrfy_asn1(&br_ec_p256_m31, h, sizeof h, &pk, sig, sig_len);
  return ok == 1u ? 1 : 0;
}

// Runs a change statement; returns the number of rows changed, or -1.
static int32_t db_changes(Db *db, sqlite3_stmt *st) {
  int rc = db_exec(st);
  if (rc != SQLITE_DONE) return -1;
  return (int32_t)sqlite3_changes(db->conn);
}

static AuthResult auth_rollback(Db *db, AuthResult r) {
  int rb = db_exec(db->st[ST_ROLLBACK]);
  ASSERT(rb == SQLITE_DONE);
  return r;
}

static AuthResult auth_commit(Db *db) {
  if (db_exec(db->st[ST_COMMIT]) == SQLITE_DONE) return AUTH_OK;
  return auth_rollback(db, AUTH_ERROR);
}

// The link and email text. origin is checked to be plain printable ASCII.
static int32_t auth_mail_text(char *out, size_t cap, uint32_t purpose, DbText origin, const uint8_t hex[64]) {
  for (uint32_t i = 0; i < origin.len; i++) {
    unsigned char ch = (unsigned char)origin.ptr[i];
    if (ch <= 32u || ch >= 127u || ch == '"' || ch == '<' || ch == '>') return -1;
  }
  const char *what = purpose == AUTH_SIGNUP ? "finish creating your account" : "sign in and add a new passkey";
  int n = snprintf(out, cap, "Open this link within 30 minutes to %s:\n\n%.*s/verify?t=%.64s\n\n"
                   "If you did not ask for this, ignore this email.\n",
                   what, (int)origin.len, origin.ptr, (const char *)hex);
  return n > 0 && (size_t)n < cap ? n : -1;
}

static AuthResult auth_token_issue(Db *db, uint32_t purpose, DbText email, DbText name, DbText origin, uint64_t now_ms,
                                   uint8_t *token_out);

AuthResult auth_email_token(Db *db, uint32_t purpose, DbText email, DbText name, DbText origin, uint64_t now_ms) {
  return auth_token_issue(db, purpose, email, name, origin, now_ms, NULL);
}

AuthResult auth_signup_direct(Db *db, DbText email, DbText name, DbText origin, uint64_t now_ms, uint8_t token_hex[64]) {
  return auth_token_issue(db, AUTH_SIGNUP, email, name, origin, now_ms, token_hex);
}

static AuthResult auth_token_issue(Db *db, uint32_t purpose, DbText email, DbText name, DbText origin, uint64_t now_ms,
                                   uint8_t *token_out) {
  ASSERT(purpose == AUTH_SIGNUP || purpose == AUTH_RECOVER);
  if (email.len == 0u || email.len > 254u || name.len > 64u || origin.len == 0u || origin.len > 200u) {
    return AUTH_INVALID;
  }
  if (db_exec(db->st[ST_BEGIN]) != SQLITE_DONE) return AUTH_ERROR;
  sqlite3_stmt *st = db->st[ST_TOKEN_RECENT];
  bind_text(st, 1, email);
  sqlite3_bind_int64(st, 2, (sqlite3_int64)(now_ms - 3600000ull));
  uint32_t recent = 0;
  if (db_one_u32(st, &recent) != 1) return auth_rollback(db, AUTH_ERROR);
  if (recent >= EMAIL_TOKENS_PER_HOUR) return auth_rollback(db, AUTH_RATE_LIMITED);
  st = db->st[ST_USER_ID_BY_EMAIL];
  bind_text(st, 1, email);
  uint32_t user = 0;
  int32_t found = db_one_u32(st, &user);
  if (found < 0) return auth_rollback(db, AUTH_ERROR);
  if (purpose == AUTH_SIGNUP && found == 1) return auth_rollback(db, AUTH_EMAIL_TAKEN);
  if (purpose == AUTH_RECOVER && found == 0) return auth_rollback(db, AUTH_OK);  // silent
  uint8_t raw[32], hash[32], hex[64];
  if (getrandom(raw, sizeof raw, 0) != (ssize_t)sizeof raw) return auth_rollback(db, AUTH_ERROR);
  auth_sha256(raw, 32, hash);
  token_encode(raw, hex);
  explicit_bzero(raw, sizeof raw);
  if (token_out != NULL) memcpy(token_out, hex, sizeof hex);
  st = db->st[ST_TOKEN_NEW];
  sqlite3_bind_blob(st, 1, hash, 32, SQLITE_TRANSIENT);
  sqlite3_bind_int64(st, 2, purpose);
  bind_text(st, 3, email);
  bind_text(st, 4, name);
  if (purpose == AUTH_RECOVER) sqlite3_bind_int64(st, 5, user);
  else sqlite3_bind_null(st, 5);
  sqlite3_bind_int64(st, 6, (sqlite3_int64)now_ms);
  sqlite3_bind_int64(st, 7, (sqlite3_int64)(now_ms + EMAIL_TOKEN_TTL_MS));
  if (db_exec(st) != SQLITE_DONE) return auth_rollback(db, AUTH_ERROR);
  char text[1024];
  int32_t tn = auth_mail_text(text, sizeof text, purpose, origin, hex);
  explicit_bzero(hex, sizeof hex);
  if (tn < 0) return auth_rollback(db, AUTH_INVALID);
  st = db->st[ST_OUTBOX_NEW];
  bind_text(st, 1, email);
  sqlite3_bind_text(st, 2, purpose == AUTH_SIGNUP ? "Finish creating your account" : "Your sign-in link", -1, SQLITE_STATIC);
  sqlite3_bind_text(st, 3, text, tn, SQLITE_TRANSIENT);
  sqlite3_bind_int64(st, 4, (sqlite3_int64)now_ms);
  int rc = db_exec(st);
  explicit_bzero(text, sizeof text);
  if (rc != SQLITE_DONE) return auth_rollback(db, AUTH_ERROR);
  return auth_commit(db);
}

AuthResult auth_token_check(Db *db, const uint8_t token_hash[32], uint64_t now_ms, uint32_t *purpose) {
  sqlite3_stmt *st = db->st[ST_TOKEN_GET];
  sqlite3_bind_blob(st, 1, token_hash, 32, SQLITE_STATIC);
  sqlite3_bind_int64(st, 2, (sqlite3_int64)now_ms);
  int32_t r = db_one_u32(st, purpose);
  if (r < 0) return AUTH_ERROR;
  return r == 1 ? AUTH_OK : AUTH_INVALID;
}

AuthResult auth_token_info(Db *db, const uint8_t token_hash[32], uint64_t now_ms, uint32_t *purpose,
                           char email[256], char name[128]) {
  sqlite3_stmt *st = db->st[ST_TOKEN_GET];
  sqlite3_bind_blob(st, 1, token_hash, 32, SQLITE_STATIC);
  sqlite3_bind_int64(st, 2, (sqlite3_int64)now_ms);
  int rc = sqlite3_step(st);
  AuthResult r = rc == SQLITE_DONE ? AUTH_INVALID : AUTH_ERROR;
  if (rc == SQLITE_ROW) {
    int el = sqlite3_column_bytes(st, 1), nl = sqlite3_column_bytes(st, 2);
    if (el >= 0 && el < 256 && nl >= 0 && nl < 128) {
      *purpose = (uint32_t)sqlite3_column_int64(st, 0);
      memcpy(email, sqlite3_column_text(st, 1), (size_t)el);
      email[el] = 0;
      memcpy(name, sqlite3_column_text(st, 2), (size_t)nl);
      name[nl] = 0;
      r = AUTH_OK;
    }
  }
  sqlite3_reset(st);
  sqlite3_clear_bindings(st);
  return r;
}

AuthResult auth_challenge(Db *db, uint32_t purpose, const uint8_t *token_hash, uint64_t now_ms, uint8_t out[32]) {
  ASSERT(purpose == CHAL_REGISTER || purpose == CHAL_LOGIN);
  ASSERT((purpose == CHAL_REGISTER) == (token_hash != NULL));
  if (token_hash != NULL) {
    uint32_t tp = 0;
    AuthResult r = auth_token_check(db, token_hash, now_ms, &tp);
    if (r != AUTH_OK) return r;
  }
  if (getrandom(out, 32, 0) != 32) return AUTH_ERROR;
  uint8_t hash[32];
  auth_sha256(out, 32, hash);
  sqlite3_stmt *st = db->st[ST_CHAL_NEW];
  sqlite3_bind_blob(st, 1, hash, 32, SQLITE_TRANSIENT);
  sqlite3_bind_int64(st, 2, purpose);
  if (token_hash != NULL) sqlite3_bind_blob(st, 3, token_hash, 32, SQLITE_STATIC);
  else sqlite3_bind_null(st, 3);
  sqlite3_bind_int64(st, 4, (sqlite3_int64)(now_ms + CHALLENGE_TTL_MS));
  return db_exec(st) == SQLITE_DONE ? AUTH_OK : AUTH_ERROR;
}

AuthResult auth_credential(Db *db, const uint8_t *id, uint32_t id_len, uint32_t *user,
                           uint8_t x[32], uint8_t y[32], uint32_t *count) {
  if (id_len == 0u || id_len > CRED_ID_MAX) return AUTH_INVALID;
  sqlite3_stmt *st = db->st[ST_CRED_GET];
  sqlite3_bind_blob(st, 1, id, (int)id_len, SQLITE_STATIC);
  int rc = sqlite3_step(st);
  AuthResult r = AUTH_ERROR;
  if (rc == SQLITE_ROW && sqlite3_column_bytes(st, 1) == 32 && sqlite3_column_bytes(st, 2) == 32) {
    *user = (uint32_t)sqlite3_column_int64(st, 0);
    memcpy(x, sqlite3_column_blob(st, 1), 32);
    memcpy(y, sqlite3_column_blob(st, 2), 32);
    sqlite3_int64 cnt = sqlite3_column_int64(st, 3);
    ASSERT(cnt >= 0 && cnt <= (sqlite3_int64)UINT32_MAX);
    *count = (uint32_t)cnt;
    r = AUTH_OK;
  } else if (rc == SQLITE_DONE) {
    r = AUTH_INVALID;
  }
  sqlite3_reset(st);
  sqlite3_clear_bindings(st);
  return r;
}

// Consumes a challenge. token_hash is NULL for login challenges.
static int32_t auth_use_challenge(Db *db, const uint8_t hash[32], uint32_t purpose, const uint8_t *token_hash,
                                  uint64_t now_ms) {
  sqlite3_stmt *st = db->st[ST_CHAL_USE];
  sqlite3_bind_blob(st, 1, hash, 32, SQLITE_STATIC);
  sqlite3_bind_int64(st, 2, purpose);
  sqlite3_bind_int64(st, 3, (sqlite3_int64)now_ms);
  if (token_hash != NULL) sqlite3_bind_blob(st, 4, token_hash, 32, SQLITE_STATIC);
  else sqlite3_bind_null(st, 4);
  return db_changes(db, st);
}

// A session inside the current transaction.
static AuthResult auth_session(Db *db, uint32_t user, uint64_t now_ms, uint8_t session[32]) {
  return db_session_new(db, user, now_ms, 30ull * 24ull * 3600ull * 1000ull, session) == 0 ? AUTH_OK : AUTH_ERROR;
}

AuthResult auth_register(Db *db, const uint8_t token_hash[32], const uint8_t challenge_hash[32],
                         const uint8_t *id, uint32_t id_len, const uint8_t x[32], const uint8_t y[32],
                         uint32_t count, uint64_t now_ms, uint32_t *user, uint8_t session[32]) {
  *user = 0;
  if (id_len < 16u || id_len > CRED_ID_MAX) return AUTH_INVALID;
  if (db_exec(db->st[ST_BEGIN]) != SQLITE_DONE) return AUTH_ERROR;
  // Read the token (purpose, email, name, user) before using it.
  sqlite3_stmt *st = db->st[ST_TOKEN_GET];
  sqlite3_bind_blob(st, 1, token_hash, 32, SQLITE_STATIC);
  sqlite3_bind_int64(st, 2, (sqlite3_int64)now_ms);
  int rc = sqlite3_step(st);
  if (rc != SQLITE_ROW) {
    sqlite3_reset(st);
    sqlite3_clear_bindings(st);
    return auth_rollback(db, rc == SQLITE_DONE ? AUTH_INVALID : AUTH_ERROR);
  }
  uint32_t purpose = (uint32_t)sqlite3_column_int64(st, 0);
  char email[256], name[128];
  int el = sqlite3_column_bytes(st, 1), nl = sqlite3_column_bytes(st, 2);
  ASSERT(el >= 0 && nl >= 0);
  if ((size_t)el >= sizeof email || (size_t)nl >= sizeof name) {
    sqlite3_reset(st);
    sqlite3_clear_bindings(st);
    return auth_rollback(db, AUTH_ERROR);
  }
  memcpy(email, sqlite3_column_text(st, 1), (size_t)el);
  memcpy(name, sqlite3_column_text(st, 2), (size_t)nl);
  uint32_t existing = (uint32_t)sqlite3_column_int64(st, 3);
  sqlite3_reset(st);
  sqlite3_clear_bindings(st);
  if (auth_use_challenge(db, challenge_hash, CHAL_REGISTER, token_hash, now_ms) != 1) {
    return auth_rollback(db, AUTH_INVALID);
  }
  st = db->st[ST_TOKEN_USE];
  sqlite3_bind_blob(st, 1, token_hash, 32, SQLITE_STATIC);
  sqlite3_bind_int64(st, 2, (sqlite3_int64)now_ms);
  if (db_changes(db, st) != 1) return auth_rollback(db, AUTH_INVALID);
  uint32_t uid = existing;
  if (purpose == AUTH_SIGNUP) {
    uid = db_user_new(db, (DbText){email, (uint32_t)el}, (DbText){name, (uint32_t)nl}, now_ms);
    if (uid == 0u) return auth_rollback(db, AUTH_EMAIL_TAKEN);
  }
  if (uid == 0u) return auth_rollback(db, AUTH_INVALID);
  st = db->st[ST_CRED_NEW];
  sqlite3_bind_blob(st, 1, id, (int)id_len, SQLITE_STATIC);
  sqlite3_bind_int64(st, 2, uid);
  sqlite3_bind_blob(st, 3, x, 32, SQLITE_STATIC);
  sqlite3_bind_blob(st, 4, y, 32, SQLITE_STATIC);
  sqlite3_bind_int64(st, 5, count);
  sqlite3_bind_int64(st, 6, (sqlite3_int64)now_ms);
  if (db_exec(st) != SQLITE_DONE) return auth_rollback(db, AUTH_INVALID);
  if (auth_session(db, uid, now_ms, session) != AUTH_OK) return auth_rollback(db, AUTH_ERROR);
  AuthResult r = auth_commit(db);
  if (r == AUTH_OK) *user = uid;
  return r;
}

AuthResult auth_login(Db *db, const uint8_t challenge_hash[32], const uint8_t *id, uint32_t id_len,
                      const uint8_t *msg, uint32_t msg_len, const uint8_t *sig, uint32_t sig_len,
                      uint64_t now_ms, uint32_t *user, uint8_t session[32]) {
  *user = 0;
  if (id_len == 0u || id_len > CRED_ID_MAX) return AUTH_INVALID;
  // authenticator data is at least 37 bytes; the clientDataJSON hash is 32.
  if (msg_len < 37u + 32u || msg_len > 4096u) return AUTH_INVALID;
  uint32_t count = ((uint32_t)msg[33] << 24) | ((uint32_t)msg[34] << 16) | ((uint32_t)msg[35] << 8) | (uint32_t)msg[36];
  if (db_exec(db->st[ST_BEGIN]) != SQLITE_DONE) return AUTH_ERROR;
  if (auth_use_challenge(db, challenge_hash, CHAL_LOGIN, NULL, now_ms) != 1) return auth_rollback(db, AUTH_INVALID);
  uint8_t x[32], y[32];
  uint32_t uid = 0, old = 0;
  AuthResult r = auth_credential(db, id, id_len, &uid, x, y, &old);
  if (r != AUTH_OK) return auth_rollback(db, r);
  if (auth_p256_verify(x, y, msg, msg_len, sig, sig_len) != 1) return auth_rollback(db, AUTH_INVALID);
  sqlite3_stmt *st = db->st[ST_CRED_COUNT];
  sqlite3_bind_blob(st, 1, id, (int)id_len, SQLITE_STATIC);
  sqlite3_bind_int64(st, 2, count);
  if (db_changes(db, st) != 1) return auth_rollback(db, AUTH_COUNTER);
  if (auth_session(db, uid, now_ms, session) != AUTH_OK) return auth_rollback(db, AUTH_ERROR);
  r = auth_commit(db);
  if (r == AUTH_OK) *user = uid;
  return r;
}

// COLLABORATIVE EDITING
// ---------------------

static uint32_t db_sync_rows[SYNC_OPS_MAX][7];

DbResult db_sync(Db *db, const uint8_t token_hash[32], uint64_t now_ms, const DbFacts *f,
                 uint32_t post, const char *ops, uint32_t ops_len, uint64_t since, DbOutFn out, void *ctx) {
  int32_t n = ops_parse(ops, ops_len, db_sync_rows, SYNC_OPS_MAX);
  if (n < 0) return DB_DENIED;
  DbWrite w = {.kind = A_SYNC_OPS, .target = post};
  if (!db_floor(f, &w)) return DB_DENIED;
  if (db_exec(db->st[ST_BEGIN]) != SQLITE_DONE) {
    fprintf(stderr, "db_apply: begin: %s\n", sqlite3_errmsg(db->conn));
    return DB_ERROR;
  }
  DbResult r = db_facts_hold(db, token_hash, now_ms, f);
  if (r != DB_OK) {
    auth_rollback(db, AUTH_OK);
    return r;
  }
  sqlite3_stmt *st = db->st[ST_OP_COUNT];
  sqlite3_bind_int64(st, 1, post);
  uint32_t have = 0;
  if (db_one_u32(st, &have) != 1 || have + (uint32_t)n > POST_OPS_MAX) {
    auth_rollback(db, AUTH_OK);
    return DB_CONFLICT;
  }
  for (int32_t i = 0; i < n; i++) {
    st = db->st[ST_OP_NEW];
    sqlite3_bind_int64(st, 1, post);
    for (int j = 0; j < 7; j++) sqlite3_bind_int64(st, j + 2, db_sync_rows[i][j]);
    if (db_exec(st) != SQLITE_DONE) {
      auth_rollback(db, AUTH_OK);
      return DB_CONFLICT;
    }
  }
  st = db->st[ST_OP_SINCE];
  sqlite3_bind_int64(st, 1, post);
  sqlite3_bind_int64(st, 2, (sqlite3_int64)since);
  // First pass: the rows, buffered by the caller; the max seq comes last.
  char line[128];
  uint64_t max = since, bytes = 0;
  int rc;
  while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
    uint64_t seq = (uint64_t)sqlite3_column_int64(st, 0);
    if (seq > max) max = seq;
    int ln = snprintf(line, sizeof line, "%lld.%lld.%lld.%lld.%lld.%lld.%lld;",
                      (long long)sqlite3_column_int64(st, 1), (long long)sqlite3_column_int64(st, 2),
                      (long long)sqlite3_column_int64(st, 3), (long long)sqlite3_column_int64(st, 4),
                      (long long)sqlite3_column_int64(st, 5), (long long)sqlite3_column_int64(st, 6),
                      (long long)sqlite3_column_int64(st, 7));
    ASSERT(ln > 0 && (size_t)ln < sizeof line);
    bytes += (uint64_t)ln;
    if (bytes > SYNC_OUT_MAX) break;
    out(ctx, line, (uint32_t)ln);
  }
  sqlite3_reset(st);
  sqlite3_clear_bindings(st);
  if (db_exec(db->st[ST_COMMIT]) != SQLITE_DONE) {
    auth_rollback(db, AUTH_OK);
    return DB_ERROR;
  }
  int ln = snprintf(line, sizeof line, "\n%llu", (unsigned long long)max);
  ASSERT(ln > 0);
  out(ctx, line, (uint32_t)ln);
  return DB_OK;
}
