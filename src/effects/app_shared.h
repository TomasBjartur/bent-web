// State shared by the worker processes (src/effects/net.c workers), in one
// MAP_SHARED mapping made before the fork; with one process, this
// process's own memory. Included by src/effects/net.c and db.c (both are
// spliced into one C file).
//
// The page cache itself stays per process (a copy in each); what must agree
// is when an entry is stale: the write generations, and a version per post
// (a hash slot of the post id) that each write to the post moves. Live
// comment readers watch a version per post too.
#ifndef BLOG_APP_SHARED_H
#define BLOG_APP_SHARED_H

#include <stdatomic.h>
#include <stdint.h>

#define APP_POST_SLOTS 65536u
#define APP_WORKERS_MAX 16u

typedef struct {
  _Atomic uint64_t write_gen;  // feeds, search, RSS: any public write
  _Atomic uint64_t post_gen;   // every post page: blog-wide writes
  _Atomic uint32_t post_ver[APP_POST_SLOTS];     // one post's page: a write to it
  _Atomic uint32_t comment_ver[APP_POST_SLOTS];  // a new comment on it
} AppShared;

static AppShared app_shared_own = {1, 1, {0}, {0}};
static AppShared *app_shared = &app_shared_own;
static uint32_t app_workers = 1;  // processes serving (BLOG_WORKERS)
static int app_listen_fd = -1;    // made before the fork, taken by Net.listen

static uint32_t app_post_slot(uint32_t post) {
  return post % APP_POST_SLOTS;
}

#endif
