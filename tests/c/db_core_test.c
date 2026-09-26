// Unit tests for src/c/db_core.c, focused on the fact re-check: honest,
// forged and stale facts, and the policy floor.
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "../../src/c/db_core.h"

static int fails = 0;
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #x); fails++; } } while (0)
#define T(s) ((DbText){(s), (uint32_t)strlen(s)})

static Db db;

static uint32_t rows_seen;
static void count_row(void *ctx, uint32_t n, const char *const *c, const uint32_t *l) {
  (void)ctx; (void)n; (void)c; (void)l;
  rows_seen++;
}
static int32_t q_rows(uint32_t q, uint32_t a, const uint8_t hash[32]) {
  rows_seen = 0;
  int32_t r = db_query(&db, q, a, 0, (DbText){"", 0}, hash, 1000000, count_row, NULL);
  return r < 0 ? -1 : (int32_t)rows_seen;
}
static const uint64_t NOW = 1000000;

typedef struct { uint32_t id; uint8_t token[32]; uint8_t hash[32]; } Who;

static Who user(const char *email) {
  Who w;
  w.id = db_user_new(&db, T(email), T("x"), NOW);
  CHECK(w.id != 0u);
  CHECK(db_session_new(&db, w.id, NOW, 3600000, w.token) == 0);
  db_token_hash(w.token, w.hash);
  return w;
}

static DbFacts facts(Who *w, uint32_t blog, uint32_t post) {
  DbFacts f;
  uint32_t who = db_session_user(&db, w->hash, NOW);
  CHECK(db_load_facts(&db, who, blog, post, &f) == DB_OK);
  return f;
}

static DbResult apply(Who *w, DbFacts f, DbWrite x, uint32_t *id) {
  uint32_t dummy;
  return db_apply(&db, w->hash, NOW, &f, &x, id ? id : &dummy);
}

int main(void) {
  const char *path = "/tmp/claude-db-core-test.db";
  unlink(path);
  if (db_open(&db, path) != 0) {
    fprintf(stderr, "FAIL: db_open\n");
    return 1;
  }
  Who a = user("a@x.io"), b = user("b@x.io"), c = user("c@x.io");

  // Honest flow: A creates a blog, adds B, B writes a post.
  uint32_t blog = 0, post = 0;
  CHECK(apply(&a, facts(&a, 0, 0), (DbWrite){.kind = A_CREATE_BLOG, .slug = T("a-blog"), .title = T("A")}, &blog) == DB_OK);
  CHECK(blog != 0u);
  CHECK(facts(&a, blog, 0).role == ROLE_OWNER);
  CHECK(apply(&a, facts(&a, blog, 0), (DbWrite){.kind = A_ADD_AUTHOR, .target = blog, .user = b.id}, NULL) == DB_OK);
  CHECK(apply(&b, facts(&b, blog, 0), (DbWrite){.kind = A_CREATE_POST, .target = blog, .slug = T("p1"), .title = T("P")}, &post) == DB_OK);
  CHECK(apply(&b, facts(&b, 0, post), (DbWrite){.kind = A_EDIT_POST, .target = post, .title = T("P2"), .body_md = T("m"), .body_html = T("<p>m</p>")}, NULL) == DB_OK);

  // Read floors: a draft is invisible to an outsider and to anonymous.
  uint8_t nobody[32] = {0};
  const char *html; uint32_t hlen;
  CHECK(q_rows(Q_POST_VIEW, post, b.hash) == 1);
  CHECK(q_rows(Q_POST_VIEW, post, c.hash) == 0);
  CHECK(q_rows(Q_POST_VIEW, post, nobody) == 0);
  CHECK(q_rows(Q_POSTS_MEMBER, blog, a.hash) == 1);
  CHECK(q_rows(Q_POSTS_MEMBER, blog, c.hash) == 0);
  CHECK(q_rows(Q_POST_MD, post, c.hash) == 0);
  CHECK(q_rows(Q_POST_MD, post, b.hash) == 1);
  CHECK(q_rows(Q_AUTHORS, blog, c.hash) == 0);
  CHECK(q_rows(Q_AUTHORS, blog, a.hash) == 2);
  CHECK(q_rows(Q_POSTS_PUBLIC, blog, a.hash) == 0);
  CHECK(q_rows(Q_RECENT_PUBLIC, 0, nobody) == 0);
  CHECK(db_body(&db, post, c.hash, NOW, &html, &hlen) == 0);
  CHECK(db_body(&db, post, b.hash, NOW, &html, &hlen) == 1 && hlen == 8 && memcmp(html, "<p>m</p>", 8) == 0);
  CHECK(db_body(&db, post, b.hash, NOW + 3600001, &html, &hlen) == 0);
  CHECK(q_rows(Q_MY_BLOGS, 0, b.hash) == 1);
  CHECK(q_rows(Q_MY_BLOGS, 0, nobody) == 0);
  CHECK(q_rows(99, 0, a.hash) == -1);

  // Outsider with honest facts: the floor denies.
  CHECK(apply(&c, facts(&c, 0, post), (DbWrite){.kind = A_EDIT_POST, .target = post, .title = T("x")}, NULL) == DB_DENIED);

  // Outsider forging a role: the re-check catches it.
  DbFacts forged = facts(&c, 0, post);
  forged.role = ROLE_AUTHOR;
  CHECK(apply(&c, forged, (DbWrite){.kind = A_EDIT_POST, .target = post, .title = T("x")}, NULL) == DB_STALE);

  // Outsider claiming to be A while holding their own session.
  DbFacts as_a = facts(&a, 0, post);
  CHECK(apply(&c, as_a, (DbWrite){.kind = A_EDIT_POST, .target = post, .title = T("x")}, NULL) == DB_STALE);

  // Forged post location: claims the post is in C's own blog.
  uint32_t cblog = 0;
  CHECK(apply(&c, facts(&c, 0, 0), (DbWrite){.kind = A_CREATE_BLOG, .slug = T("c-blog"), .title = T("C")}, &cblog) == DB_OK);
  DbFacts moved = facts(&c, cblog, 0);
  moved.has_post = 1; moved.post = post; moved.post_blog = cblog; moved.post_pub = 0;
  CHECK(apply(&c, moved, (DbWrite){.kind = A_DELETE_POST, .target = post}, NULL) == DB_STALE);

  // TOCTOU: B loads facts, A removes B, B's write must fail.
  DbFacts before = facts(&b, 0, post);
  CHECK(apply(&a, facts(&a, blog, 0), (DbWrite){.kind = A_REMOVE_AUTHOR, .target = blog, .user = b.id}, NULL) == DB_OK);
  CHECK(apply(&b, before, (DbWrite){.kind = A_EDIT_POST, .target = post, .title = T("late")}, NULL) == DB_STALE);

  // Stale published flag: facts say draft, post is now published.
  DbFacts draft = facts(&a, 0, post);
  CHECK(apply(&a, facts(&a, 0, post), (DbWrite){.kind = A_PUBLISH_POST, .target = post, .flag = 1}, NULL) == DB_OK);
  // Once published, everyone sees it.
  CHECK(q_rows(Q_POST_VIEW, post, nobody) == 1);
  CHECK(q_rows(Q_POSTS_PUBLIC, blog, nobody) == 1);
  CHECK(q_rows(Q_RECENT_PUBLIC, 0, nobody) == 1);
  CHECK(db_body(&db, post, nobody, NOW, &html, &hlen) == 1);
  CHECK(apply(&a, draft, (DbWrite){.kind = A_EDIT_POST, .target = post, .title = T("t")}, NULL) == DB_STALE);

  // The owner cannot remove themself: the floor denies; forging past the
  // floor still cannot delete an owner row (SQL deletes role 2 only, and a
  // trigger forbids it).
  CHECK(apply(&a, facts(&a, blog, 0), (DbWrite){.kind = A_REMOVE_AUTHOR, .target = blog, .user = a.id}, NULL) == DB_DENIED);
  CHECK(facts(&a, blog, 0).role == ROLE_OWNER);

  // Logout ends the session server-side.
  Who d = user("d@x.io");
  CHECK(db_session_user(&db, d.hash, NOW) == d.id);
  CHECK(db_session_end(&db, d.hash) == 0);
  CHECK(db_session_user(&db, d.hash, NOW) == 0u);

  // Expired session.
  CHECK(db_session_user(&db, a.hash, NOW + 3600001) == 0u);
  DbFacts af = facts(&a, blog, 0);
  DbWrite edit = {.kind = A_EDIT_BLOG, .target = blog, .title = T("new")};
  uint32_t id;
  CHECK(db_apply(&db, a.hash, NOW + 3600001, &af, &edit, &id) == DB_STALE);

  // Duplicate slug: constraint conflict, and the transaction rolled back.
  CHECK(apply(&a, facts(&a, 0, 0), (DbWrite){.kind = A_CREATE_BLOG, .slug = T("a-blog"), .title = T("dup")}, NULL) == DB_CONFLICT);
  // Invalid slug reaches the schema CHECK.
  CHECK(apply(&a, facts(&a, 0, 0), (DbWrite){.kind = A_CREATE_BLOG, .slug = T("../x"), .title = T("bad")}, NULL) == DB_CONFLICT);

  // Unknown action kind.
  CHECK(apply(&a, facts(&a, blog, 0), (DbWrite){.kind = 99}, NULL) == DB_DENIED);

  // Deleting the blog cascades (owner row included).
  CHECK(apply(&a, facts(&a, blog, 0), (DbWrite){.kind = A_DELETE_BLOG, .target = blog}, NULL) == DB_OK);
  CHECK(facts(&a, blog, 0).role == ROLE_NONE);

  db_close(&db);
  unlink(path);
  if (fails == 0) printf("db_core_test: all passed\n");
  return fails != 0;
}
