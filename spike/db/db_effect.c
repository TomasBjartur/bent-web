// Spike effect: Db.recent_titles(blog_id, n) -> List<String>.
// Runs the query on a Bend IO helper thread (io_work). Each helper thread
// keeps its own read-only connection and prepared statement.
// Spike code: partial C_STYLE (asserts, limits), not the final contract.
#include "/home/claude/web/vendor/sqlite/sqlite3.h"

#define DB_ROWS_MAX 100
#define DB_ROW_BYTES_MAX 512
#define DB_ASSERT(x) do { if (!(x)) { fprintf(stderr, "ASSERT %s:%d %s\n", __FILE__, __LINE__, #x); abort(); } } while (0)

static __thread sqlite3*      db_conn;
static __thread sqlite3_stmt* db_recent;

static int db_open_thread(void) {
  if (db_conn) return 0;
  const char* path = getenv("BLOG_DB");
  if (!path) path = "blog.db";
  if (sqlite3_open_v2(path, &db_conn, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, NULL)) return 1;
  sqlite3_db_config(db_conn, SQLITE_DBCONFIG_DEFENSIVE, 1, NULL);
  sqlite3_busy_timeout(db_conn, 1000);
  const char* sql = "SELECT title FROM post WHERE blog_id = ?1 ORDER BY created_ms DESC LIMIT ?2";
  if (sqlite3_prepare_v3(db_conn, sql, -1, SQLITE_PREPARE_PERSISTENT, &db_recent, NULL)) return 1;
  return 0;
}

// Helper thread: touches only w. Packs rows as [u32 len][bytes]...
static void db_recent_call(IoWork* w) {
  if (db_open_thread()) { w->code = EIO; return; }
  u32 blog = (u32)w->hand, n = w->word;
  DB_ASSERT(n <= DB_ROWS_MAX);
  sqlite3_bind_int64(db_recent, 1, blog);
  sqlite3_bind_int64(db_recent, 2, n);
  u64 o = 0;
  u32 rows = 0;
  while (rows < n && sqlite3_step(db_recent) == SQLITE_ROW) {
    const unsigned char* t = sqlite3_column_text(db_recent, 0);
    int len = sqlite3_column_bytes(db_recent, 0);
    DB_ASSERT(len >= 0);
    if (len > DB_ROW_BYTES_MAX) len = DB_ROW_BYTES_MAX;
    u32 l = (u32)len;
    memcpy(w->data + o, &l, 4);
    memcpy(w->data + o + 4, t, l);
    o += 4 + l;
    rows++;
  }
  sqlite3_reset(db_recent);
  DB_ASSERT(rows <= n);
  w->made = rows;
  w->size = o;
}

static Term db_recent_pack(Env e, IoWork* w) {
  if (w->code) { free(w->data); return io_fail(e, w->code, NULL); }
  // Build the list back to front: record offsets first.
  u64 offs[DB_ROWS_MAX];
  u64 o = 0;
  for (intptr_t i = 0; i < w->made; i++) { offs[i] = o; u32 l; memcpy(&l, w->data + o, 4); o += 4 + l; }
  DB_ASSERT(o == w->size);
  Term xs = term_pak(CID(Nil), 0);
  for (intptr_t i = w->made; i > 0; i--) {
    u32 l; memcpy(&l, w->data + offs[i - 1], 4);
    xs = io_node(e, CID(Con), io_str(e, w->data + offs[i - 1] + 4, l), xs);
  }
  free(w->data);
  return io_done(e, xs);
}

Term db_recent_titles_run(Env e, Term* f, IoWork* w) {
  u32 n = (u32)f[1];
  if (n > DB_ROWS_MAX) n = DB_ROWS_MAX;
  w->hand = (intptr_t)(u32)f[0];
  w->word = n;
  w->code = 0;
  w->data = io_mem(malloc((u64)n * (4 + DB_ROW_BYTES_MAX) + 1));
#ifdef DB_SYNC
  db_recent_call(w);  // run inline on the event loop: no thread handoff
  return db_recent_pack(e, w);
#else
  return io_work(w, db_recent_call, db_recent_pack);
#endif
}

static void __attribute__((constructor)) db_recent_titles_use(void) {
  io_eff(CID(Db.recent_titles), db_recent_titles_run, 0);
}
