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

// WRITE GENERATION
// ----------------
// Bumped by every successful apply_raw: every write that can change a
// public page goes through it (src/db.bend's apply; tools/lint.sh). The
// page cache below serves an entry only if it was stored at the current
// generation, so a publish, unpublish, edit or delete is visible at once.
// One process owns the database; several would need a shared counter
// (PRAGMA data_version).
static uint64_t app_write_gen = 1;
static void page_cache_drop(const char *k, u64 n);
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
    if (db_publish_due(&app_db, now) > 0) app_write_gen++;
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

Term db_open_run(Env e, Term *f, IoWork *w) {
  (void)w;
  u64 n = 0;
  char *path = io_cstr(e, f[0], &n);
  int32_t r = app_db_ready ? -1 : db_open(&app_db, path);
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
    if (res == DB_OK && db_write_is_public(&x, &wr)) app_write_gen++;
    // A new comment wakes whoever is waiting for this post's comments.
    if (res == DB_OK && wr.kind == A_COMMENT && x.has_post) live_wake(x.post);
    // A like or comment changes only that post's page (cached for
    // signed-out visitors under "p0:<post id>").
    if (res == DB_OK && (wr.kind == A_LIKE_POST || wr.kind == A_COMMENT || wr.kind == A_DELETE_COMMENT) && x.has_post) {
      char k[32];
      int kn = snprintf(k, sizeof k, "p0:%u", x.post);
      ASSERT(kn > 0 && (size_t)kn < sizeof k);
      page_cache_drop(k, (u64)kn);
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

static Term page_run(Env e, Term *f, IoWork *w) {
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
  int hn = snprintf(head, sizeof head, "HTTP/1.1 %u %s\r\nContent-Type: %s\r\nContent-Length: %llu\r\nConnection: close\r\n%s%s",
                    status, reason, page_ctypes[ctype], (unsigned long long)body.len, NET_SECURITY_HEADERS, NET_NO_STORE);
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
// of that post's waiters. Each waiter costs an fd and a place in every
// pass of the event loop (the runtime select()s over parked requests), so
// the number is capped.
#define LIVE_MAX 512u

typedef struct {
  int fd;  // -1: free
  uint32_t post;
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

static Term comment_wait_more(Env e, IoWork *w) {
  (void)e;
  uint32_t slot = (uint32_t)w->made;
  ASSERT(slot < LIVE_MAX && live[slot].fd >= 0);
  uint64_t v = 0;
  ssize_t n = read(live[slot].fd, &v, sizeof v);
  close(live[slot].fd);
  live[slot].fd = -1;
  live_used--;
  return (Term)(uint32_t)(n == (ssize_t)sizeof v && v > 0u ? 1u : 0u);
}

Term comment_wait_run(Env e, Term *f, IoWork *w) {
  (void)e;
  ASSERT(app_db_ready);
  uint32_t post = (uint32_t)f[0], after = (uint32_t)f[1], timeout = (uint32_t)f[2];
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
  live[slot] = (LiveWaiter){fd, post};
  live_used++;
  w->made = (intptr_t)slot;
  if (timeout > 60000u) timeout = 60000u;
  return io_wait_on(w, fd, POLLIN, io_tick() + (u64)timeout * 1000000ull, comment_wait_more);
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
// never cached. Entries are valid only at the write generation they were
// stored at.
// Direct-mapped: a key's slot is its hash; a new entry replaces the old.
// 4096 slots of at most 64 KiB: 256 MiB of address space, touched (and so
// resident) only as pages are cached. Bigger pages are not cached.
#define PAGE_CACHE_SLOTS 4096u
#define PAGE_CACHE_KEY_MAX 96u
#define PAGE_CACHE_BYTES (64u * 1024u)

typedef struct {
  uint64_t gen;  // 0: empty
  uint32_t key_len, len, ctype;
  char key[PAGE_CACHE_KEY_MAX];
  char bytes[PAGE_CACHE_BYTES];
} PageCacheSlot;

static PageCacheSlot page_cache[PAGE_CACHE_SLOTS];

static uint32_t page_cache_slot(const char *k, u64 n) {
  uint32_t h = 2166136261u;
  for (u64 i = 0; i < n; i++) h = (h ^ (uint8_t)k[i]) * 16777619u;
  return h % PAGE_CACHE_SLOTS;
}

// Sends body (200, no cookie, content type ctype) on w's socket; takes
// ownership of it.
static Term page_emit(Env e, IoWork *w, uint32_t ctype, PageOut *body) {
  ASSERT(ctype < sizeof page_ctypes / sizeof page_ctypes[0]);
  char head[1024];
  int hn = snprintf(head, sizeof head, "HTTP/1.1 200 OK\r\nContent-Type: %s\r\nContent-Length: %llu\r\nConnection: close\r\n%s%s\r\n",
                    page_ctypes[ctype], (unsigned long long)body->len, NET_SECURITY_HEADERS, NET_NO_STORE);
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

// Drops key's entry (a post's cached page after a like or comment on it).
static void page_cache_drop(const char *k, u64 n) {
  if (n == 0u || n > PAGE_CACHE_KEY_MAX) return;
  PageCacheSlot *c = &page_cache[page_cache_slot(k, n)];
  if (c->key_len == n && memcmp(c->key, k, n) == 0) c->gen = 0;
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
  if (kn > 0u && kn <= PAGE_CACHE_KEY_MAX) {
    PageCacheSlot *c = &page_cache[page_cache_slot(key, kn)];
    if (c->gen == app_write_gen && c->key_len == kn && memcmp(c->key, key, kn) == 0) {
      ASSERT(c->len <= PAGE_CACHE_BYTES);
      PageOut body = {io_mem(malloc(c->len > 0u ? c->len : 1u)), 0, c->len > 0u ? c->len : 1u, 0};
      page_put(&body, c->bytes, c->len);
      r = page_emit(e, w, c->ctype, &body);
      hit = 1;
    }
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
  if (body.overflow || ctype >= sizeof page_ctypes / sizeof page_ctypes[0]) {
    free(key);
    free(body.buf);
    return io_tup(e, io_hand(w->hand), io_fail(e, 1, NULL));
  }
  if (kn > 0u && kn <= PAGE_CACHE_KEY_MAX && body.len <= PAGE_CACHE_BYTES) {
    PageCacheSlot *c = &page_cache[page_cache_slot(key, kn)];
    memcpy(c->key, key, kn);
    c->key_len = (uint32_t)kn;
    memcpy(c->bytes, body.buf, body.len);
    c->len = (uint32_t)body.len;
    c->ctype = ctype;
    c->gen = app_write_gen;
  }
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
// 0 the editor bundle, 1 the stylesheet, 2 the passkey script, 3 the post
// page's script.

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
static const char ASSET_POST[] = {
#embed "../src/web/post.js"
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
  else if (id == 3u) { data = ASSET_POST; len = sizeof ASSET_POST; }
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
