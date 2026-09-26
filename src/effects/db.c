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
#include <time.h>

#include "../src/c/db_core.c"
#include "../src/c/token_core.h"
#include "../src/c/http_headers.h"
#include "../src/c/limits.h"

static Db app_db;
static int32_t app_db_ready;

static uint64_t app_now_ms(void) {
  struct timespec t;
  clock_gettime(CLOCK_REALTIME, &t);
  return (uint64_t)t.tv_sec * 1000ull + (uint64_t)t.tv_nsec / 1000000ull;
}

// Session tokens live 30 days.
#define SESSION_TTL_MS (30ull * 24ull * 3600ull * 1000ull)

// The SHA-256 of the session token in `t` (a Bend String of hex), or all
// zeros (which matches no session) if it is not a well-formed token.
static void app_token_hash(Env e, Term t, uint8_t out[32]) {
  u64 n = 0;
  char *s = io_cstr(e, t, &n);
  uint8_t raw[TOKEN_BYTES];
  memset(out, 0, 32);
  if (n == TOKEN_HEX && token_decode((const uint8_t *)s, (uint32_t)n, raw)) {
    db_token_hash(raw, out);
  }
  explicit_bzero(raw, sizeof raw);
  explicit_bzero(s, n);
  free(s);
}

// Takes one element off a Bend list term: returns 1 and sets *head/*tail if
// it is a cons, 0 if it is empty.
static int app_uncons(Env e, Term s, Term *head, Term *tail) {
  if (term_aux(s) != CID(Con)) return 0;
  Term fb[2];
  spare_free(e, cls_fit(2), ctr_take(e, s, 2, fb));
  *head = fb[0];
  *tail = fb[1];
  return 1;
}

// OPEN
// ----

#ifdef CID(db_open)

Term db_open_run(Env e, Term *f, IoWork *w) {
  (void)w;
  u64 n = 0;
  char *path = io_cstr(e, f[0], &n);
  int32_t r = app_db_ready ? -1 : db_open(&app_db, path);
  free(path);
  if (r != 0) return io_fail(e, EIO, "cannot open the database");
  app_db_ready = 1;
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

typedef struct {
  uint32_t used, cells, rows, overflow;
} AppRows;

static void app_row(void *ctx, uint32_t ncols, const char *const *cols, const uint32_t *lens) {
  AppRows *a = ctx;
  ASSERT(a->rows < DB_ROWS_MAX && ncols <= DB_COLS_MAX);
  for (uint32_t i = 0; i < ncols; i++) {
    if (lens[i] > APP_ARENA_BYTES - a->used) {
      a->overflow = 1;
      return;
    }
    memcpy(app_arena + a->used, cols[i], lens[i]);
    app_cell_off[a->cells] = a->used;
    app_cell_len[a->cells] = lens[i];
    a->used += lens[i];
    a->cells++;
  }
  app_row_cols[a->rows] = ncols;
  a->rows++;
}

// f: q, a, b, text, token. Answers List<List<String>>; empty on error.
Term query_run(Env e, Term *f, IoWork *w) {
  (void)w;
  ASSERT(app_db_ready);
  uint8_t h[32];
  app_token_hash(e, f[4], h);
  u64 tn = 0;
  char *text = io_cstr(e, f[3], &tn);
  AppRows a = {0, 0, 0, 0};
  int32_t n = tn > UINT32_MAX ? -1
    : db_query(&app_db, (uint32_t)f[0], (uint32_t)f[1], (uint32_t)f[2], (DbText){text, (uint32_t)tn},
               h, app_now_ms(), app_row, &a);
  free(text);
  Term rows = term_pak(CID(Nil), 0);
  if (n < 0 || a.overflow) return rows;
  uint32_t cell = a.cells;
  for (uint32_t r = a.rows; r > 0u; r--) {
    Term cols = term_pak(CID(Nil), 0);
    for (uint32_t c = app_row_cols[r - 1u]; c > 0u; c--) {
      cell--;
      cols = io_node(e, CID(Con), io_str(e, app_arena + app_cell_off[cell], app_cell_len[cell]), cols);
    }
    rows = io_node(e, CID(Con), cols, rows);
  }
  ASSERT(cell == 0u);
  return rows;
}

static void __attribute__((constructor)) query_use(void) {
  io_eff(CID(query), query_run, 0);
}

#endif

// PAGES
// -----
// page(sock, status, ctype, texts, bodies, token, cookie, location): sends
// texts[0] body[0] texts[1] body[1] ... texts[n] as one response. Each body
// is a post id whose stored HTML is spliced in only if the post is published
// or the session is a member of its blog (db_body's floor); otherwise
// nothing is spliced. cookie: "" (none), "-" (clear) or a 64-hex token to
// set. location: "" or a path for a 303 redirect.

#ifdef CID(page)

static const char *page_reason(uint32_t s) {
  switch (s) {
    case 200: return "OK";
    case 303: return "See Other";
    case 400: return "Bad Request";
    case 403: return "Forbidden";
    case 404: return "Not Found";
    case 405: return "Method Not Allowed";
    case 409: return "Conflict";
    case 413: return "Content Too Large";
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
};

// A redirect target: starts with "/", not "//", only unreserved characters
// and "/", "?", "=", "&", "%".
static int page_path_ok(const char *p, u64 n) {
  if (n == 0u || n > 512u || p[0] != '/' || (n > 1u && p[1] == '/')) return 0;
  for (u64 i = 0; i < n; i++) {
    unsigned char c = (unsigned char)p[i];
    int ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
             c == '-' || c == '.' || c == '_' || c == '~' || c == '/' || c == '?' || c == '=' ||
             c == '&' || c == '%';
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

Term page_run(Env e, Term *f, IoWork *w) {
  ASSERT(app_db_ready);
  w->hand = (intptr_t)io_hand_v(f[0]);
  uint32_t status = (uint32_t)f[1], ctype = (uint32_t)f[2];
  uint8_t h[32];
  app_token_hash(e, f[5], h);
  u64 cn = 0, ln = 0;
  char *cookie = io_cstr(e, f[6], &cn);
  char *loc = io_cstr(e, f[7], &ln);
  PageOut body = {io_mem(malloc(16384)), 0, 16384, 0};
  Term texts = f[3], ids = f[4], x, rest;
  uint64_t now = app_now_ms();
  for (uint32_t i = 0; i < 100000u && app_uncons(e, texts, &x, &rest); i++) {
    u64 n = 0;
    char *s = io_cstr(e, x, &n);
    page_put(&body, s, n);
    free(s);
    texts = rest;
    Term id;
    if (app_uncons(e, ids, &id, &rest)) {
      const char *html;
      uint32_t hl;
      if (db_body(&app_db, (uint32_t)id, h, now, &html, &hl) == 1) page_put(&body, html, hl);
      ids = rest;
    }
  }
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
  char head[2048];
  int hn = snprintf(head, sizeof head, "HTTP/1.1 %u %s\r\nContent-Type: %s\r\nContent-Length: %llu\r\nConnection: close\r\n%s",
                    status, reason, page_ctypes[ctype], (unsigned long long)body.len, NET_SECURITY_HEADERS);
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

static void __attribute__((constructor)) page_use(void) {
  io_eff(CID(page), page_run, 0);
}

#endif
