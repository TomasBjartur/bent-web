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
#include "../src/effects/app_common.h"
#include "../src/effects/app_shared.h"

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
#include <signal.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/wait.h>

// A listening socket on 127.0.0.1:port (loopback only: TLS and the public
// edge are Caddy's job), non-blocking. Answers the fd, or -errno. No
// SO_REUSEPORT: worker processes share this one socket (see workers), and
// a stray second server on the port fails to start instead of silently
// taking part of the traffic.
static int net_listen_fd(uint32_t port) {
  ASSERT(port > 0u && port <= 65535u);
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return -errno;
  int one = 1;
  struct sockaddr_in at;
  memset(&at, 0, sizeof at);
  at.sin_family = AF_INET;
  at.sin_port = htons((uint16_t)port);
  at.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one) < 0 || bind(fd, (struct sockaddr*)&at, sizeof at) < 0
    || listen(fd, 1024) < 0 || fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) < 0) {
    int code = errno;
    close(fd);
    return -code;
  }
  ASSERT(fd >= 0);
  return fd;
}

// The socket made by workers (once), else a new one.
Term net_listen_run(Env e, Term* f, IoWork* w) {
  (void)w;
  uint32_t port = (uint32_t)f[0];
  if (port == 0u || port > 65535u) return io_fail(e, EINVAL, NULL);
  int fd = app_listen_fd >= 0 ? app_listen_fd : net_listen_fd(port);
  app_listen_fd = -1;
  if (fd < 0) return io_fail(e, (uint32_t)-fd, NULL);
  return io_done(e, io_hand(fd));
}

static void __attribute__((constructor)) net_listen_use(void) {
  io_eff(CID(listen), net_listen_run, 0);
}

// WORKERS
// -------
// workers(port, db): with BLOG_WORKERS=n (2..APP_WORKERS_MAX), migrates the
// database once (opened and closed again: workers racing to migrate a new
// file collided), makes the shared state (app_shared.h) and the listening
// socket, then forks n workers and
// answers each its index; this process stays behind as their supervisor
// and never answers: when any worker ends, it stops the others and exits
// (non-zero), and systemd restarts the service. A worker ends with its
// supervisor (PR_SET_PDEATHSIG). Must run first, before the database is
// opened or any thread exists (neither survives a fork). With one worker,
// answers 0 and nothing changes.
//
// All workers accept from one socket: a connection goes to whichever is
// free, so one stalled by a slow request takes no new ones.
static void net_supervise(const pid_t* kids, uint32_t n) {
  ASSERT(n >= 2u && n <= APP_WORKERS_MAX);
  int status = 0;
  pid_t gone = -1;
  for (;;) {  // until a worker ends: the supervisor has nothing else to do
    gone = waitpid(-1, &status, 0);
    if (gone > 0 || errno != EINTR) break;
  }
  for (uint32_t i = 0; i < n; i++) {
    if (kids[i] != gone) kill(kids[i], SIGTERM);
  }
  fprintf(stderr, "worker %d ended (status %d): stopping\n", (int)gone, status);
  exit(1);
}

// The runtime's helper threads hand finished work (io_work) back to the
// event loop through a pipe it opens at startup (io_wake_fd, Bend 2.0.29
// runtime internals: a rename breaks this build, loudly). After a fork
// every worker would share it, and one could take another's finished work
// (a pointer into the other's memory: it crashed). Each worker opens its
// own before any helper thread exists.
static void net_own_wake_pipe(void) {
  close(io_wake_fd[0]);
  close(io_wake_fd[1]);
  if (pipe(io_wake_fd) != 0 || fcntl(io_wake_fd[0], F_SETFL, O_NONBLOCK) != 0) {
    perror("workers: wake pipe");
    _exit(1);
  }
  ASSERT(io_wake_fd[0] >= 0 && io_wake_fd[1] >= 0);
}

Term net_workers_run(Env e, Term* f, IoWork* w) {
  (void)w;
  uint32_t port = (uint32_t)f[0];
  const char* v = getenv("BLOG_WORKERS");
  uint32_t n = v != NULL && v[0] >= '1' && v[0] <= '9' ? (uint32_t)strtoul(v, NULL, 10) : 1u;
  if (n <= 1u || port == 0u || port > 65535u) return (Term)0u;
  if (n > APP_WORKERS_MAX) n = APP_WORKERS_MAX;
  u64 pn = 0;
  char* path = io_cstr(e, f[1], &pn);
  Db once;
  int32_t migrated = db_open(&once, path);
  if (migrated == 0) db_close(&once);
  free(path);
  if (migrated != 0) {
    fprintf(stderr, "workers: cannot open the database\n");
    exit(1);
  }
  AppShared* sh = mmap(NULL, sizeof *sh, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
  int fd = net_listen_fd(port);
  if (sh == MAP_FAILED || fd < 0) {
    fprintf(stderr, "workers: cannot start (%s)\n", sh == MAP_FAILED ? "shared memory" : strerror(-fd));
    exit(1);
  }
  atomic_store(&sh->write_gen, 1u);
  atomic_store(&sh->post_gen, 1u);
  app_shared = sh;
  app_listen_fd = fd;
  app_workers = n;
  pid_t me = getpid();
  pid_t kids[APP_WORKERS_MAX];
  for (uint32_t i = 0; i < n; i++) {
    pid_t k = fork();
    if (k < 0) {
      perror("workers: fork");
      for (uint32_t j = 0; j < i; j++) kill(kids[j], SIGTERM);
      exit(1);
    }
    if (k == 0) {
      if (prctl(PR_SET_PDEATHSIG, SIGTERM) != 0 || getppid() != me) _exit(1);
      net_own_wake_pipe();
      return (Term)i;
    }
    kids[i] = k;
  }
  close(fd);
  net_supervise(kids, n);
  return (Term)0u;  // not reached
}

static void __attribute__((constructor)) net_workers_use(void) {
  io_eff(CID(workers), net_workers_run, 0);
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

#include "../src/c/http_headers.h"

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
    "HTTP/1.1 %u %s\r\nContent-Type: %s\r\nContent-Length: %llu\r\nConnection: close\r\n%s%s\r\n",
    status, reason, net_ctypes[ctype], (unsigned long long)body_len, NET_SECURITY_HEADERS, NET_NO_STORE);
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
