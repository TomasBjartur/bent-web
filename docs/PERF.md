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
| post | **6,834** vs 271 (25×) | **4.6** vs 108 ms | **0** vs 561 KB (168) | **152** vs 180 ms | **84** vs 379 ms | **1** vs 102 ms |
| blog | **2,091** vs 236 (9×) | **15** vs 124 ms | **0** vs 563 KB (168) | **152** vs 188 ms | **78** vs 390 ms | **0** vs 104 ms |
| home | **2,036** vs 186 (11×) | **16** vs 167 ms | **0** vs 563 KB (168) | **156** vs 204 ms | **93** vs 392 ms | **1** vs 104 ms |

HTML is also smaller: 2.7–3.4 KB vs 11.7–15.2 KB (Next inlines its React
Server Components payload).

## What this does and does not show

- **Server throughput** compares per-request rendering. A Next deployment
  would often cache or statically generate these pages (ISR/SSG), which
  would close most of that gap for anonymous traffic. Ours has no page
  cache either; both render every request.
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

## Not yet measured

- INP (interaction latency) on the editor.
- Real network conditions (throttled latency and bandwidth).
- Multi-core serving (one process per core with `SO_REUSEPORT`).
- A cached/static Next baseline.
