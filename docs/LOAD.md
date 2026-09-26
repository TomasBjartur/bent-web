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
| normal | 1 | **454** | 1.01 / 16.9 | 2.5 | 13.4 | 0.46 | 0 | 214 |
| normal | 8 | **485** | 12.14 / 50.8 | 12.8 | 22.9 | 11.52 | 0 | 235 |
| normal | 32 | **511** | 58.13 / 123.2 | 58.5 | 68.5 | 59.99 | 0 | 243 |
| normal | 128 | **518** | 239.76 / 377.0 | 243.3 | 255.7 | 241.32 | 0 | 250 |
| normal | 512 | **527** | 953.77 / 1191.4 | 951.1 | 972.4 | 960.27 | 0 | 255 |
| writes_x5 | 32 | **485** | 58.41 / 125.4 | 61.0 | 70.6 | 56.14 | 0 | 258 |

Throughput is flat from 1 to 512 concurrent connections: the server is
CPU-bound at ~1.9 ms per request on average, and latency grows with the
queue, with no errors and no timeouts. Runs on this VM vary by about 10%
(the same build did 574 req/s at 32 connections in another run). RSS is
higher than before by design: SQLite's page cache is now 128 MiB.

### Second round (profiled with `perf`)

The Datastar work (live comments, forms that patch in place) made post
pages heavier (19.5 KB to 24.7 KB) and the same test fell from 455 to
**344 req/s**. Profiling the server under this mix (`perf record`, with
DWARF call stacks, since Bend's C has no frame pointers) found, in order
of size:

| change | req/s at 32 conns |
|---|---|
| start (after the Datastar pages) | 344 |
| feed pages rendered once, appends removed (below) | 344 (feeds 10 ms to 2.2 ms each) |
| big pages cached; a post edit drops only that post's page | 476 |
| SQLite page cache 2 MB to 128 MiB | 511-574 |

- **Every uncached feed page was rendered twice.** A handler passed both
  the full page and the "load more" fragment to one function that sends
  one of them; Bend is strict, so both were built. Now they are passed as
  functions (`feed_send`). The single largest cost for feeds, and
  invisible in the code: nothing looks wrong at the call site.
- **Appends copy their left side.** `a ++ b` copies `a` (a cons list).
  The rows of a feed were built right-nested (cheap), but the finished
  15 KB list was then the left side of `++` at each wrapper
  (`items ++ "</ul>"`, `feed ++ pager`, `body ++ layout_bottom()`): four
  copies, each allocating and later freeing a cell per character. Feed
  renderers now take the text that follows them (`recent_items(rows,
  rest)`), as the escaper always did, and `e(x) ++ rest` became
  `Html.esc(x, rest)` everywhere (135 places). Feed pages went from 10 ms
  to 2.2 ms (the same page with no rows at all is 1.5-1.8 ms).
- **Popular posts were never cached.** Cache slots held 64 KiB, and a post
  with hundreds of comments is ~160 KB, so the most-read posts were
  rendered on every view (13-20 ms each). A second table of 128 slots of
  1 MiB holds them (0.4 ms from the cache). And each save of any published
  post moved the global write generation, which dropped every cached post
  page; now a write to a post drops only that post's page, and only
  blog-wide changes move the post pages' generation (`app_post_gen`).
- **SQLite read from the OS.** 13% of the time was `pread`: the default
  page cache (2 MB) is small next to a 1.5 GB database. Now 128 MiB.

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

- **Rendering through Bend Strings**: ~40% of the time is Bend building
  pages, ~15% converting them to C strings (`io_cstr` walks the cons list
  one cell at a time). What is rendered is mostly signed-out post pages
  of the long tail (20,000 distinct posts in 30,000 views: they miss any
  cache) and signed-in post pages (never cached). The next step is fewer
  characters through Bend: static template chunks spliced by C like
  bodies, and per-comment HTML kept at write time.
- **SQLite** (~30%): the comment thread query (a recursive CTE per post
  page) and one body lookup per comment; search (FTS5) is 2.5% of
  requests and ~8% of the time.
- **One core.** The server has one event loop; the machine has two cores,
  one used by the load generator (in production, one used by Caddy).
- **Comments past 300** on one post are not shown (the thread query is
  capped). They need a "more comments" link.
- **Writes are cheap**: likes and comments ~0.5 ms, saves ~6 ms (Markdown
  rendering and search indexing), all serialized by SQLite's single
  writer without errors at 5x the normal write rate.
