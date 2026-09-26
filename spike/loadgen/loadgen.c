// Minimal HTTP load generator for the spike (no wrk available, no root).
// Opens `conns` concurrent connections; each sends one GET, reads until the
// server closes (servers under test use Connection: close), then reconnects.
// Reports requests/s and latency percentiles. Spike code, not production style.
//
// usage: loadgen <port> <conns> <seconds> [path]
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define CONNS_MAX 1024
#define LAT_MAX (1u << 22)

typedef struct {
  int fd;
  uint64_t start_ns;
  size_t got;
} Conn;

static Conn conns[CONNS_MAX];
static uint32_t lats_us[LAT_MAX];
static uint64_t n_lat, n_ok, n_err, n_bytes;
static struct sockaddr_in addr;
static char req[256];
static size_t req_len;
static int ep;

static uint64_t now_ns(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec;
}

static void start(int i) {
  Conn *c = &conns[i];
  c->fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
  int one = 1;
  setsockopt(c->fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
  c->start_ns = now_ns();
  c->got = 0;
  int r = connect(c->fd, (struct sockaddr *)&addr, sizeof addr);
  if (r < 0 && errno != EINPROGRESS) { n_err++; close(c->fd); c->fd = -1; return; }
  struct epoll_event ev = {.events = EPOLLOUT | EPOLLIN, .data.u32 = (uint32_t)i};
  epoll_ctl(ep, EPOLL_CTL_ADD, c->fd, &ev);
}

static void finish(int i, int ok) {
  Conn *c = &conns[i];
  epoll_ctl(ep, EPOLL_CTL_DEL, c->fd, NULL);
  close(c->fd);
  if (ok && c->got > 0) {
    n_ok++;
    if (n_lat < LAT_MAX) lats_us[n_lat++] = (uint32_t)((now_ns() - c->start_ns) / 1000);
  } else {
    n_err++;
  }
  start(i);
}

static int cmp_u32(const void *a, const void *b) {
  uint32_t x = *(const uint32_t *)a, y = *(const uint32_t *)b;
  return (x > y) - (x < y);
}

int main(int argc, char **argv) {
  if (argc < 4) { fprintf(stderr, "usage: loadgen <port> <conns> <seconds> [path]\n"); return 2; }
  int port = atoi(argv[1]), n = atoi(argv[2]), secs = atoi(argv[3]);
  const char *path = argc > 4 ? argv[4] : "/";
  if (n < 1 || n > CONNS_MAX) return 2;
  req_len = (size_t)snprintf(req, sizeof req, "GET %s HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", path);
  addr.sin_family = AF_INET;
  addr.sin_port = htons((uint16_t)port);
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  ep = epoll_create1(0);
  for (int i = 0; i < n; i++) start(i);
  uint64_t t0 = now_ns(), end = t0 + (uint64_t)secs * 1000000000ull;
  struct epoll_event evs[256];
  char buf[65536];
  while (now_ns() < end) {
    int k = epoll_wait(ep, evs, 256, 100);
    for (int j = 0; j < k; j++) {
      int i = (int)evs[j].data.u32;
      Conn *c = &conns[i];
      if (evs[j].events & EPOLLOUT) {
        if (send(c->fd, req, req_len, MSG_NOSIGNAL) != (ssize_t)req_len) { finish(i, 0); continue; }
        struct epoll_event ev = {.events = EPOLLIN, .data.u32 = (uint32_t)i};
        epoll_ctl(ep, EPOLL_CTL_MOD, c->fd, &ev);
        continue;
      }
      for (;;) {
        ssize_t r = recv(c->fd, buf, sizeof buf, 0);
        if (r > 0) { c->got += (size_t)r; n_bytes += (uint64_t)r; continue; }
        if (r == 0) { finish(i, 1); break; }
        if (errno == EAGAIN) break;
        finish(i, 0);
        break;
      }
    }
  }
  double el = (double)(now_ns() - t0) / 1e9;
  qsort(lats_us, n_lat, sizeof lats_us[0], cmp_u32);
  uint32_t p50 = n_lat ? lats_us[n_lat / 2] : 0, p99 = n_lat ? lats_us[n_lat * 99 / 100] : 0;
  printf("conns=%d ok=%lu err=%lu req/s=%.0f MB/s=%.1f p50=%uus p99=%uus\n", n, (unsigned long)n_ok,
         (unsigned long)n_err, (double)n_ok / el, (double)n_bytes / el / 1e6, p50, p99);
  return 0;
}
