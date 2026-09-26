// Mixed-traffic HTTP load generator (test tool, not server code).
//
// Reads a mix file of prepared requests (one per line: category, a tab,
// then the raw request with CR and LF written as \r and \n), keeps `conns`
// connections busy for `seconds`, each sending a request picked uniformly
// at random from the mix (the mix file already holds the traffic in its
// proportions), reading until the server closes (Connection: close).
// Prints one JSON object: totals, and per category the count, statuses and
// latency percentiles.
//
// usage: mixgen <port> <conns> <seconds> <mixfile> [seed]
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

#define CONNS_MAX 2048
#define REQS_MAX 200000
#define CATS_MAX 32
#define LAT_MAX (1u << 20)

typedef struct {
  char name[32];
  uint64_t n, bytes, st2, st3, st4, st5, st0;
  uint32_t *lat;  // microseconds
  uint64_t nlat;
} Cat;

typedef struct {
  uint32_t cat;
  char *data;
  uint32_t len;
} Req;

typedef struct {
  int fd;
  uint64_t start_ns;
  uint32_t req;
  uint32_t sent;
  char head[16];
  uint32_t head_len;
  uint64_t got;
} Conn;

static Cat cats[CATS_MAX];
static uint32_t ncats;
static Req reqs[REQS_MAX];
static uint32_t nreqs;
static Conn conns[CONNS_MAX];
static struct sockaddr_in addr;
static int ep;
static uint64_t rng_state = 88172645463325252ull;

static uint64_t rng(void) {
  rng_state ^= rng_state << 13;
  rng_state ^= rng_state >> 7;
  rng_state ^= rng_state << 17;
  return rng_state;
}

static uint64_t now_ns(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec;
}

static uint32_t cat_of(const char *name, size_t n) {
  for (uint32_t i = 0; i < ncats; i++) {
    if (strlen(cats[i].name) == n && memcmp(cats[i].name, name, n) == 0) return i;
  }
  if (ncats == CATS_MAX || n >= sizeof cats[0].name) {
    fprintf(stderr, "too many categories\n");
    exit(2);
  }
  memcpy(cats[ncats].name, name, n);
  cats[ncats].lat = calloc(LAT_MAX, sizeof(uint32_t));
  return ncats++;
}

static void load_mix(const char *path) {
  FILE *f = fopen(path, "rb");
  if (!f) {
    perror(path);
    exit(2);
  }
  static char line[4u << 20];
  while (nreqs < REQS_MAX && fgets(line, sizeof line, f)) {
    char *tab = strchr(line, '\t');
    if (!tab) continue;
    uint32_t c = cat_of(line, (size_t)(tab - line));
    char *src = tab + 1, *out = malloc(strlen(src) + 1);
    uint32_t n = 0;
    for (; *src && *src != '\n'; src++) {
      if (src[0] == '\\' && src[1] == 'r') { out[n++] = '\r'; src++; }
      else if (src[0] == '\\' && src[1] == 'n') { out[n++] = '\n'; src++; }
      else if (src[0] == '\\' && src[1] == '\\') { out[n++] = '\\'; src++; }
      else out[n++] = *src;
    }
    reqs[nreqs++] = (Req){c, out, n};
  }
  fclose(f);
  if (nreqs == 0) {
    fprintf(stderr, "empty mix\n");
    exit(2);
  }
}

static void start(Conn *c) {
  c->fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
  int one = 1;
  setsockopt(c->fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
  c->req = (uint32_t)(rng() % nreqs);
  c->sent = 0;
  c->head_len = 0;
  c->got = 0;
  c->start_ns = now_ns();
  connect(c->fd, (struct sockaddr *)&addr, sizeof addr);
  struct epoll_event ev = {.events = EPOLLOUT | EPOLLIN, .data.ptr = c};
  epoll_ctl(ep, EPOLL_CTL_ADD, c->fd, &ev);
}

static void finish(Conn *c, int ok) {
  Cat *k = &cats[reqs[c->req].cat];
  uint64_t us = (now_ns() - c->start_ns) / 1000u;
  k->n++;
  k->bytes += c->got;
  int st = 0;
  if (ok && c->head_len >= 12 && memcmp(c->head, "HTTP/1.1 ", 9) == 0) st = c->head[9] - '0';
  if (st == 2) k->st2++;
  else if (st == 3) k->st3++;
  else if (st == 4) k->st4++;
  else if (st == 5) k->st5++;
  else k->st0++;
  if (k->nlat < LAT_MAX) k->lat[k->nlat++] = (uint32_t)(us > 0xffffffffu ? 0xffffffffu : us);
  epoll_ctl(ep, EPOLL_CTL_DEL, c->fd, NULL);
  close(c->fd);
}

static int cmp_u32(const void *a, const void *b) {
  uint32_t x = *(const uint32_t *)a, y = *(const uint32_t *)b;
  return (x > y) - (x < y);
}

static uint32_t pct(Cat *k, double p) {
  if (k->nlat == 0) return 0;
  uint64_t i = (uint64_t)(p * (double)(k->nlat - 1));
  return k->lat[i];
}

int main(int argc, char **argv) {
  if (argc < 5) {
    fprintf(stderr, "usage: mixgen <port> <conns> <seconds> <mixfile> [seed]\n");
    return 2;
  }
  int port = atoi(argv[1]), nconn = atoi(argv[2]);
  double secs = atof(argv[3]);
  if (argc > 5) rng_state ^= strtoull(argv[5], NULL, 10) * 0x9E3779B97F4A7C15ull;
  if (nconn < 1 || nconn > CONNS_MAX) return 2;
  load_mix(argv[4]);
  addr.sin_family = AF_INET;
  addr.sin_port = htons((uint16_t)port);
  inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);
  ep = epoll_create1(0);
  for (int i = 0; i < nconn; i++) start(&conns[i]);
  uint64_t t0 = now_ns(), end = t0 + (uint64_t)(secs * 1e9);
  static char buf[1 << 16];
  struct epoll_event evs[256];
  while (now_ns() < end) {
    int n = epoll_wait(ep, evs, 256, 50);
    for (int i = 0; i < n; i++) {
      Conn *c = evs[i].data.ptr;
      Req *r = &reqs[c->req];
      if ((evs[i].events & EPOLLOUT) && c->sent < r->len) {
        ssize_t w = send(c->fd, r->data + c->sent, r->len - c->sent, MSG_NOSIGNAL);
        if (w > 0) c->sent += (uint32_t)w;
        else if (w < 0 && errno != EAGAIN && errno != EINPROGRESS) { finish(c, 0); start(c); continue; }
        if (c->sent == r->len) {
          struct epoll_event ev = {.events = EPOLLIN, .data.ptr = c};
          epoll_ctl(ep, EPOLL_CTL_MOD, c->fd, &ev);
        }
      }
      if (evs[i].events & (EPOLLIN | EPOLLHUP | EPOLLERR)) {
        for (;;) {
          ssize_t g = recv(c->fd, buf, sizeof buf, 0);
          if (g > 0) {
            if (c->head_len < sizeof c->head) {
              uint32_t k = (uint32_t)g < sizeof c->head - c->head_len ? (uint32_t)g : (uint32_t)(sizeof c->head - c->head_len);
              memcpy(c->head + c->head_len, buf, k);
              c->head_len += k;
            }
            c->got += (uint64_t)g;
            continue;
          }
          if (g == 0) { finish(c, 1); start(c); }
          else if (errno != EAGAIN) { finish(c, c->got > 0); start(c); }
          break;
        }
      }
    }
  }
  double el = (double)(now_ns() - t0) / 1e9;
  uint64_t total = 0, errs = 0;
  for (uint32_t i = 0; i < ncats; i++) {
    total += cats[i].n;
    errs += cats[i].st5 + cats[i].st0;
    qsort(cats[i].lat, cats[i].nlat, sizeof(uint32_t), cmp_u32);
  }
  printf("{\"conns\": %d, \"seconds\": %.2f, \"requests\": %llu, \"req_s\": %.1f, \"errors\": %llu, \"cats\": {", nconn, el,
         (unsigned long long)total, (double)total / el, (unsigned long long)errs);
  for (uint32_t i = 0; i < ncats; i++) {
    Cat *k = &cats[i];
    printf("%s\"%s\": {\"n\": %llu, \"req_s\": %.1f, \"2xx\": %llu, \"3xx\": %llu, \"4xx\": %llu, \"5xx\": %llu, \"fail\": %llu, "
           "\"kb\": %.1f, \"p50_ms\": %.2f, \"p90_ms\": %.2f, \"p99_ms\": %.2f, \"max_ms\": %.2f}",
           i ? ", " : "", k->name, (unsigned long long)k->n, (double)k->n / el, (unsigned long long)k->st2, (unsigned long long)k->st3,
           (unsigned long long)k->st4, (unsigned long long)k->st5, (unsigned long long)k->st0,
           k->n ? (double)k->bytes / (double)k->n / 1024.0 : 0.0, pct(k, 0.5) / 1000.0, pct(k, 0.9) / 1000.0, pct(k, 0.99) / 1000.0,
           pct(k, 1.0) / 1000.0);
  }
  printf("}}\n");
  return 0;
}
