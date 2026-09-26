// EFFECTS: db_open, session_user, session_new, session_end, load_facts,
//          apply_raw, query, page.
// WHY C:  SQLite (src/c/db_core.c), crypto (BearSSL), and sending pages
//         whose stored post bodies never become Bend Strings.
// PRE:    called only by the Bend event loop thread.
// POST:   per effect below.
// LAWS THAT DEPEND ON THIS: authz_permit_ok is about Permits; apply_raw
//         re-checks a Permit's facts against the database before writing
//         (db_apply), and every private read has a membership floor in SQL.
//         apply_raw must only be called from src/db.bend's apply (checked by
//         tools/lint.sh).
// VERIFIED BY: tests/c/db_core_test.c (the core), tests/app_test.py
//         (integration).
//
// Spliced into the Bend program's C source after the runtime; includes the
// cores by paths relative to build/.
#include "../src/effects/app_common.h"
#include "../src/effects/app_shared.h"

// WRITE GENERATION
// ----------------
// Moved by every successful apply_raw: every write that can change a
// public page goes through it (src/db.bend's apply; tools/lint.sh). The
// page cache below serves an entry only if nothing it depends on moved
// since, so a publish, unpublish, edit or delete is visible at once, in
// every worker process (the counters are in app_shared.h):
// - write_gen: feeds, search, RSS (any public write);
// - post_gen: every post page (blog-wide writes: a blog's title or
//   deletion, scheduled publishing);
// - post_ver[post]: one post's page (a write to the post, its likes or
//   comments).
static void app_post_moved(uint32_t post) {
  atomic_fetch_add(&app_shared->post_ver[app_post_slot(post)], 1u);
}
static void live_wake(uint32_t post);
static void live_init(void);

// SCHEDULED POSTS
// ---------------
// tick(): called at the start of every request; at most every
// TICK_INTERVAL_MS (tests: BLOG_TICK_MS) it publishes scheduled posts that
// are due. Publishing is observed only through requests, so checking on
// requests is enough.
#define TICK_INTERVAL_MS 10000ull

#ifdef CID(tick)
static uint64_t app_next_tick = 0;
static uint64_t app_tick_ms = TICK_INTERVAL_MS;

Term tick_run(Env e, Term *f, IoWork *w) {
  (void)f;
  (void)w;
  ASSERT(app_db_ready);
  uint64_t now = app_now_ms();
  if (now >= app_next_tick) {
    app_next_tick = now + app_tick_ms;
    if (db_publish_due(&app_db, now) > 0) {
      atomic_fetch_add(&app_shared->write_gen, 1u);
      atomic_fetch_add(&app_shared->post_gen, 1u);
    }
  }
  return term_pak(CID(Unit), 0);
}

static void __attribute__((constructor)) tick_use(void) {
  io_eff(CID(tick), tick_run, 0);
}
#endif

// OPEN
// ----

#ifdef CID(db_open)

#ifdef CID(query_off)
static int32_t off_open(const char *path);
#endif

Term db_open_run(Env e, Term *f, IoWork *w) {
  (void)w;
  u64 n = 0;
  char *path = io_cstr(e, f[0], &n);
  int32_t r = app_db_ready ? -1 : db_open(&app_db, path);
#ifdef CID(query_off)
  if (r == 0) r = off_open(path);
#endif
  free(path);
  if (r != 0) return io_fail(e, EIO, "cannot open the database");
  app_db_ready = 1;
  live_init();
#ifdef CID(tick)
  const char *t = getenv("BLOG_TICK_MS");
  if (t != NULL && t[0] >= '0' && t[0] <= '9') app_tick_ms = strtoull(t, NULL, 10) <= 60000ull ? strtoull(t, NULL, 10) : TICK_INTERVAL_MS;
#endif
  return io_done(e, term_pak(CID(Unit), 0));
}

static void __attribute__((constructor)) db_open_use(void) {
  io_eff(CID(db_open), db_open_run, 0);
}

#endif

// SESSIONS
// --------

#ifdef CID(session_user)

// The user id of an unexpired session token, or 0.
Term session_user_run(Env e, Term *f, IoWork *w) {
  (void)w;
  ASSERT(app_db_ready);
  uint8_t h[32];
  app_token_hash(e, f[0], h);
  return (Term)db_session_user(&app_db, h, app_now_ms());
}

static void __attribute__((constructor)) session_user_use(void) {
  io_eff(CID(session_user), session_user_run, 0);
}

#endif

#ifdef CID(session_new)

// A new session for user: answers its token as 64 hex characters.
Term session_new_run(Env e, Term *f, IoWork *w) {
  (void)w;
  ASSERT(app_db_ready);
  uint32_t user = (uint32_t)f[0];
  uint8_t raw[TOKEN_BYTES], hex[TOKEN_HEX];
  if (user == 0u || db_session_new(&app_db, user, app_now_ms(), SESSION_TTL_MS, raw) != 0) {
    return io_fail(e, EIO, "cannot create a session");
  }
  token_encode(raw, hex);
  explicit_bzero(raw, sizeof raw);
  Term s = io_str(e, (const char *)hex, TOKEN_HEX);
  explicit_bzero(hex, sizeof hex);
  return io_done(e, s);
}

static void __attribute__((constructor)) session_new_use(void) {
  io_eff(CID(session_new), session_new_run, 0);
}

#endif

#ifdef CID(session_end)

// Ends a session (logout). Ill-formed tokens are ignored.
Term session_end_run(Env e, Term *f, IoWork *w) {
  (void)w;
  ASSERT(app_db_ready);
  uint8_t h[32];
  app_token_hash(e, f[0], h);
  (void)db_session_end(&app_db, h);
  return term_pak(CID(Unit), 0);
}

static void __attribute__((constructor)) session_end_use(void) {
  io_eff(CID(session_end), session_end_run, 0);
}

#endif

// FACTS AND WRITES
// ----------------

#ifdef CID(load_facts)

// [who, blog, role, has_post, post, post_blog, post_pub]
Term load_facts_run(Env e, Term *f, IoWork *w) {
  (void)w;
  ASSERT(app_db_ready);
  DbFacts x;
  if (db_load_facts(&app_db, (uint32_t)f[0], (uint32_t)f[1], (uint32_t)f[2], &x) != DB_OK) {
    memset(&x, 0, sizeof x);
    x.who = (uint32_t)f[0];
  }
  uint32_t v[7] = {x.who, x.blog, x.role, x.has_post, x.post, x.post_blog, x.post_pub};
  Term xs = term_pak(CID(Nil), 0);
  for (uint32_t i = 7; i > 0u; i--) xs = io_node(e, CID(Con), (Term)v[i - 1u], xs);
  return xs;
}

static void __attribute__((constructor)) load_facts_use(void) {
  io_eff(CID(load_facts), load_facts_run, 0);
}

#endif

#ifdef CID(apply_raw)

// f: token, who, blog, role, has_post, post, post_blog, post_pub,
//    kind, target, user, flag, slug, title, body_md, body_html.
// Answers the new id (0 if none), or fails with DbResult as the code.
Term apply_raw_run(Env e, Term *f, IoWork *w) {
  (void)w;
  ASSERT(app_db_ready);
  uint8_t h[32];
  app_token_hash(e, f[0], h);
  DbFacts x = {(uint32_t)f[1], (uint32_t)f[2], (uint32_t)f[3], (uint32_t)f[4],
               (uint32_t)f[5], (uint32_t)f[6], (uint32_t)f[7]};
  u64 n1 = 0, n2 = 0, n3 = 0, n4 = 0;
  char *slug = io_cstr(e, f[12], &n1);
  char *title = io_cstr(e, f[13], &n2);
  char *md = io_cstr(e, f[14], &n3);
  char *html = io_cstr(e, f[15], &n4);
  Term r;
  if (n1 > UINT32_MAX || n2 > UINT32_MAX || n3 > UINT32_MAX || n4 > UINT32_MAX) {
    r = io_fail(e, DB_ERROR, NULL);
  } else {
    DbWrite wr = {(uint32_t)f[8], (uint32_t)f[9], (uint32_t)f[10], (uint32_t)f[11],
                  {slug, (uint32_t)n1}, {title, (uint32_t)n2}, {md, (uint32_t)n3}, {html, (uint32_t)n4}};
    uint32_t id = 0;
    DbResult res = db_apply(&app_db, h, app_now_ms(), &x, &wr, &id);
    if (res == DB_OK && db_write_is_public(&x, &wr)) atomic_fetch_add(&app_shared->write_gen, 1u);
    if (res == DB_OK && db_write_is_blog_wide(&wr)) atomic_fetch_add(&app_shared->post_gen, 1u);
    // A like, a comment, or an edit, publication or deletion of a post
    // changes only that post's page (cached for signed-out visitors under
    // "p0:<post id>").
    if (res == DB_OK && db_write_is_post_page(&wr) && x.has_post) app_post_moved(x.post);
    // A new comment wakes whoever is waiting for this post's comments: in
    // this process at once, in the others at their next look (live below).
    if (res == DB_OK && wr.kind == A_COMMENT && x.has_post) {
      atomic_fetch_add(&app_shared->comment_ver[app_post_slot(x.post)], 1u);
      live_wake(x.post);
    }
    r = res == DB_OK ? io_done(e, (Term)id) : io_fail(e, (uint32_t)res, NULL);
  }
  free(slug);
  free(title);
  free(md);
  free(html);
  return r;
}

static void __attribute__((constructor)) apply_raw_use(void) {
  io_eff(CID(apply_raw), apply_raw_run, 0);
}

#endif

// QUERIES
// -------
// Rows are copied into a static arena, then built into Bend lists back to
// front. Text is UTF-8 from SQLite, decoded to code points by io_str.

#ifdef CID(query)

#define APP_ARENA_BYTES (4u * 1024u * 1024u)
#define APP_CELLS_MAX (DB_ROWS_MAX * DB_COLS_MAX)

static char app_arena[APP_ARENA_BYTES];
static uint32_t app_cell_off[APP_CELLS_MAX], app_cell_len[APP_CELLS_MAX], app_row_cols[DB_ROWS_MAX];

// Where one query's rows go: an arena of arena_bytes, and per cell its
// offset and length, per row its column count.
typedef struct {
  char *arena;
  uint32_t *cell_off, *cell_len, *row_cols;
  uint32_t arena_bytes, used, cells, rows, overflow;
} AppRows;

static void app_row(void *ctx, uint32_t ncols, const char *const *cols, const uint32_t *lens) {
  AppRows *a = ctx;
  ASSERT(a->rows < DB_ROWS_MAX && ncols <= DB_COLS_MAX);
  for (uint32_t i = 0; i < ncols; i++) {
    if (lens[i] > a->arena_bytes - a->used) {
      a->overflow = 1;
      return;
    }
    memcpy(a->arena + a->used, cols[i], lens[i]);
    a->cell_off[a->cells] = a->used;
    a->cell_len[a->cells] = lens[i];
    a->used += lens[i];
    a->cells++;
  }
  a->row_cols[a->rows] = ncols;
  a->rows++;
}

// The rows as a Bend List<List<String>> (built back to front).
static Term app_rows_term(Env e, const AppRows *a) {
  ASSERT(a->cells <= APP_CELLS_MAX && a->rows <= DB_ROWS_MAX);
  Term rows = term_pak(CID(Nil), 0);
  uint32_t cell = a->cells;
  for (uint32_t r = a->rows; r > 0u; r--) {
    Term cols = term_pak(CID(Nil), 0);
    for (uint32_t c = a->row_cols[r - 1u]; c > 0u; c--) {
      cell--;
      cols = io_node(e, CID(Con), io_str(e, a->arena + a->cell_off[cell], a->cell_len[cell]), cols);
    }
    rows = io_node(e, CID(Con), cols, rows);
  }
  ASSERT(cell == 0u);
  return rows;
}

// f: q, a, b, text, token. Answers List<List<String>>; empty on error.
Term query_run(Env e, Term *f, IoWork *w) {
  (void)w;
  ASSERT(app_db_ready);
  uint8_t h[32];
  app_token_hash(e, f[4], h);
  u64 tn = 0;
  char *text = io_cstr(e, f[3], &tn);
  AppRows a = {app_arena, app_cell_off, app_cell_len, app_row_cols, APP_ARENA_BYTES, 0, 0, 0, 0};
  int32_t n = tn > UINT32_MAX ? -1
    : db_query(&app_db, (uint32_t)f[0], (uint32_t)f[1], (uint32_t)f[2], (DbText){text, (uint32_t)tn},
               h, app_now_ms(), app_row, &a);
  free(text);
  if (n < 0 || a.overflow) return term_pak(CID(Nil), 0);
  return app_rows_term(e, &a);
}

static void __attribute__((constructor)) query_use(void) {
  io_eff(CID(query), query_run, 0);
}

#ifdef CID(query_off)
// OFF THE EVENT LOOP: query_off(q, a, b, text, token) is query run on a
// helper thread, on one of SEARCH_SLOTS read-only connections, stopped
// after SEARCH_BUDGET_MS. For queries whose cost depends on the data and
// the input (search): one slow search then delays no other request. Only
// this (loop) thread takes and frees slots; a helper thread uses only its
// own slot. With every slot busy, or on error or timeout, the answer is 2
// (busy) or 1 (failed) and no rows.
#define SEARCH_SLOTS 4u
#define SEARCH_BUDGET_MS 2000u
#define SEARCH_ARENA_BYTES (256u * 1024u)
#define SEARCH_TEXT_MAX 8192u  // a search's FTS query (src/text.bend fts_query: at most 8 words)

typedef struct {
  DbReader reader;
  uint32_t busy;
  uint32_t q, a, b;
  char text[SEARCH_TEXT_MAX];
  uint32_t text_len;
  uint8_t hash[32];
  uint64_t now_ms;
  int32_t n;
  char arena[SEARCH_ARENA_BYTES];
  uint32_t cell_off[APP_CELLS_MAX], cell_len[APP_CELLS_MAX], row_cols[DB_ROWS_MAX];
  AppRows rows;
} OffSlot;

static OffSlot off_slots[SEARCH_SLOTS];

static int32_t off_open(const char *path) {
  for (uint32_t i = 0; i < SEARCH_SLOTS; i++) {
    if (db_reader_open(&off_slots[i].reader, path) != 0) return -1;
  }
  return 0;
}

static void off_call(IoWork *w) {
  OffSlot *s = &off_slots[w->code];
  ASSERT(w->code < SEARCH_SLOTS && s->busy == 1u);
  s->rows = (AppRows){s->arena, s->cell_off, s->cell_len, s->row_cols, SEARCH_ARENA_BYTES, 0, 0, 0, 0};
  s->n = db_reader_query(&s->reader, s->q, s->a, s->b, (DbText){s->text, s->text_len}, s->hash, s->now_ms,
                         SEARCH_BUDGET_MS, app_row, &s->rows);
}

// Answers (status, rows): 0 done, 1 failed, 2 busy.
static Term off_answer(Env e, uint32_t status, Term rows) {
  ASSERT(status <= 2u);
  return io_tup(e, (Term)status, rows);
}

static Term off_pack(Env e, IoWork *w) {
  OffSlot *s = &off_slots[w->code];
  ASSERT(w->code < SEARCH_SLOTS && s->busy == 1u);
  Term r = s->n < 0 || s->rows.overflow ? off_answer(e, 1u, term_pak(CID(Nil), 0))
                                        : off_answer(e, 0u, app_rows_term(e, &s->rows));
  s->busy = 0;
  return r;
}

Term query_off_run(Env e, Term *f, IoWork *w) {
  ASSERT(app_db_ready);
  uint32_t slot = SEARCH_SLOTS;
  for (uint32_t i = 0; i < SEARCH_SLOTS; i++) {
    if (off_slots[i].busy == 0u) {
      slot = i;
      break;
    }
  }
  if (slot == SEARCH_SLOTS) return off_answer(e, 2u, term_pak(CID(Nil), 0));
  OffSlot *s = &off_slots[slot];
  u64 tn = 0;
  char *text = io_cstr(e, f[3], &tn);
  if (tn > sizeof s->text) {
    free(text);
    return off_answer(e, 1u, term_pak(CID(Nil), 0));
  }
  memcpy(s->text, text, tn);
  free(text);
  s->text_len = (uint32_t)tn;
  s->q = (uint32_t)f[0];
  s->a = (uint32_t)f[1];
  s->b = (uint32_t)f[2];
  app_token_hash(e, f[4], s->hash);
  s->now_ms = app_now_ms();
  s->busy = 1;
  w->code = slot;
  return io_work(w, off_call, off_pack);
}

static void __attribute__((constructor)) query_off_use(void) {
  io_eff(CID(query_off), query_off_run, 0);
}
#endif

#endif

// PAGES
// -----
// page(sock, status, ctype, texts, bodies, token, cookie, location): sends
// texts[0] body[0] texts[1] body[1] ... texts[n] as one response. Each body
// is a post id whose stored HTML is spliced in only if the post is published
// or the session is a member of its blog (db_body's floor); otherwise
// nothing is spliced. cookie: "" (none), "-" (clear) or a 64-hex token to
// set. location: "" or a path for a 303 redirect.

static const char *page_reason(uint32_t s) {
  switch (s) {
    case 200: return "OK";
    case 303: return "See Other";
    case 400: return "Bad Request";
    case 403: return "Forbidden";
    case 404: return "Not Found";
    case 405: return "Method Not Allowed";
    case 409: return "Conflict";
    case 204: return "No Content";
    case 413: return "Content Too Large";
    case 429: return "Too Many Requests";
    case 500: return "Internal Server Error";
    default: return NULL;
  }
}

static const char *const page_ctypes[] = {
  "text/html; charset=utf-8",
  "text/plain; charset=utf-8",
  "text/event-stream",
  "application/json",
  "text/css; charset=utf-8",
  "text/javascript; charset=utf-8",
  "application/rss+xml; charset=utf-8",
};

// A redirect target: starts with "/", not "//", only unreserved characters
// and "/", "?", "=", "&", "%", "#".
// Or an absolute http(s) URL (a custom domain sends readers to the main
// site), with ':' allowed; the character set still excludes CR, LF,
// spaces and quotes, so a Location header can never be split.
static int page_path_ok(const char *p, u64 n) {
  u64 from = 0;
  if (n > 8u && memcmp(p, "https://", 8) == 0) from = 8;
  else if (n > 7u && memcmp(p, "http://", 7) == 0) from = 7;
  if (n == 0u || n > 512u) return 0;
  if (from == 0u && (p[0] != '/' || (n > 1u && p[1] == '/'))) return 0;
  for (u64 i = from; i < n; i++) {
    if (from != 0u && p[i] == ':') continue;
    unsigned char c = (unsigned char)p[i];
    int ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
             c == '-' || c == '.' || c == '_' || c == '~' || c == '/' || c == '?' || c == '=' ||
             c == '&' || c == '%' || c == '#';
    if (!ok) return 0;
  }
  return 1;
}

typedef struct {
  char *buf;
  u64 len, cap;
  int overflow;
} PageOut;

static void page_put(PageOut *o, const char *p, u64 n) {
  if (o->overflow || n > RESPONSE_BYTES_MAX - o->len) {
    o->overflow = 1;
    return;
  }
  if (o->len + n > o->cap) {
    u64 cap = o->cap * 2u;
    while (cap < o->len + n) cap *= 2u;
    o->buf = io_mem(realloc(o->buf, cap));
    o->cap = cap;
  }
  memcpy(o->buf + o->len, p, n);
  o->len += n;
}

// A body id with this bit set is a comment's (src/db.bend: comment_body).
#define PAGE_COMMENT_BIT 0x80000000u

static void page_body_put(void *ctx, const char *p, uint32_t n) {
  page_put((PageOut *)ctx, p, n);
}

// NONCES AND DATASTAR STREAMS
// ----------------------------
// A page's <html data-nonce="..."> holds PAGE_NONCE_MARK (from
// src/pages.bend nonce_mark): 32 bytes starting and ending with byte 1,
// which the proved escaper never emits and stored HTML never contains, so
// only a template can write it. Each response replaces it with a fresh
// random nonce (32 hex digits), the one its CSP header allows; a cached
// page gets a new one each time it is served.
static const char PAGE_NONCE_MARK[] = "\x01" "NONCE-MARK-0000000000000000000" "\x01";
#define PAGE_NONCE_LEN 32u

// Fills nonce (32 hex + NUL) and writes it over the mark in body, if any.
static void page_nonce(PageOut *body, char nonce[PAGE_NONCE_LEN + 1u]) {
  _Static_assert(sizeof PAGE_NONCE_MARK - 1u == PAGE_NONCE_LEN, "nonce mark length");
  uint8_t raw[PAGE_NONCE_LEN / 2u];
  if (getrandom(raw, sizeof raw, 0) != (ssize_t)sizeof raw) err_fail("getrandom");
  static const char hx[] = "0123456789abcdef";
  for (uint32_t i = 0; i < sizeof raw; i++) {
    nonce[2u * i] = hx[raw[i] >> 4];
    nonce[2u * i + 1u] = hx[raw[i] & 15u];
  }
  nonce[PAGE_NONCE_LEN] = 0;
  char *m = body->len >= PAGE_NONCE_LEN ? memmem(body->buf, body->len, PAGE_NONCE_MARK, PAGE_NONCE_LEN) : NULL;
  if (m != NULL) memcpy(m, nonce, PAGE_NONCE_LEN);
}

// Content type 2 (text/event-stream): the body the templates made is a
// list of patches, each "selector \x1f mode \x1f html \x1e" (bytes 31 and
// 30: like the mark, never in escaped text or stored HTML). Rewritten as
// Datastar SSE events: event: datastar-patch-elements, data: selector,
// data: mode, and one data: elements line per line of HTML.
static PageOut page_sse(const PageOut *in) {
  PageOut out = {io_mem(malloc(in->len + 256u)), 0, in->len + 256u, 0};
  const char *p = in->buf, *end = in->buf + in->len;
  for (uint32_t guard = 0; p < end && guard < 100000u; guard++) {
    const char *rec = memchr(p, 0x1e, (size_t)(end - p));
    if (rec == NULL) rec = end;
    const char *f1 = memchr(p, 0x1f, (size_t)(rec - p));
    const char *f2 = f1 != NULL ? memchr(f1 + 1, 0x1f, (size_t)(rec - f1 - 1)) : NULL;
    if (f2 != NULL) {
      page_put(&out, "event: datastar-patch-elements\n", 31);
      if (f1 > p) {
        page_put(&out, "data: selector ", 15);
        page_put(&out, p, (u64)(f1 - p));
        page_put(&out, "\n", 1);
      }
      if (f2 > f1 + 1) {
        page_put(&out, "data: mode ", 11);
        page_put(&out, f1 + 1, (u64)(f2 - f1 - 1));
        page_put(&out, "\n", 1);
      }
      for (const char *l = f2 + 1; l < rec;) {
        const char *nl = memchr(l, '\n', (size_t)(rec - l));
        const char *le = nl != NULL ? nl : rec;
        page_put(&out, "data: elements ", 15);
        page_put(&out, l, (u64)(le - l));
        page_put(&out, "\n", 1);
        l = nl != NULL ? nl + 1 : rec;
      }
      page_put(&out, "\n", 1);
    }
    p = rec + 1;
  }
  if (in->overflow) out.overflow = 1;
  return out;
}

static Term page_more(Env e, IoWork *w) {
  int fd = (int)w->hand;
  u64 deadline = (u64)(uintptr_t)w->text;
  for (uint32_t step = 0; step < RESPONSE_BYTES_MAX && (u64)w->made < w->size; step++) {
    ssize_t n = send(fd, w->data + w->made, w->size - (u64)w->made, MSG_NOSIGNAL);
    if (n < 0 && errno == EAGAIN) {
      if (io_tick() >= deadline) break;
      return io_wait_on(w, fd, POLLOUT, deadline, page_more);
    }
    if (n <= 0) break;
    w->made += n;
  }
  int done = (u64)w->made == w->size;
  free(w->data);
  if (done) {
    shutdown(fd, SHUT_WR);
    static uint8_t sink[4096];
    for (uint32_t i = 0; i < 16u && recv(fd, sink, sizeof sink, MSG_DONTWAIT) > 0; i++) {
    }
  }
  return io_tup(e, io_hand(w->hand), done ? io_done(e, term_pak(CID(Unit), 0)) : io_fail(e, 1, NULL));
}

// texts[0] body[0] texts[1] body[1] ... texts[n]: each body id a post's
// stored HTML (or, with PAGE_COMMENT_BIT, a comment's), spliced only if the
// session (token hash h) may read it (db_body's floor).
static PageOut page_body(Env e, Term texts, Term ids, const uint8_t h[32]) {
  PageOut body = {io_mem(malloc(16384)), 0, 16384, 0};
  Term x, rest;
  uint64_t now = app_now_ms();
  for (uint32_t i = 0; i < 100000u && app_uncons(e, CID(Con), texts, &x, &rest); i++) {
    u64 n = 0;
    char *s = io_cstr(e, x, &n);
    page_put(&body, s, n);
    free(s);
    texts = rest;
    Term id;
    if (app_uncons(e, CID(Con), ids, &id, &rest)) {
      if (((uint32_t)id & PAGE_COMMENT_BIT) != 0u) {
        db_comment_body(&app_db, (uint32_t)id & ~PAGE_COMMENT_BIT, h, now, page_body_put, &body);
      } else {
        db_body(&app_db, (uint32_t)id, h, now, page_body_put, &body);
      }
      ids = rest;
    }
  }
  return body;
}

static Term page_run(Env e, Term *f, IoWork *w) {
  ASSERT(app_db_ready);
  w->hand = (intptr_t)io_hand_v(f[0]);
  uint32_t status = (uint32_t)f[1], ctype = (uint32_t)f[2];
  uint8_t h[32];
  app_token_hash(e, f[5], h);
  u64 cn = 0, ln = 0;
  char *cookie = io_cstr(e, f[6], &cn);
  char *loc = io_cstr(e, f[7], &ln);
  PageOut body = page_body(e, f[3], f[4], h);
  const char *reason = page_reason(status);
  int cookie_ok = cn == 0u || (cn == 1u && cookie[0] == '-');
  uint8_t tmp[TOKEN_BYTES];
  if (cn == TOKEN_HEX && token_decode((const uint8_t *)cookie, TOKEN_HEX, tmp)) cookie_ok = 1;
  explicit_bzero(tmp, sizeof tmp);
  int loc_ok = ln == 0u || page_path_ok(loc, ln);
  if (reason == NULL || ctype >= sizeof page_ctypes / sizeof page_ctypes[0] || !cookie_ok || !loc_ok || body.overflow) {
    status = 500;
    reason = page_reason(500);
    ctype = 1;
    body.len = 0;
    cn = 0;
    ln = 0;
  }
  if (ctype == 2u && body.len > 0u) {
    PageOut sse = page_sse(&body);
    free(body.buf);
    body = sse;
    if (body.overflow) body.len = 0;
  }
  char nonce[PAGE_NONCE_LEN + 1u], csp[512];
  page_nonce(&body, nonce);
  int cn2 = snprintf(csp, sizeof csp, NET_HTML_CSP_FMT, nonce);
  ASSERT(cn2 > 0 && (size_t)cn2 < sizeof csp);
  char head[2048];
  int hn = snprintf(head, sizeof head, "HTTP/1.1 %u %s\r\nContent-Type: %s\r\nContent-Length: %llu\r\nConnection: close\r\n%s%s%s",
                    status, reason, page_ctypes[ctype], (unsigned long long)body.len, csp, NET_OTHER_HEADERS, NET_NO_STORE);
  ASSERT(hn > 0 && (size_t)hn < sizeof head);
  if (cn == TOKEN_HEX) {
    hn += snprintf(head + hn, sizeof head - (size_t)hn,
                   "Set-Cookie: sid=%.*s; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=2592000\r\n", (int)cn, cookie);
  } else if (cn == 1u) {
    hn += snprintf(head + hn, sizeof head - (size_t)hn, "Set-Cookie: sid=; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=0\r\n");
  }
  if (ln > 0u) hn += snprintf(head + hn, sizeof head - (size_t)hn, "Location: %.*s\r\n", (int)ln, loc);
  hn += snprintf(head + hn, sizeof head - (size_t)hn, "\r\n");
  ASSERT(hn > 0 && (size_t)hn < sizeof head);
  explicit_bzero(cookie, cn);
  free(cookie);
  free(loc);
  u64 total = (u64)hn + body.len;
  char *out = io_mem(malloc(total));
  memcpy(out, head, (size_t)hn);
  memcpy(out + hn, body.buf, body.len);
  free(body.buf);
  w->data = out;
  w->size = total;
  w->made = 0;
  w->code = 0;
  w->text = (char *)(uintptr_t)(io_tick() + 10000ull * 1000000ull);
  return page_more(e, w);
}

#ifdef CID(page)
static void __attribute__((constructor)) page_use(void) {
  io_eff(CID(page), page_run, 0);
}
#endif

// STREAMS
// -------
// A long-lived response (a Datastar event stream): stream_open sends the
// head (no Content-Length: the body ends when the connection closes),
// stream_send sends one chunk and leaves the connection open. Both answer
// Fail when the reader has gone, which ends the handler's loop.
// stream_send(sock, raw, texts, bodies, token): raw 1 sends the text as
// it is (an SSE comment, e.g. a keep-alive); raw 0 sends patches (as
// page(), content type 2).
static Term stream_more(Env e, IoWork *w) {
  int fd = (int)w->hand;
  u64 deadline = (u64)(uintptr_t)w->text;
  for (uint32_t step = 0; step < RESPONSE_BYTES_MAX && (u64)w->made < w->size; step++) {
    ssize_t n = send(fd, w->data + w->made, w->size - (u64)w->made, MSG_NOSIGNAL);
    if (n < 0 && errno == EAGAIN) {
      if (io_tick() >= deadline) break;
      return io_wait_on(w, fd, POLLOUT, deadline, stream_more);
    }
    if (n <= 0) break;
    w->made += n;
  }
  int done = (u64)w->made == w->size;
  free(w->data);
  w->data = NULL;
  return io_tup(e, io_hand(w->hand), done ? io_done(e, term_pak(CID(Unit), 0)) : io_fail(e, 1, NULL));
}

static Term stream_start(Env e, IoWork *w, char *out, u64 len) {
  w->data = out;
  w->size = len;
  w->made = 0;
  w->code = 0;
  w->text = (char *)(uintptr_t)(io_tick() + 10000ull * 1000000ull);
  return stream_more(e, w);
}

#ifdef CID(stream_open)
Term stream_open_run(Env e, Term *f, IoWork *w) {
  w->hand = (intptr_t)io_hand_v(f[0]);
  char head[1024];
  int hn = snprintf(head, sizeof head, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n%s%s\r\n",
                    NET_SECURITY_HEADERS, NET_NO_STORE);
  ASSERT(hn > 0 && (size_t)hn < sizeof head);
  char *out = io_mem(malloc((size_t)hn));
  memcpy(out, head, (size_t)hn);
  return stream_start(e, w, out, (u64)hn);
}

static void __attribute__((constructor)) stream_open_use(void) {
  io_eff(CID(stream_open), stream_open_run, 0);
}
#endif

#ifdef CID(stream_send)
Term stream_send_run(Env e, Term *f, IoWork *w) {
  ASSERT(app_db_ready);
  w->hand = (intptr_t)io_hand_v(f[0]);
  uint8_t h[32];
  app_token_hash(e, f[4], h);
  PageOut body = page_body(e, f[2], f[3], h);
  if ((uint32_t)f[1] == 0u) {
    PageOut sse = page_sse(&body);
    free(body.buf);
    body = sse;
  }
  if (body.overflow) {
    free(body.buf);
    return io_tup(e, io_hand(w->hand), io_fail(e, 1, NULL));
  }
  return stream_start(e, w, body.buf, body.len);
}

static void __attribute__((constructor)) stream_send_use(void) {
  io_eff(CID(stream_send), stream_send_run, 0);
}
#endif

// IMAGES
// ------
// upload_raw(token, facts (7), post, bytes): bytes is a Bend String of one
// Char per byte (as the network layer reads them); stores the image (see
// db_upload) and answers its key, or fails with DbResult as the code.
// Only src/db.bend's upload calls this (tools/lint.sh).
#ifdef CID(upload_raw)

// A byte string back to bytes: NULL if longer than max or a Char > 255.
static uint8_t *app_bytes(Env e, Term s, uint32_t max, uint32_t *n) {
  uint8_t *out = io_mem(malloc(max > 0u ? max : 1u));
  uint32_t len = 0;
  Term h, t;
  for (uint64_t guard = 0; guard <= (uint64_t)max && app_uncons(e, CID(SCon), s, &h, &t); guard++) {
    if (len == max || (u64)h > 255u) {
      free(out);
      return NULL;
    }
    out[len++] = (uint8_t)h;
    s = t;
  }
  *n = len;
  return out;
}

Term upload_raw_run(Env e, Term *f, IoWork *w) {
  (void)w;
  ASSERT(app_db_ready);
  uint8_t h[32];
  app_token_hash(e, f[0], h);
  DbFacts x = {(uint32_t)f[1], (uint32_t)f[2], (uint32_t)f[3], (uint32_t)f[4],
               (uint32_t)f[5], (uint32_t)f[6], (uint32_t)f[7]};
  uint32_t n = 0;
  uint8_t *bytes = app_bytes(e, f[9], IMG_BYTES_MAX, &n);
  if (bytes == NULL) return io_fail(e, DB_CONFLICT, NULL);
  uint8_t key[IMG_KEY_BYTES];
  char hex[2u * IMG_KEY_BYTES + 1u];
  if (getrandom(key, sizeof key, 0) != (ssize_t)sizeof key) {
    free(bytes);
    return io_fail(e, DB_ERROR, NULL);
  }
  DbResult r = db_upload(&app_db, h, app_now_ms(), &x, (uint32_t)f[8], bytes, n, key, hex);
  free(bytes);
  return r == DB_OK ? io_done(e, io_str(e, hex, 2u * IMG_KEY_BYTES)) : io_fail(e, (uint32_t)r, NULL);
}

static void __attribute__((constructor)) upload_raw_use(void) {
  io_eff(CID(upload_raw), upload_raw_run, 0);
}
#endif

// image(sock, key): sends the image stored under key with its checked
// type, immutable caching (keys are random and images never change),
// nosniff and a CSP that forbids everything (so it is inert if opened as
// a document); 404 if there is none.
typedef struct {
  PageOut body;
  const char *type;
} ImageOut;

static void image_put(void *ctx, const char *type, const uint8_t *p, uint32_t n) {
  ImageOut *o = ctx;
  o->type = type[0] == 'i' ? (strcmp(type, "image/jpeg") == 0 ? "image/jpeg" : strcmp(type, "image/png") == 0 ? "image/png"
                              : strcmp(type, "image/gif") == 0 ? "image/gif" : strcmp(type, "image/webp") == 0 ? "image/webp" : NULL) : NULL;
  if (o->type != NULL) page_put(&o->body, (const char *)p, n);
}

#ifdef CID(image)
Term image_run(Env e, Term *f, IoWork *w) {
  ASSERT(app_db_ready);
  w->hand = (intptr_t)io_hand_v(f[0]);
  u64 kn = 0;
  char *key = io_cstr(e, f[1], &kn);
  ImageOut o = {{io_mem(malloc(65536)), 0, 65536, 0}, NULL};
  int32_t found = kn <= 64u ? db_image(&app_db, key, (uint32_t)kn, image_put, &o) : 0;
  free(key);
  int ok = found == 1 && o.type != NULL && !o.body.overflow;
  if (!ok) o.body.len = 0;
  char head[1024];
  int hn = snprintf(head, sizeof head, "HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %llu\r\nConnection: close\r\n%s%s"
                    "Content-Disposition: inline\r\n\r\n",
                    ok ? "200 OK" : "404 Not Found", ok ? o.type : "text/plain; charset=utf-8",
                    (unsigned long long)o.body.len, NET_SECURITY_HEADERS, ok ? NET_IMMUTABLE : NET_NO_STORE);
  ASSERT(hn > 0 && (size_t)hn < sizeof head);
  u64 total = (u64)hn + o.body.len;
  char *out = io_mem(malloc(total));
  memcpy(out, head, (size_t)hn);
  memcpy(out + hn, o.body.buf, o.body.len);
  free(o.body.buf);
  w->data = out;
  w->size = total;
  w->made = 0;
  w->code = 0;
  w->text = (char *)(uintptr_t)(io_tick() + 10000ull * 1000000ull);
  return page_more(e, w);
}

static void __attribute__((constructor)) image_use(void) {
  io_eff(CID(image), image_run, 0);
}
#endif

// LIVE COMMENTS
// -------------
// comment_wait(post, after, timeout_ms): answers 1 as soon as the post has
// a comment newer than `after` (at once if it already does), 0 at the
// timeout, 2 at once if LIVE_MAX readers are already waiting (the page's
// script then waits longer before asking again). A waiting request parks
// on its own eventfd; writing a comment (apply_raw) writes to the eventfds
// of that post's waiters in this process, and moves the post's shared
// comment version, which waiters in other worker processes look at every
// LIVE_LOOK_MS. Each waiter costs an fd and a place in every pass of the
// event loop (the runtime select()s over parked requests), so the number
// is capped.
#define LIVE_MAX 512u
#define LIVE_LOOK_MS 500u

typedef struct {
  int fd;  // -1: free
  uint32_t post;
  uint32_t ver;  // the post's comment version when it began waiting
  u64 end;       // io_tick() deadline
} LiveWaiter;

static LiveWaiter live[LIVE_MAX];
static uint32_t live_used;

static void live_init(void) {
  for (uint32_t i = 0; i < LIVE_MAX; i++) live[i].fd = -1;
}

static void live_wake(uint32_t post) {
  uint64_t one = 1;
  for (uint32_t i = 0; i < LIVE_MAX && live_used > 0u; i++) {
    if (live[i].fd >= 0 && live[i].post == post) {
      ssize_t n = write(live[i].fd, &one, sizeof one);
      (void)n;  // a full eventfd is already readable
    }
  }
}

#ifdef CID(comment_wait)
#include <sys/eventfd.h>

// The next wake-up: the deadline, or with other worker processes the next
// look at the shared version, if sooner.
static u64 live_next(const LiveWaiter *l) {
  ASSERT(l->fd >= 0);
  u64 look = io_tick() + (u64)LIVE_LOOK_MS * 1000000ull;
  return app_workers > 1u && look < l->end ? look : l->end;
}

static Term comment_wait_more(Env e, IoWork *w) {
  (void)e;
  uint32_t slot = (uint32_t)w->made;
  ASSERT(slot < LIVE_MAX && live[slot].fd >= 0);
  LiveWaiter *l = &live[slot];
  uint64_t v = 0;
  ssize_t n = read(l->fd, &v, sizeof v);
  int woke = n == (ssize_t)sizeof v && v > 0u;
  int moved = atomic_load(&app_shared->comment_ver[app_post_slot(l->post)]) != l->ver;
  if (!woke && !moved && io_tick() < l->end) return io_wait_on(w, l->fd, POLLIN, live_next(l), comment_wait_more);
  close(l->fd);
  l->fd = -1;
  live_used--;
  return (Term)(uint32_t)(woke || moved ? 1u : 0u);
}

Term comment_wait_run(Env e, Term *f, IoWork *w) {
  (void)e;
  ASSERT(app_db_ready);
  uint32_t post = (uint32_t)f[0], after = (uint32_t)f[1], timeout = (uint32_t)f[2];
  // Read before the database, so a comment committed after the read below
  // moves it (and is not missed).
  uint32_t ver = atomic_load(&app_shared->comment_ver[app_post_slot(post)]);
  sqlite3_stmt *st = app_db.q[Q_LAST_COMMENT];
  sqlite3_bind_int64(st, 1, post);
  uint32_t last = 0;
  if (sqlite3_step(st) == SQLITE_ROW) last = (uint32_t)sqlite3_column_int64(st, 0);
  sqlite3_reset(st);
  sqlite3_clear_bindings(st);
  if (last > after) return (Term)1u;
  if (live_used >= LIVE_MAX) return (Term)2u;
  uint32_t slot = 0;
  while (slot < LIVE_MAX && live[slot].fd >= 0) slot++;
  ASSERT(slot < LIVE_MAX);
  int fd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
  if (fd < 0) return (Term)2u;
  if (timeout > 60000u) timeout = 60000u;
  live[slot] = (LiveWaiter){fd, post, ver, io_tick() + (u64)timeout * 1000000ull};
  live_used++;
  w->made = (intptr_t)slot;
  return io_wait_on(w, fd, POLLIN, live_next(&live[slot]), comment_wait_more);
}

static void __attribute__((constructor)) comment_wait_use(void) {
  io_eff(CID(comment_wait), comment_wait_run, 0);
}
#endif

// DNS
// ---
// dns_txt_has(name, expect): does name have a TXT record whose text is
// exactly expect? (Custom domain verification.) The lookup blocks, so it
// runs on a helper thread (io_work), with a short timeout; the system
// resolver (glibc's libresolv: no new dependency) does the parsing.
#ifdef CID(dns_txt_has)
#include <arpa/nameser.h>
#include <resolv.h>

#define DNS_NAME_MAX 253u
#define DNS_EXPECT_MAX 128u

static void dns_call(IoWork *w) {
  const char *name = w->data;
  const char *expect = w->data + DNS_NAME_MAX + 1u;
  size_t en = strlen(expect);
  w->code = 0;
  struct __res_state st;
  memset(&st, 0, sizeof st);
  if (res_ninit(&st) != 0) return;
  st.retrans = 2;
  st.retry = 2;
  static __thread unsigned char buf[8192];
  int n = res_nquery(&st, name, ns_c_in, ns_t_txt, buf, sizeof buf);
  ns_msg m;
  if (n > 0 && ns_initparse(buf, n, &m) == 0) {
    for (int i = 0; i < ns_msg_count(m, ns_s_an) && i < 64; i++) {
      ns_rr rr;
      if (ns_parserr(&m, ns_s_an, i, &rr) != 0 || ns_rr_type(rr) != ns_t_txt) continue;
      // A TXT record's text is its character-strings joined.
      const unsigned char *d = ns_rr_rdata(rr);
      int len = ns_rr_rdlen(rr);
      char text[1024];
      size_t tn = 0;
      for (int k = 0; k < len && tn < sizeof text;) {
        int sl = d[k];
        if (k + 1 + sl > len || tn + (size_t)sl > sizeof text) break;
        memcpy(text + tn, d + k + 1, (size_t)sl);
        tn += (size_t)sl;
        k += 1 + sl;
      }
      if (tn == en && memcmp(text, expect, en) == 0) w->code = 1;
    }
  }
  res_nclose(&st);
}

static Term dns_pack(Env e, IoWork *w) {
  (void)e;
  free(w->data);
  w->data = NULL;
  return term_pak(w->code == 1u ? CID(True) : CID(False), 0);
}

Term dns_txt_has_run(Env e, Term *f, IoWork *w) {
  u64 nn = 0, en = 0;
  char *name = io_cstr(e, f[0], &nn);
  char *expect = io_cstr(e, f[1], &en);
  if (nn == 0u || nn > DNS_NAME_MAX || en == 0u || en > DNS_EXPECT_MAX) {
    free(name);
    free(expect);
    return term_pak(CID(False), 0);
  }
  w->data = io_mem(calloc(1, DNS_NAME_MAX + 1u + DNS_EXPECT_MAX + 1u));
  memcpy(w->data, name, nn);
  memcpy(w->data + DNS_NAME_MAX + 1u, expect, en);
  free(name);
  free(expect);
  return io_work(w, dns_call, dns_pack);
}

static void __attribute__((constructor)) dns_txt_has_use(void) {
  io_eff(CID(dns_txt_has), dns_txt_has_run, 0);
}
#endif

// PAGE CACHE
// ----------
// Rendered public pages (feeds), so a visitor's request does not render
// dozens of rows through Bend Strings (~90 ns per character) each time.
// WHAT MAY BE CACHED: a 200 HTML page that is the same for every request
// with the same key. Handlers put everything a page depends on into its
// key (the path, and whether someone is signed in: the header differs);
// pages that depend on who is asking (drafts, Edit links, dashboards) are
// never cached. An entry is valid while its stamp (PageStamp: the shared
// write counters it depends on, read when the page was found missing)
// still holds.
// Direct-mapped: a key's slot is its hash; a new entry replaces the old.
// Two direct-mapped tables: 4096 slots of at most 64 KiB (256 MiB of
// address space) and, for long pages such as a post with hundreds of
// comments, 128 slots of at most 1 MiB (128 MiB). Both are touched (and so
// resident) only as pages are cached. Bigger pages are not cached.
#define PAGE_CACHE_SLOTS 4096u
#define PAGE_CACHE_BIG_SLOTS 128u
#define PAGE_CACHE_KEY_MAX 96u
#define PAGE_CACHE_BYTES (64u * 1024u)
#define PAGE_CACHE_BIG_BYTES (1024u * 1024u)
_Static_assert(PAGE_CACHE_BYTES < PAGE_CACHE_BIG_BYTES, "big slots hold bigger pages");

// What an entry depends on, read when the page was found missing (before
// the handler read anything for it): valid while it still equals the
// current stamp. Stamping at store time instead would cache a page as
// fresh when a write landed while it was being made.
typedef struct {
  uint64_t gen;  // write_gen, or post_gen for a post page; 0: none
  uint32_t ver;  // post_ver of the post, for a post page
} PageStamp;

typedef struct {
  PageStamp stamp;  // gen 0: empty
  uint32_t key_len, len, ctype;
  char key[PAGE_CACHE_KEY_MAX];
} PageCacheHead;

typedef struct {
  PageCacheHead h;
  char bytes[PAGE_CACHE_BYTES];
} PageCacheSlot;

typedef struct {
  PageCacheHead h;
  char bytes[PAGE_CACHE_BIG_BYTES];
} PageCacheBigSlot;

static PageCacheSlot page_cache[PAGE_CACHE_SLOTS];
static PageCacheBigSlot page_cache_big[PAGE_CACHE_BIG_SLOTS];

static uint32_t page_cache_hash(const char *k, u64 n) {
  ASSERT(n <= PAGE_CACHE_KEY_MAX);
  uint32_t h = 2166136261u;
  for (u64 i = 0; i < n; i++) h = (h ^ (uint8_t)k[i]) * 16777619u;
  return h;
}

// The current stamp for a key: a post page ("p0:<id>") depends on
// post_gen and its post's version, anything else on write_gen.
static PageStamp page_stamp_now(const char *k, u64 n) {
  ASSERT(n > 0u && n <= PAGE_CACHE_KEY_MAX);
  if (n > 3u && memcmp(k, "p0:", 3) == 0) {
    uint32_t post = 0;
    for (u64 i = 3; i < n && k[i] >= '0' && k[i] <= '9'; i++) post = post * 10u + (uint32_t)(k[i] - '0');
    PageStamp s = {atomic_load(&app_shared->post_gen), atomic_load(&app_shared->post_ver[app_post_slot(post)])};
    ASSERT(s.gen > 0u);
    return s;
  }
  PageStamp s = {atomic_load(&app_shared->write_gen), 0};
  ASSERT(s.gen > 0u);
  return s;
}

static int page_cache_is(const PageCacheHead *h, const char *k, u64 n, PageStamp now) {
  ASSERT(n > 0u && n <= PAGE_CACHE_KEY_MAX);
  return h->stamp.gen == now.gen && h->stamp.ver == now.ver && h->key_len == n && memcmp(h->key, k, n) == 0;
}

// The stamp taken when a socket's page was found missing (cached_run), for
// its page_cache_put. Sockets are fds; one past the table is not cached.
#define PAGE_STAMP_FDS 65536u
static PageStamp page_stamps[PAGE_STAMP_FDS];

// The entry for key (valid now), or NULL; bytes gets its body.
static const PageCacheHead *page_cache_find(const char *k, u64 n, const char **bytes) {
  ASSERT(n > 0u && n <= PAGE_CACHE_KEY_MAX);
  uint32_t h = page_cache_hash(k, n);
  PageStamp now = page_stamp_now(k, n);
  PageCacheSlot *c = &page_cache[h % PAGE_CACHE_SLOTS];
  if (page_cache_is(&c->h, k, n, now)) {
    ASSERT(c->h.len <= PAGE_CACHE_BYTES);
    *bytes = c->bytes;
    return &c->h;
  }
  PageCacheBigSlot *b = &page_cache_big[h % PAGE_CACHE_BIG_SLOTS];
  if (page_cache_is(&b->h, k, n, now)) {
    ASSERT(b->h.len <= PAGE_CACHE_BIG_BYTES);
    *bytes = b->bytes;
    return &b->h;
  }
  return NULL;
}

// Drops key's entry in both tables.
static void page_cache_drop(const char *k, u64 n) {
  if (n == 0u || n > PAGE_CACHE_KEY_MAX) return;
  uint32_t h = page_cache_hash(k, n);
  PageCacheHead *a = &page_cache[h % PAGE_CACHE_SLOTS].h;
  PageCacheHead *b = &page_cache_big[h % PAGE_CACHE_BIG_SLOTS].h;
  if (a->key_len == n && memcmp(a->key, k, n) == 0) a->stamp.gen = 0;
  if (b->key_len == n && memcmp(b->key, k, n) == 0) b->stamp.gen = 0;
}

// Stores body under key with stamp, if it fits; the other table's entry
// for the key (an older size) is dropped.
static void page_cache_store(const char *k, u64 n, PageStamp stamp, uint32_t ctype, const char *body, u64 len) {
  if (n == 0u || n > PAGE_CACHE_KEY_MAX || len > PAGE_CACHE_BIG_BYTES || stamp.gen == 0u) return;
  page_cache_drop(k, n);
  uint32_t h = page_cache_hash(k, n);
  PageCacheHead *head;
  char *dst;
  if (len <= PAGE_CACHE_BYTES) {
    PageCacheSlot *c = &page_cache[h % PAGE_CACHE_SLOTS];
    head = &c->h;
    dst = c->bytes;
  } else {
    PageCacheBigSlot *b = &page_cache_big[h % PAGE_CACHE_BIG_SLOTS];
    head = &b->h;
    dst = b->bytes;
  }
  memcpy(head->key, k, n);
  head->key_len = (uint32_t)n;
  memcpy(dst, body, len);
  head->len = (uint32_t)len;
  head->ctype = ctype;
  head->stamp = stamp;
  ASSERT(head->stamp.gen != 0u && head->len == len);
}

// Sends body (200, no cookie, content type ctype) on w's socket; takes
// ownership of it.
static Term page_emit(Env e, IoWork *w, uint32_t ctype, PageOut *body) {
  ASSERT(ctype < sizeof page_ctypes / sizeof page_ctypes[0]);
  char nonce[PAGE_NONCE_LEN + 1u], csp[512];
  page_nonce(body, nonce);
  int cn = snprintf(csp, sizeof csp, NET_HTML_CSP_FMT, nonce);
  ASSERT(cn > 0 && (size_t)cn < sizeof csp);
  char head[1024];
  int hn = snprintf(head, sizeof head, "HTTP/1.1 200 OK\r\nContent-Type: %s\r\nContent-Length: %llu\r\nConnection: close\r\n%s%s%s\r\n",
                    page_ctypes[ctype], (unsigned long long)body->len, csp, NET_OTHER_HEADERS, NET_NO_STORE);
  ASSERT(hn > 0 && (size_t)hn < sizeof head);
  u64 total = (u64)hn + body->len;
  char *out = io_mem(malloc(total));
  memcpy(out, head, (size_t)hn);
  memcpy(out + hn, body->buf, body->len);
  free(body->buf);
  w->data = out;
  w->size = total;
  w->made = 0;
  w->code = 0;
  w->text = (char *)(uintptr_t)(io_tick() + 10000ull * 1000000ull);
  return page_more(e, w);
}

#ifdef CID(cached)
// cached(sock, key): sends the cached page for key and answers Done, or
// sends nothing and answers Fail (then the handler renders it).
Term cached_run(Env e, Term *f, IoWork *w) {
  w->hand = (intptr_t)io_hand_v(f[0]);
  u64 kn = 0;
  char *key = io_cstr(e, f[1], &kn);
  Term r = 0;
  int hit = 0;
  const char *bytes = NULL;
  const PageCacheHead *c = kn > 0u && kn <= PAGE_CACHE_KEY_MAX ? page_cache_find(key, kn, &bytes) : NULL;
  if (w->hand >= 0 && (u64)w->hand < PAGE_STAMP_FDS) {
    page_stamps[w->hand] = c == NULL && kn > 0u && kn <= PAGE_CACHE_KEY_MAX ? page_stamp_now(key, kn) : (PageStamp){0, 0};
  }
  if (c != NULL) {
    ASSERT(bytes != NULL);
    PageOut body = {io_mem(malloc(c->len > 0u ? c->len : 1u)), 0, c->len > 0u ? c->len : 1u, 0};
    page_put(&body, bytes, c->len);
    r = page_emit(e, w, c->ctype, &body);
    hit = 1;
  }
  free(key);
  return hit ? r : io_tup(e, io_hand(w->hand), io_fail(e, 0, NULL));
}

static void __attribute__((constructor)) cached_use(void) {
  io_eff(CID(cached), cached_run, 0);
}
#endif

#ifdef CID(page_cache_put)
// page_cache_put(sock, key, ctype, texts, bodies): sends texts[0] body[0]
// texts[1] ... as a 200 response of content type ctype (bodies spliced as
// for page(), as a signed-out visitor: published only) and stores it under
// key at the current write generation (if it fits).
Term page_cache_put_run(Env e, Term *f, IoWork *w) {
  w->hand = (intptr_t)io_hand_v(f[0]);
  u64 kn = 0;
  char *key = io_cstr(e, f[1], &kn);
  uint32_t ctype = (uint32_t)f[2];
  PageOut body = {io_mem(malloc(16384)), 0, 16384, 0};
  Term texts = f[3], ids = f[4], x, rest;
  uint8_t anon[32];
  memset(anon, 0, sizeof anon);  // no session has this hash
  uint64_t now = app_now_ms();
  for (uint32_t i = 0; i < 100000u && app_uncons(e, CID(Con), texts, &x, &rest); i++) {
    u64 n = 0;
    char *s = io_cstr(e, x, &n);
    page_put(&body, s, n);
    free(s);
    texts = rest;
    Term id;
    if (app_uncons(e, CID(Con), ids, &id, &rest)) {
      if (((uint32_t)id & PAGE_COMMENT_BIT) != 0u) {
        db_comment_body(&app_db, (uint32_t)id & ~PAGE_COMMENT_BIT, anon, now, page_body_put, &body);
      } else {
        db_body(&app_db, (uint32_t)id, anon, now, page_body_put, &body);
      }
      ids = rest;
    }
  }
  if (ctype == 2u && !body.overflow) {
    PageOut sse = page_sse(&body);
    free(body.buf);
    body = sse;
  }
  if (body.overflow || ctype >= sizeof page_ctypes / sizeof page_ctypes[0]) {
    free(key);
    free(body.buf);
    return io_tup(e, io_hand(w->hand), io_fail(e, 1, NULL));
  }
  // Only with the stamp taken by this socket's cached (else not stored).
  PageStamp stamp = {0, 0};
  if (w->hand >= 0 && (u64)w->hand < PAGE_STAMP_FDS) {
    stamp = page_stamps[w->hand];
    page_stamps[w->hand] = (PageStamp){0, 0};
  }
  page_cache_store(key, kn, stamp, ctype, body.buf, body.len);
  free(key);
  return page_emit(e, w, ctype, &body);
}

static void __attribute__((constructor)) page_cache_put_use(void) {
  io_eff(CID(page_cache_put), page_cache_put_run, 0);
}
#endif

// SYNC
// ----
// sync_page(sock, token, facts (7), post, ops, since): runs db_sync and
// sends its output as the response (200 text/plain), so a document's
// operations go from SQLite to the socket without becoming a Bend String.
// Fails: 403 (denied/stale), 409 (conflict/limit), 400 (malformed).

#ifdef CID(sync_page)

static void sync_out_put(void *ctx, const char *p, uint32_t n) {
  page_put((PageOut *)ctx, p, n);
}

Term sync_page_run(Env e, Term *f, IoWork *w) {
  ASSERT(app_db_ready);
  w->hand = (intptr_t)io_hand_v(f[0]);
  uint8_t h[32];
  app_token_hash(e, f[1], h);
  DbFacts x = {(uint32_t)f[2], (uint32_t)f[3], (uint32_t)f[4], (uint32_t)f[5],
               (uint32_t)f[6], (uint32_t)f[7], (uint32_t)f[8]};
  uint32_t post = (uint32_t)f[9];
  u64 on = 0;
  char *ops = io_cstr(e, f[10], &on);
  uint64_t since = (uint64_t)(uint32_t)f[11];
  PageOut body = {io_mem(malloc(16384)), 0, 16384, 0};
  DbResult r = on > UINT32_MAX ? DB_DENIED
    : db_sync(&app_db, h, app_now_ms(), &x, post, ops, (uint32_t)on, since, sync_out_put, &body);
  free(ops);
  uint32_t status = r == DB_OK && !body.overflow ? 200u : r == DB_CONFLICT ? 409u : r == DB_DENIED || r == DB_STALE ? 403u : 500u;
  if (status != 200u) body.len = 0;
  char head[1024];
  int hn = snprintf(head, sizeof head, "HTTP/1.1 %u %s\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: %llu\r\nConnection: close\r\n%s%s\r\n",
                    status, page_reason(status), (unsigned long long)body.len, NET_SECURITY_HEADERS, NET_NO_STORE);
  ASSERT(hn > 0 && (size_t)hn < sizeof head);
  u64 total = (u64)hn + body.len;
  char *out = io_mem(malloc(total));
  memcpy(out, head, (size_t)hn);
  memcpy(out + hn, body.buf, body.len);
  free(body.buf);
  w->data = out;
  w->size = total;
  w->made = 0;
  w->code = 0;
  w->text = (char *)(uintptr_t)(io_tick() + 10000ull * 1000000ull);
  return page_more(e, w);
}

static void __attribute__((constructor)) sync_page_use(void) {
  io_eff(CID(sync_page), sync_page_run, 0);
}

#endif

// ASSETS
// ------
// asset(sock, id): static files embedded at compile time, served as bytes
// with immutable caching (pages link them with a ?v=<hash> query).
// 0 the editor bundle, 1 the stylesheet, 2 the passkey script, 3 Datastar.

#ifdef CID(asset)

static const char ASSET_EDITOR[] = {
#embed "web/editor.bundle.js"
};
static const char ASSET_CSS[] = {
#embed "../src/web/app.css"
};
static const char ASSET_PASSKEY[] = {
#embed "../src/web/passkey.js"
};
static const char ASSET_DATASTAR[] = {
#embed "../vendor/datastar/datastar.js"
};

Term asset_run(Env e, Term *f, IoWork *w) {
  w->hand = (intptr_t)io_hand_v(f[0]);
  uint32_t id = (uint32_t)f[1];
  const char *data = "";
  u64 len = 0;
  const char *type = "text/javascript; charset=utf-8";
  if (id == 0u) { data = ASSET_EDITOR; len = sizeof ASSET_EDITOR; }
  else if (id == 1u) { data = ASSET_CSS; len = sizeof ASSET_CSS; type = "text/css; charset=utf-8"; }
  else if (id == 2u) { data = ASSET_PASSKEY; len = sizeof ASSET_PASSKEY; }
  else if (id == 3u) { data = ASSET_DATASTAR; len = sizeof ASSET_DATASTAR; }
  uint32_t status = len > 0u ? 200u : 404u;
  char head[1024];
  int hn = snprintf(head, sizeof head, "HTTP/1.1 %u %s\r\nContent-Type: %s\r\nContent-Length: %llu\r\nConnection: close\r\n%s%s\r\n",
                    status, page_reason(status), type, (unsigned long long)len, NET_SECURITY_HEADERS,
                    status == 200u ? NET_IMMUTABLE : NET_NO_STORE);
  ASSERT(hn > 0 && (size_t)hn < sizeof head);
  char *out = io_mem(malloc((u64)hn + len));
  memcpy(out, head, (size_t)hn);
  memcpy(out + hn, data, len);
  w->data = out;
  w->size = (u64)hn + len;
  w->made = 0;
  w->code = 0;
  w->text = (char *)(uintptr_t)(io_tick() + 10000ull * 1000000ull);
  return page_more(e, w);
}

static void __attribute__((constructor)) asset_use(void) {
  io_eff(CID(asset), asset_run, 0);
}

#endif
