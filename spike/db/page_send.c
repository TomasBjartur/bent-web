// Spike effect: Page.send(sock, tpl). Sends `tpl`, replacing each marker
// "\x01<decimal id>\x02" with stored blob `id` (pre-sanitized HTML bytes kept
// in C). The Bend side never turns bulk text into a String.
// Spike code, not production style.

#define BLOBS 64
// Static template chunks, referenced as "\x03<k>" (k = '0' + index).
static const char* const chunk[] = {
  "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n"
  "<!doctype html><html><head><meta charset=\"utf-8\"><title>Blog</title></head><body><main>\n",
  "<article><h2><a href=\"/p/",
  "\">",
  "</a></h2><p class=\"by\">",
  "</p><p>",
  "</p></article>\n",
  "</main></body></html>\n",
};
#define CHUNKS (sizeof chunk / sizeof chunk[0])
static char* blob_data[BLOBS];
static u64   blob_size[BLOBS];

static void __attribute__((constructor)) page_blobs_init(void) {
  static const char ex[] =
    "Lorem ipsum dolor sit amet, &lt;em&gt;consectetur&lt;/em&gt; &amp; adipiscing elit. "
    "Lorem ipsum dolor sit amet, &lt;em&gt;consectetur&lt;/em&gt; &amp; adipiscing elit. "
    "Lorem ipsum dolor sit amet, &lt;em&gt;consectetur&lt;/em&gt; &amp; adipiscing elit. ";
  for (int i = 0; i < BLOBS; i++) {
    blob_data[i] = (char*)ex;
    blob_size[i] = sizeof ex - 1;
  }
}

static Term page_send_more(Env e, IoWork* w) {
  int fd = (int)w->hand;
  while (w->code == 0 && (u64)w->made < w->size) {
    ssize_t n = send(fd, w->data + w->made, w->size - (u64)w->made, 0);
    if (n < 0 && errno == EAGAIN) {
      return io_wait_on(w, fd, POLLOUT, 0, page_send_more);
    }
    w->made += io_sys_end(w, n);
  }
  Term r = w->code != 0 ? io_fail(e, w->code, NULL)
    : io_done(e, term_pak(CID(Unit), 0));
  free(w->data);
  return io_tup(e, io_hand(w->hand), r);
}

Term page_send_run(Env e, Term* f, IoWork* w) {
  u64 n = 0;
  char* t = io_cstr(e, f[1], &n);
  u64 cap = n + 64 * 1024;
  char* out = malloc(cap);
  u64 o = 0;
  for (u64 i = 0; i < n; i++) {
    if (t[i] == 3 && i + 1 < n) {
      u64 k = (u64)(t[++i] - '0') % CHUNKS;
      u64 len = strlen(chunk[k]);
      if (o + len > cap) { cap = (o + len) * 2; out = realloc(out, cap); }
      memcpy(out + o, chunk[k], len);
      o += len;
    } else if (t[i] == 1) {
      u64 id = 0;
      i++;
      while (i < n && t[i] != 2) { id = id * 10 + (u64)(t[i] - '0'); i++; }
      id %= BLOBS;
      if (o + blob_size[id] > cap) { cap = (o + blob_size[id]) * 2; out = realloc(out, cap); }
      memcpy(out + o, blob_data[id], blob_size[id]);
      o += blob_size[id];
    } else {
      if (o + 1 > cap) { cap *= 2; out = realloc(out, cap); }
      out[o++] = t[i];
    }
  }
  free(t);
  w->hand = (intptr_t)io_hand_v(f[0]);
  w->data = out;
  w->size = o;
  w->made = 0;
  w->code = 0;
  return page_send_more(e, w);
}

static void __attribute__((constructor)) page_send_use(void) {
  io_eff(CID(Page.send), page_send_run, 0);
}
