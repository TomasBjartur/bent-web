# Performance: this server against Next.js (React)

The thesis: server-rendered hypermedia plus small vanilla JS, on a lean
server, beats a React framework on real metrics. First measured
2026-09-26; re-measured 2026-09-27 against a Next app rebuilt to render
the same (richer) pages.

## Setup

- **Ours:** `build/server` (Bend compiled to C, SQLite), one worker process,
  public pages with Datastar (13 KB gzipped of JavaScript).
- **Baseline:** Next.js 16.3.6 / React 19.3.0, App Router, server components,
  `next build && next start` (production), `dynamic = "force-dynamic"`
  (renders per request). The same public pages as ours (`baseline/next`:
  home, blog, post with byline, tags, likes, 20 comment threads with
  replies, tag, author, search), the same markup and stylesheet, the same
  SQLite file (Node 24's built-in `node:sqlite`, read-only), the same
  queries. No sign-in or writes (those would be a second app).
- **Ours, no cache:** our server with `BLOG_PAGE_CACHE=0`, making every
  page per request as Next does. This is the fair per-request comparison;
  "ours" is what is deployed (pages cached, and dropped by any write that
  changes them).
- **Machine:** cloud container, 2 vCPUs; each server pinned to core 0, the
  load generator to core 1.
- **Browser:** headless Chrome 154, 4x CPU throttling (a mid-range phone),
  cold cache, each load arriving from a page on another site, median of 5.

## Results (2026-09-27)

### Page benchmark (`tests/bench_vs_next.py`, `docs/bench.json`)

50 blogs, 2,000 posts of ~5 KB, tags, likes; post-3 of each blog has 30
comment threads with replies. One page at a time, 32 connections.

| page | ours (cached) | ours, no cache | Next | per request | JS (gzip) ours / Next | load event ours / Next |
|---|---|---|---|---|---|---|
| home | 8,178 req/s | 546 | 120 | **4.6x** | 13 / 171 KB | 112 / 506 ms |
| blog | 8,378 | 587 | 148 | **4.0x** | 13 / 171 KB | 122 / 457 ms |
| post | 7,739 | 465 | 112 | **4.2x** | 13 / 172 KB | 221 / 518 ms |
| tag | 8,275 | 538 | 161 | **3.3x** | 13 / 171 KB | 109 / 477 ms |
| author | 8,261 | 547 | 166 | **3.3x** | 13 / 171 KB | 116 / 455 ms |
| search | 8,396 | 202 | 178 | **1.1x** | 13 / 171 KB | 125 / 470 ms |

HTML is ~3x smaller (15-24 KB vs 44-74 KB: Next inlines its React Server
Components payload). Main-thread script on the throttled phone: 31-48 ms
vs 119-136 ms. First paint: 208-228 ms vs 248-300 ms.

### The load test's signed-out reads (`tests/load/vs_next.py`, `docs/vs_next_load.json`)

The 100k-post database (1.5 GB) and the load test's mix of signed-out
page views (posts, blogs, home, tags, authors, search), two rounds:

| server | req/s | p50 latency at 32 connections |
|---|---|---|
| ours (cached, as deployed) | **1,194-1,238** | 25-28 ms |
| ours, no cache | **670-694** | 46-51 ms |
| Next | 175-178 | 163-175 ms |

**Per request, ours is ~4x Next; as deployed, ~7x.**

## What this does and does not show

- **The per-request gap is 3-5x, not the 20x of the first measurement.**
  Both sides render richer pages now (bylines, excerpts, comments), and
  Next slowed ~2.3x (263 -> 112 req/s on posts) while ours slowed more
  (5,190 -> 465 uncached): extra text costs us more, because our pages
  are built from Bend Strings (linked lists of characters, docs/LOAD.md).
  JavaScript itself is not the slow part of Next; React's rendering and
  the framework around it are.
- **Search is a tie** (202 vs 178): both run the same FTS5 query, which
  is most of the work.
- **Caching:** our deployed pages come from a page cache that every write
  keeps correct. A Next deployment could cache too (ISR, a CDN), with
  staleness rules instead; neither side was given a CDN here.
- **Not compared:** signed-in pages and writes (Next has none), and more
  than one core (ours runs worker processes; Next would need a cluster
  behind a proxy).
- **The browser gap is structural:** 13 KB vs 171 KB of gzipped
  JavaScript, and a quarter of the main-thread script time on a
  throttled phone, whatever the server does.

## Findings along the way

1. **Our home page was 10× too slow** (220 req/s): "recent posts" had no
   index, so SQLite scanned every wide post row. Adding
   `post(published, updated_ms)` fixed it (2,036 req/s)...
2. **...and broke blog pages** (2,100 → 244 req/s): without statistics the
   planner preferred the new index for a blog's post list too. An exact
   index `post(blog_id, published, updated_ms)` plus `PRAGMA optimize` at
   startup fixed both. Lesson: benchmark every query plan after any index
   change.
3. **`Cross-Origin-Opener-Policy: same-origin` costs ~60–90 ms of first
   paint when navigating from `about:blank`** (it forces a new browsing
   context group, i.e. a renderer process). Measured by serving a static
   page with each of our headers added alone; all others are free. A
   visitor arriving from another site already gets a process swap from
   site isolation, so the benchmark starts from another site. We keep COOP:
   it protects signed-in users from cross-window attacks.

4. **Feeds cost ~90 ns per output character in Bend.** The UI pass made
   feed rows richer (publication, author, date, reading time, excerpt);
   home fell from 2,036 to 873 req/s, and to 356 with real excerpts (the
   benchmark's posts have none). SQL was 0.1 ms of the ~2.8 ms; the rest
   was building Bend Strings. Rather than render fewer characters, the
   rendered feed is cached in C (`src/effects/db.c`, `PAGE CACHE`): 32
   static slots, keyed by path and signed-in state, valid only at the
   write generation that every successful `apply_raw` bumps. 8,597 req/s.
   Tests in `tests/app_test.py` check that publish, unpublish and delete
   show at once and that signed-in and anonymous headers never mix.

## Not yet measured

- INP (interaction latency) on the editor.
- Real network conditions (throttled latency and bandwidth).
- Several cores on both sides (our worker processes against a Next cluster).
- A cached (ISR) Next baseline.
