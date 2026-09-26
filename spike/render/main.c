// C twin of main.bend: same page, same data, same escaping, byte buffers.
// Spike code, not production style.
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#define PAGE_MAX (64 * 1024)
#define POSTS 40
#define ITERS 2000

typedef struct {
  char buf[PAGE_MAX];
  size_t len;
} Out;

static void put(Out *o, const char *s, size_t n) {
  memcpy(o->buf + o->len, s, n);
  o->len += n;
}
#define PUTS(o, lit) put((o), (lit), sizeof(lit) - 1)

static void esc(Out *o, const char *s, size_t n) {
  for (size_t i = 0; i < n; i++) {
    switch (s[i]) {
      case '<': PUTS(o, "&lt;"); break;
      case '>': PUTS(o, "&gt;"); break;
      case '&': PUTS(o, "&amp;"); break;
      case '"': PUTS(o, "&quot;"); break;
      case '\'': PUTS(o, "&#39;"); break;
      default: o->buf[o->len++] = s[i];
    }
  }
}

static const char EXCERPT[] =
    "Lorem ipsum dolor sit amet, <em>consectetur</em> & adipiscing elit. "
    "Lorem ipsum dolor sit amet, <em>consectetur</em> & adipiscing elit. "
    "Lorem ipsum dolor sit amet, <em>consectetur</em> & adipiscing elit. ";

static size_t render_page(Out *o, uint32_t seed) {
  char title[64], author[32], id[16];
  o->len = 0;
  PUTS(o, "<!doctype html><html><head><meta charset=\"utf-8\"><title>Blog</title></head><body><main>\n");
  for (int p = POSTS - 1; p >= 0; p--) {
    uint32_t i = seed + (uint32_t)p;
    int idn = snprintf(id, sizeof id, "%u", i);
    int tn = snprintf(title, sizeof title, "Post %u <draft> & notes", i);
    int an = snprintf(author, sizeof author, "author%u", i % 7);
    PUTS(o, "<article><h2><a href=\"/p/");
    put(o, id, (size_t)idn);
    PUTS(o, "\">");
    esc(o, title, (size_t)tn);
    PUTS(o, "</a></h2><p class=\"by\">");
    esc(o, author, (size_t)an);
    PUTS(o, "</p><p>");
    esc(o, EXCERPT, sizeof EXCERPT - 1);
    PUTS(o, "</p></article>\n");
  }
  PUTS(o, "</main></body></html>\n");
  return o->len;
}

static Out out;

int main(void) {
  struct timespec a, b;
  clock_gettime(CLOCK_MONOTONIC, &a);
  size_t total = 0;
  for (uint32_t k = 0; k < ITERS; k++) total += render_page(&out, ITERS - 1 - k);
  clock_gettime(CLOCK_MONOTONIC, &b);
  double ms = (double)(b.tv_sec - a.tv_sec) * 1e3 + (double)(b.tv_nsec - a.tv_nsec) / 1e6;
  printf("bytes=%zu ms=%.1f\n", total, ms);
  return 0;
}
