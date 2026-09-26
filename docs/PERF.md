# Performance: this server against Next.js (React)

The thesis: server-rendered hypermedia plus small vanilla JS, on a lean
server, beats a React framework on real metrics. First measurement,
2026-09-26 (`tests/bench_vs_next.py`, raw numbers in `docs/bench.json`).

## Setup

- **Ours:** `build/server` (Bend compiled to C, SQLite, no JS on public pages).
- **Baseline:** Next.js 16.3.6 / React 19.3.0, App Router, server components,
  `next build && next start` (production), `dynamic = "force-dynamic"`
  (renders per request, like ours). Same three pages, same CSS, same SQLite
  file (via Node 24's built-in `node:sqlite`, read-only), same stored HTML.
- **Data:** 50 blogs, 2,000 published posts of ~5 KB HTML each.
- **Machine:** cloud container, 2 vCPUs. Each server pinned to core 0, the
  load generator (`spike/loadgen`, 32 connections, `Connection: close`) to
  core 1.
- **Browser:** headless Chrome 154, 4× CPU throttling (a mid-range phone),
  cold cache, each load arriving from a page on another site, median of 5.

## Results

| page | server req/s | p50 latency | JS shipped (gzip) | FCP = LCP | load event | main-thread script |
|---|---|---|---|---|---|---|
| post | **5,190** vs 263 (20×) | **6.1** vs 113 ms | **0** vs 561 KB (168) | **160** vs 200 ms | **80** vs 410 ms | **0** vs 103 ms |
| blog | **8,295** vs 214 (cached) | **4.1** vs 138 ms | **0** vs 563 KB (168) | **172** vs 188 ms | **94** vs 391 ms | **0** vs 106 ms |
| home | **8,597** vs 94 (cached) | **4.1** vs 330 ms | **0** vs 563 KB (168) | **168** vs 220 ms | **96** vs 410 ms | **0** vs 109 ms |

(Re-run after the UI pass. Home and blog pages are now served from our
page cache, so their server numbers compare a cached page with an
uncached Next page: see below. The post page is still rendered per
request, and is the fair comparison: 20×. Before the cache, with the
richer feed rows, home and blog were ~850 req/s here.)

HTML is also smaller: 2.7–3.4 KB vs 11.7–15.2 KB (Next inlines its React
Server Components payload).

## What this does and does not show

- **Server throughput** of post pages compares per-request rendering. Home
  and blog pages come from our page cache (invalidated on every write);
  Next's are rendered per request here. A Next deployment could cache
  them too (ISR), which would close most of that gap.
- **Next compresses responses** (gzip) and keeps connections alive; ours
  relies on the reverse proxy (Caddy) for compression. On localhost this
  does not matter; over a real network, compare the gzip column.
- **The browser gap is structural:** 168 KB of gzipped JS and ~100 ms of main
  thread per load on a throttled phone, versus none. It grows on real
  mobile networks and CPUs; it does not shrink with caching.
- **First paint** is 15–25% faster, not 4×: on localhost both are dominated
  by browser work (parsing, style, the first frame). `load` shows the
  difference in total work.

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
- Multi-core serving (one process per core with `SO_REUSEPORT`).
- A cached/static Next baseline.
