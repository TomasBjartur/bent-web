# Load test: 100k posts, mixed traffic

Tools: `tests/load/make_data.py` (synthetic database), `tests/load/make_mix.py`
(a request mix), `tests/load/mixgen.c` (the load generator), `tests/load/run.py`
(runs it all, writes `docs/load.json`).

## The setup

- **Data** (1.49 GB SQLite): 10,000 users (3,000 with sessions), 2,000 blogs,
  100,000 posts (median ~740 words, long tail), 20 novel-length posts (~1 MB
  each), 300,000 comments (a third are replies), 1,000,000 likes, 200 tags.
  Popularity is skewed like real traffic: the top 1% of posts and blogs get
  ~21% of views.
- **Traffic**: ~80% signed-out reads (home, blog pages, posts, novels,
  feeds, search, tags, authors, the stylesheet), ~20% signed-in (reading,
  dashboard, opening the editor, syncing, liking, commenting, saving).
  Every run also has a "writes x5" variant.
- **Machine**: 2 vCPU (server on core 0, load on core 1), 4 GB RAM. One server process, one event loop.

## Result

| mix | conns | req/s | post p50 / p99 ms | blog p50 ms | search p50 ms | like p50 ms | errors | RSS MB |
|---|---|---|---|---|---|---|---|---|
| normal | 1 | **437** | 0.85 / 11.9 | 5.4 | 12.6 | 0.31 | 0 | 61 |
| normal | 8 | **454** | 16.19 / 42.1 | 18.6 | 24.0 | 15.26 | 0 | 73 |
| normal | 32 | **455** | 68.75 / 115.6 | 71.0 | 77.2 | 69.33 | 0 | 80 |
| normal | 128 | **442** | 287.19 / 383.2 | 290.1 | 300.5 | 278.51 | 0 | 85 |
| normal | 512 | **440** | 1136.54 / 1365.7 | 1139.6 | 1138.5 | 1140.01 | 0 | 88 |
| writes_x5 | 32 | **436** | 67.04 / 118.5 | 73.2 | 79.3 | 65.03 | 0 | 91 |

Throughput is flat from 1 to 512 concurrent connections: the server is
CPU-bound at ~2.2 ms per request on average, and latency grows with the
queue, as it should, with no errors, no timeouts and no memory growth. The
page cache holds the hot pages; the rest is rendering.

## How it got there (the first run did 15 req/s)

The first run of this test served **15-19 requests a second**, with
requests taking seconds. Each cause, found by timing requests one at a
time and reading SQLite's query plans:

1. **Comment threads scanned the whole comment table** (300k rows) on
   every post page, even for a post with 2 comments (~60 ms), and built and
   sorted a whole thread to show 300 of its comments (113 ms for 1,700).
   Now the recursive query takes the thread depth-first in display order
   and stops at 300, and `CROSS JOIN` makes SQLite look comments up by id.
2. **Like and comment counts were counted per view** (9 ms for a popular
   post). Now columns kept by triggers.
3. **Tag pages sorted every tagged post** (3.9 s for a tag on 35k posts).
   Tag rows now carry their post's publish time, indexed.
4. **Search ranked every match** (180 ms, and 2-8 s with snippets, for a
   word in most posts), blocking the single event loop: a denial of
   service by typing a common word. Now newest matches first, which FTS5
   answers by walking its index and stopping (~7-13 ms); results show the
   excerpt, not a match snippet.
5. **Every column after the post body was expensive.** SQLite reaches a
   column by walking the overflow pages of every large value before it;
   with Markdown and HTML bodies in the post row, reading a post's date or
   author read its whole body (1 MB for a novel), and the excerpt was
   computed per view over the full body. Bodies moved to their own table
   (migration v10); excerpt and length are stored at save time, from the
   first 1200 characters.
6. **A migration left a 1.2 GB write-ahead log**, folded back into the
   database during requests (multi-second stalls). Migrations now
   checkpoint before the server starts listening.
7. **The page cache had 32 slots** for thousands of blog, tag, author and
   search pages; and signed-out post pages were not cached at all. Now
   4,096 slots of 64 KB (touched only as used: 90 MB resident here), post
   pages are cached for signed-out visitors and dropped per post on a
   like or comment, and only writes that change public pages (not draft
   saves, likes or comments) invalidate everything.
8. **Blog, tag and author pages rendered up to 100 rows** in Bend. Now 30
   a page, with older pages linked.

Also found by writing the test: the load generator's first runs hit the
server while it was still migrating (it now waits for `/healthz`).

## What limits it now

- **One core.** The server has one event loop; the machine has two
  cores, one used by the load generator. Every request type is now in the
  low milliseconds, so the next step is more processes (SO_REUSEPORT and
  one database, with the cache invalidated across processes via SQLite's
  `data_version`), not more query work.
- **Rendering in Bend** (~90 ns per output character): an uncached blog
  page is ~5 ms, a post page ~1 ms, a post with 300 comments ~12 ms. Popular
  posts with many comments are re-rendered after every like or comment.
  Options: paginate comments (show 100), or render comment sections per
  thread and splice them from C like bodies.
- **Writes are cheap**: likes and comments ~0.3-0.5 ms, saves ~6 ms
  (Markdown rendering and search indexing), all serialized by SQLite's
  single writer without errors at 5x the normal write rate.
