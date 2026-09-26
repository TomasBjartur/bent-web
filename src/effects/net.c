// EFFECTS: Net.listen, Net.read_head, Net.read_body, Net.respond.
// WHY C:  sockets; receive-side buffering (see src/c/net_core.h); a fixed
//         response head template so no header can be injected or
//         miscounted.
// PRE:    called only by the Bend event loop thread.
// POST:   per effect below. Strings handed to Bend from the network are raw
//         bytes, one Char per byte (0..255), never UTF-8 decoded.
// LAWS THAT DEPEND ON THIS: the HTTP laws assume Bend sees exactly the
//         bytes received (no decoding, no reordering).
// VERIFIED BY: tests/server_test.sh (integration), tests/c/ (the core);
//         deterministic simulation: not yet.
//
// This file is spliced into the Bend program's C source (after the
// runtime), so the runtime's names (Term, Env, IoWork, io_*) are in scope.
// It includes the pure core by a path relative to build/, where the
// program's C source is generated.
#include "../src/c/net_core.h"

// POOLS
// -----

static uint8_t  net_head_buf[HEAD_SLOTS][HEAD_BYTES_MAX];
static uint32_t net_head_free[HEAD_SLOTS];
static SlotPool net_head_pool;
static uint8_t  net_body_buf[BODY_SLOTS][BODY_BYTES_MAX];
static uint32_t net_body_free[BODY_SLOTS];
static SlotPool net_body_pool;

static void __attribute__((constructor)) net_pools_init(void) {
  pool_init(&net_head_pool, net_head_free, HEAD_SLOTS);
  pool_init(&net_body_pool, net_body_free, BODY_SLOTS);
}

static uint32_t net_head_slot(const char* p) {
  uintptr_t off = (uintptr_t)p - (uintptr_t)&net_head_buf[0][0];
  ASSERT(off % HEAD_BYTES_MAX == 0u);
  uint32_t slot = (uint32_t)(off / HEAD_BYTES_MAX);
  ASSERT(slot < HEAD_SLOTS);
  return slot;
}

static uint32_t net_body_slot(const char* p) {
  uintptr_t off = (uintptr_t)p - (uintptr_t)&net_body_buf[0][0];
  ASSERT(off % BODY_BYTES_MAX == 0u);
  uint32_t slot = (uint32_t)(off / BODY_BYTES_MAX);
  ASSERT(slot < BODY_SLOTS);
  return slot;
}

// Raw bytes as a Bend String, one Char per byte. Built back to front.
static Term net_bytes(Env e, const uint8_t* p, uint32_t n) {
  Term xs = term_pak(CID(SNil), 0);
  for (uint32_t i = n; i > 0u; i--) {
    xs = io_node(e, CID(SCon), (Term)p[i - 1u], xs);
  }
  return xs;
}

static u64 net_deadline(uint32_t timeout_ms) {
  return io_tick() + (u64)timeout_ms * 1000000ull;
}

// Status codes handed to Bend on failure. HTTP codes mean "answer with this
// status"; NET_GONE means "just close the socket".
#define NET_GONE 1u

// LISTEN
// ------

#ifdef CID(listen)

// Loopback only: TLS and the public edge are Caddy's job. SO_REUSEPORT so
// one process per core can share the port.
Term net_listen_run(Env e, Term* f, IoWork* w) {
  (void)w;
  uint32_t port = (uint32_t)f[0];
  if (port == 0u || port > 65535u) return io_fail(e, EINVAL, NULL);
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return io_fail(e, (uint32_t)errno, NULL);
  int one = 1;
  if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one) < 0
    || setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof one) < 0) {
    uint32_t code = (uint32_t)errno;
    close(fd);
    return io_fail(e, code, NULL);
  }
  struct sockaddr_in at;
  memset(&at, 0, sizeof at);
  at.sin_family = AF_INET;
  at.sin_port = htons((uint16_t)port);
  at.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (bind(fd, (struct sockaddr*)&at, sizeof at) < 0 || listen(fd, 1024) < 0
    || fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) < 0) {
    uint32_t code = (uint32_t)errno;
    close(fd);
    return io_fail(e, code, NULL);
  }
  return io_done(e, io_hand(fd));
}

static void __attribute__((constructor)) net_listen_use(void) {
  io_eff(CID(listen), net_listen_run, 0);
}

#endif

// READ HEAD
// ---------
// Reads until CRLFCRLF, at most HEAD_BYTES_MAX bytes, before a deadline.
// Answers the bytes read (the head plus any body bytes that came with it).
// Fails with 503 (no free buffer), 431 (head too large), 408 (deadline) or
// NET_GONE (peer closed or socket error).
// w->hand: fd. w->data: head buffer. w->made: bytes so far.
// w->size: deadline (io_tick units).

#ifdef CID(read_head)

static Term net_head_done(Env e, IoWork* w, Term r) {
  pool_give(&net_head_pool, net_head_slot(w->data));
  return io_tup(e, io_hand(w->hand), r);
}

static Term net_head_more(Env e, IoWork* w) {
  int fd = (int)w->hand;
  uint32_t have = (uint32_t)w->made;
  ASSERT(have <= HEAD_BYTES_MAX);
  for (uint32_t step = 0; step < HEAD_BYTES_MAX; step++) {
    if (have == HEAD_BYTES_MAX) return net_head_done(e, w, io_fail(e, 431, NULL));
    ssize_t n = recv(fd, w->data + have, HEAD_BYTES_MAX - have, 0);
    if (n < 0 && errno == EAGAIN) {
      if (io_tick() >= w->size) return net_head_done(e, w, io_fail(e, 408, NULL));
      w->made = have;
      return io_wait_on(w, fd, POLLIN, w->size, net_head_more);
    }
    if (n <= 0) return net_head_done(e, w, io_fail(e, NET_GONE, NULL));
    ASSERT((uint32_t)n <= HEAD_BYTES_MAX - have);
    uint32_t from = have;
    have += (uint32_t)n;
    if (head_end((const uint8_t*)w->data, have, from) != 0u) {
      Term s = net_bytes(e, (const uint8_t*)w->data, have);
      return net_head_done(e, w, io_done(e, s));
    }
  }
  // Every iteration either returns or adds >= 1 byte, so HEAD_BYTES_MAX
  // iterations always reach one of the returns above.
  ASSERT(0);
  return 0;
}

Term net_read_head_run(Env e, Term* f, IoWork* w) {
  w->hand = (intptr_t)io_hand_v(f[0]);
  uint32_t timeout_ms = (uint32_t)f[1];
  uint32_t slot = pool_take(&net_head_pool);
  if (slot == UINT32_MAX) return io_tup(e, io_hand(w->hand), io_fail(e, 503, NULL));
  w->data = (char*)net_head_buf[slot];
  w->made = 0;
  w->size = net_deadline(timeout_ms);
  w->code = 0;
  return net_head_more(e, w);
}

static void __attribute__((constructor)) net_read_head_use(void) {
  io_eff(CID(read_head), net_read_head_run, 0);
}

#endif

// READ BODY
// ---------
// Reads exactly n bytes (n <= BODY_BYTES_MAX) before a deadline.
// Fails with 503 (no free buffer), 413 (n too large), 408 (deadline) or
// NET_GONE. w->made: bytes so far; w->text: holds n; w->size: deadline.

#ifdef CID(read_body)

static Term net_body_done(Env e, IoWork* w, Term r) {
  pool_give(&net_body_pool, net_body_slot(w->data));
  return io_tup(e, io_hand(w->hand), r);
}

static Term net_body_more(Env e, IoWork* w) {
  int fd = (int)w->hand;
  uint32_t want = (uint32_t)(uintptr_t)w->text;
  uint32_t have = (uint32_t)w->made;
  ASSERT(want <= BODY_BYTES_MAX && have <= want);
  for (uint32_t step = 0; step <= BODY_BYTES_MAX; step++) {
    if (have == want) {
      return net_body_done(e, w, io_done(e, net_bytes(e, (const uint8_t*)w->data, have)));
    }
    ssize_t n = recv(fd, w->data + have, want - have, 0);
    if (n < 0 && errno == EAGAIN) {
      if (io_tick() >= w->size) return net_body_done(e, w, io_fail(e, 408, NULL));
      w->made = have;
      return io_wait_on(w, fd, POLLIN, w->size, net_body_more);
    }
    if (n <= 0) return net_body_done(e, w, io_fail(e, NET_GONE, NULL));
    ASSERT((uint32_t)n <= want - have);
    have += (uint32_t)n;
  }
  ASSERT(0);
  return 0;
}

Term net_read_body_run(Env e, Term* f, IoWork* w) {
  w->hand = (intptr_t)io_hand_v(f[0]);
  uint32_t want = (uint32_t)f[1];
  uint32_t timeout_ms = (uint32_t)f[2];
  if (want > BODY_BYTES_MAX) return io_tup(e, io_hand(w->hand), io_fail(e, 413, NULL));
  uint32_t slot = pool_take(&net_body_pool);
  if (slot == UINT32_MAX) return io_tup(e, io_hand(w->hand), io_fail(e, 503, NULL));
  w->data = (char*)net_body_buf[slot];
  w->text = (char*)(uintptr_t)want;
  w->made = 0;
  w->size = net_deadline(timeout_ms);
  w->code = 0;
  return net_body_more(e, w);
}

static void __attribute__((constructor)) net_read_body_use(void) {
  io_eff(CID(read_body), net_read_body_run, 0);
}

#endif

// RESPOND
// -------
// Sends a complete response: a fixed head built here, then the body
// (UTF-8 encoded from Bend's code points), then closes nothing (the caller
// closes). Only numeric status and a content-type index come from Bend, so
// no header can be injected.
// w->data: the whole response (malloc'd by the runtime's io_cstr path).
// w->made: bytes sent. w->size: total bytes. w->text: deadline.

#ifdef CID(respond)

static const char* net_reason(uint32_t status) {
  switch (status) {
    case 200: return "OK";
    case 204: return "No Content";
    case 303: return "See Other";
    case 400: return "Bad Request";
    case 403: return "Forbidden";
    case 404: return "Not Found";
    case 405: return "Method Not Allowed";
    case 408: return "Request Timeout";
    case 413: return "Content Too Large";
    case 431: return "Request Header Fields Too Large";
    case 500: return "Internal Server Error";
    case 501: return "Not Implemented";
    case 503: return "Service Unavailable";
    case 505: return "HTTP Version Not Supported";
    default: return NULL;
  }
}

static const char* const net_ctypes[] = {
  "text/html; charset=utf-8",
  "text/plain; charset=utf-8",
  "text/event-stream",
  "application/json",
};
#define NET_CTYPES (sizeof net_ctypes / sizeof net_ctypes[0])

// Sent on every response. The CSP allows only same-origin scripts and
// styles; Datastar and our JS are served from this origin.
static const char NET_SECURITY_HEADERS[] =
  "Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; "
  "img-src 'self'; connect-src 'self'; form-action 'self'; frame-ancestors 'none'; "
  "base-uri 'none'\r\n"
  "X-Content-Type-Options: nosniff\r\n"
  "Referrer-Policy: same-origin\r\n"
  "Cross-Origin-Opener-Policy: same-origin\r\n"
  "Cross-Origin-Resource-Policy: same-origin\r\n"
  "Cache-Control: no-store\r\n";

// Lingering close, part 1: stop writing, then discard input already
// received (up to a bound). Closing with unread input makes the kernel send
// RST, which can destroy the response before the client reads it (e.g. a
// 431 for an oversized head).
static void net_linger(int fd) {
  static uint8_t sink[4096];
  shutdown(fd, SHUT_WR);
  for (uint32_t i = 0; i < 16u; i++) {
    ssize_t n = recv(fd, sink, sizeof sink, MSG_DONTWAIT);
    if (n <= 0) break;
  }
}

static Term net_respond_more(Env e, IoWork* w) {
  int fd = (int)w->hand;
  u64 deadline = (u64)(uintptr_t)w->text;
  for (uint32_t step = 0; step < RESPONSE_BYTES_MAX && (u64)w->made < w->size; step++) {
    ssize_t n = send(fd, w->data + w->made, w->size - (u64)w->made, MSG_NOSIGNAL);
    if (n < 0 && errno == EAGAIN) {
      if (io_tick() >= deadline) {
        free(w->data);
        return io_tup(e, io_hand(w->hand), io_fail(e, 408, NULL));
      }
      return io_wait_on(w, fd, POLLOUT, deadline, net_respond_more);
    }
    if (n <= 0) {
      free(w->data);
      return io_tup(e, io_hand(w->hand), io_fail(e, NET_GONE, NULL));
    }
    w->made += n;
  }
  ASSERT((u64)w->made == w->size);
  free(w->data);
  net_linger(fd);
  return io_tup(e, io_hand(w->hand), io_done(e, term_pak(CID(Unit), 0)));
}

Term net_respond_run(Env e, Term* f, IoWork* w) {
  w->hand = (intptr_t)io_hand_v(f[0]);
  uint32_t status = (uint32_t)f[1];
  uint32_t ctype = (uint32_t)f[2];
  u64 body_len = 0;
  char* body = io_cstr(e, f[3], &body_len);
  const char* reason = net_reason(status);
  if (reason == NULL || ctype >= NET_CTYPES || body_len > RESPONSE_BYTES_MAX - 4096u) {
    free(body);
    return io_tup(e, io_hand(w->hand), io_fail(e, 500, NULL));
  }
  char head[1024];
  int hn = snprintf(head, sizeof head,
    "HTTP/1.1 %u %s\r\nContent-Type: %s\r\nContent-Length: %llu\r\nConnection: close\r\n%s\r\n",
    status, reason, net_ctypes[ctype], (unsigned long long)body_len, NET_SECURITY_HEADERS);
  ASSERT(hn > 0 && (size_t)hn < sizeof head);
  u64 total = (u64)hn + body_len;
  char* out = io_mem(malloc(total));
  memcpy(out, head, (size_t)hn);
  memcpy(out + hn, body, body_len);
  free(body);
  w->data = out;
  w->size = total;
  w->made = 0;
  w->code = 0;
  w->text = (char*)(uintptr_t)net_deadline(10000u);
  return net_respond_more(e, w);
}

static void __attribute__((constructor)) net_respond_use(void) {
  io_eff(CID(respond), net_respond_run, 0);
}

#endif
