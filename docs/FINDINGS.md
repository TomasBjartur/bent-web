# Findings

Results of the experiment, including negative ones. Newest first.

---

## 2026-09-26: Worker processes, and what Bend's parallelism is for

**Bend's parallelism does not serve requests (measured).** Bend 2
parallelizes *parallel calls* inside one pure computation (fork-join
across cores, or the GPU with `!`). Request handlers are separate
computations (`IO.spawn` per connection), and the event loop interleaves
them: with `--threads 2` the server stays one OS thread at <=100% of a
core and serves the same requests per second as `--threads 1`. The
guide's "each runs its pure code (in parallel, on every core) up to its
next effect" reads as if spawned computations ran in parallel; they do
not (an upstream question). Parallel calls could help very large renders
(a novel's blocks), not many small requests.

**So: worker processes** (`BLOG_WORKERS`, src/effects/net.c `workers`). A
supervisor migrates the database once, makes one listening socket and a
shared memory mapping, forks the workers, and exits (so systemd restarts
everything) if any worker ends. Workers accept from that one socket, so
an idle worker takes the next connection and a stalled one takes none
(SO_REUSEPORT would hash connections onto a stalled worker, and let a
stray server on the same port take traffic; it is gone). On this 2-core
VM, with the load generator on the same cores: 1 worker 712-897 req/s, 2
workers 1109-1166 req/s, post p50 44 -> 27 ms.

What has to agree across processes, and how (proved: nothing; tested:
tests/workers_test.py, 4 workers, mutation-tested):
- **Cached pages** stay per process; staleness is shared: the write
  generations and a version per post (a hash slot) live in the shared
  mapping. Breaking this (per-process counters) makes 30 of 40 reads
  stale after an edit.
- **Live comments**: a waiter is woken at once by its own process, and
  looks at the post's shared comment version every 0.5 s otherwise.
- **SQLite**: each worker has its own connection; writes serialize on
  SQLite's lock (busy_timeout 2 s, which blocks that worker's loop while
  it waits: writes are ~0.5 ms, saves ~6 ms).

Found on the way:
- **The runtime shares a pipe across fork.** Helper threads hand finished
  work back through a pipe the runtime opens at startup; after a fork all
  workers shared it, and one worker took another's finished search (a
  pointer into the other process: "memory fault"). Each worker now opens
  its own (runtime internals, Bend 2.0.29; a rename breaks the build).
- **Workers raced to migrate a new database** ("duplicate column"): the
  supervisor migrates before forking.
- **A page could be cached as fresh after a write it missed**, already
  with one process: the stamp was taken when the page was stored, so a
  write landing while the page was being made (other requests run between
  effects) was stamped as seen. Now the stamp is taken when the page is
  found missing, before anything is read, and kept per socket.

Also: every page query on the event loop now stops after 250 ms (logged;
it answers no rows), and a query over 20 ms is logged. The stop path is
not exercised by a test (no query is that slow); it is SQLite's progress
handler, checked by reading.

---

## 2026-09-26: Profiling: strict evaluation and appends

The first profile of the server (`perf`, DWARF call stacks) under the
load test's mix. Details and numbers in docs/LOAD.md; 344 -> ~510-570
req/s on one core.

- **Negative (Bend): strictness hides waste.** A handler passed both the
  full page and the "load more" fragment to a function that sends one of
  them. In a lazy language that is free; Bend is strict, so every
  uncached feed page rendered its 30 rows twice. Nothing at the call site
  looks wrong. Fix: pass functions (thunks). Rule: never pass a rendered
  alternative as an argument; pass a function.
- **Negative (Bend): `++` copies its left side.** `a ++ b` walks and
  copies `a`. Templates were right-nested (cheap), but a big finished
  string was the left side of an append at each wrapper, so a 15 KB feed
  was copied four times, with an allocation and a free per character.
  Fix: renderers take the text that follows them (`f(x, rest)`, as the
  proved escaper always did), and `e(x) ++ rest` became `Html.esc(x,
  rest)` (135 places, mechanically). Feed pages: 10 ms -> 2.2 ms. The
  escaper itself was not the problem (a benchmark: ~20 ns per character).
- **Converting a page to C costs as much as rendering it.** `io_cstr`
  (Bend's runtime) walks the cons list one cell at a time: ~15% of all
  time. This is the design rule ("bulk text never becomes a Bend String")
  measured again; what remains is template chrome and comment metadata.
- **Cache coverage, not cache speed.** The most-read posts had the most
  comments and so were over the cache's 64 KiB slot size: never cached.
  And any save of any published post dropped every cached post page. Now
  big pages have their own table, and a post write drops one page. A test
  checks each write is visible at once to a signed-out reader, and was
  mutation-tested (removing the edit case makes it fail).
- SQLite's default page cache (2 MB) made 13% of the time `pread`.
- **Negative: micro-benchmarks lied three times.** A per-request read
  transaction on a second connection, `mmap`, and malloc tuning each made
  single pages faster and the mixed load slower or no faster (a second
  connection's page cache is emptied by every write on the first). Only
  CPU time per request under the full mix, with builds alternated,
  decided anything; throughput on this VM drifts too much.
- **One event loop means one slow step stalls everything.** An event loop
  overlaps waiting (sockets), not work: a SQLite query or a page render
  runs to completion before anything else moves. A one-letter search
  prefix took 300 ms. Fixes, in order of generality: bound each request's
  work (20 comment threads a page, prefix rules), run the input-dependent
  query (search) on a helper thread with a deadline, and (not yet) more
  than one event loop.

---

## 2026-09-26: Features, a load test, live comments

**Load test** (docs/LOAD.md): 15 -> 450 req/s on 100k posts after eight
fixes, the deepest being storage layout (SQLite walks the overflow pages
of every large value before the column it wants, so post bodies moved out
of the post row) and a search that ranked every match on the single event
loop (a denial of service by typing a common word).

**Datastar: first set aside, then adopted.** By default it compiles
expressions with Function() ('unsafe-eval'); its CSP mode needs a fresh
nonce per full page, which looked incompatible with a shared page cache.
It is not: pages hold a mark only templates can write (bookended by byte
1, which the proved escaper never emits), and C writes a fresh nonce over
it on every serve, cached or not, matching the CSP header. Its main risk,
user content becoming executable data-* expressions, is ruled out by the
escaper's proof; that templates never put user text into an expression is
checked on rendered pages with hostile titles, tags and comments
(tests/app_test.py: every expression must match a template where only
numbers and slugs vary). Cost: 13 KB gzipped, cached. Used for likes,
comments and inline replies, deletes, live comments, search as you type,
"older posts" in place, the username check and co-authors; every form and
link still works without JavaScript.

**Live comments: one open stream per reader.** First built as long
polling; now a Datastar event stream held open: the handler loops (wait
for a comment on the post's eventfd, push patches) with a keep-alive every
25 s that also finds readers who left, and renews itself through a
patched element every ~10 minutes. The Bend runtime select()s over every
parked request each pass, so open streams are capped (512 per process);
hidden tabs close theirs (Datastar's default).

**Uniqueness is not a proof.** Handles are unique by a database index;
Bend proves only their shape (ASCII, lowered: no case or look-alike
variants). Checked at sign-up and again at account creation; tested.

## 2026-09-26: Usability walkthrough, and a held read snapshot

**Walkthrough.** A scripted headless-Chrome walk as a new user (click by
visible text, screenshot each step) found: five steps from sign-up to the
first typed word; a Write button that pointed at the page it was on; no
feedback after Publish; "Saved" in the editor of a published post while
the edits were not live; duplicated empty states; no author pages. Now:
name the blog, press Write (a POST that creates an untitled draft and
opens the editor), type, Publish (lands on the live post with a notice).
Drafts get a placeholder address (`draft-<hex>`) and take one from their
title on first publish, deduplicated in the blog (`db_publish_rename`);
a published address never changes. Author pages at `/u/<id>`, shown only
for people who have published (ids are sequential; otherwise anyone could
list every account's name).

**Bug: the server held a read snapshot after serving any post.**
`db_body` returned a pointer into SQLite's row and left the statement
stepping until the next call. A stepping statement is an open read
transaction, so: (1) after any other process wrote to the database (the
`sqlite3` CLI, a backup, a second server when we shard), every write here
failed with "database is locked" (BEGIN IMMEDIATE cannot start from a
stale snapshot); (2) WAL checkpoints could never finish, so the WAL would
grow without bound. Found because a test inserted a row directly. Fix:
the body is passed to a callback and the statement reset at once;
`db_core_test` now checks that no statement is left busy. The server also
logs SQLite's message when a write fails (it silently answered 500).

## 2026-09-26: The UI pass, and a data-loss bug it found

**Design.** One stylesheet written by hand (11.7 KB, 3.4 KB gzipped),
system fonts only, light and dark from `prefers-color-scheme`. Pages still
ship no JavaScript except the editor and the passkey pages. Assets are
compiled into the server and served at `/s/<name>?v=<hash>` with
`Cache-Control: immutable`, so the stylesheet costs one request per
visitor per release; pages are `no-store`.

**Usability.** Addresses (slugs) are made from titles when left empty
(`Text.slugify`, the result still refined by `mk_slug`). Publish saves
and publishes in one step, needing both an EditPost and a PublishPost
permit. Members see an Edit link on posts. The editor has an auto-growing
title and text, Ctrl/Cmd+S, a leave-page warning while edits are unsent,
confirmation for delete and unpublish, and a coloured sync status.

**Bug: newlines lost when the editor opened an old post.** The escaper
(proved never to emit a control character) did so by *dropping* them,
newlines included. The editor's textarea is filled through it, so a post
written without the editor (no CRDT operations yet) opened as one line,
and the editor then seeded its operations from that text: saving would
have flattened the post. The proof held; the spec was too coarse. Fix:
the escaper now encodes newline and tab as `&#10;` and `&#9;` (the safety
proof extended by two lemmas), and the textarea gets one sacrificial
newline, which the HTML parser drops, so a leading blank line survives.
Regression test in `tests/collab_test.py`. Lesson: a safety law says
nothing about fidelity. A round-trip law (unescape(esc(s)) == s for
text without other control characters) would have caught this; it is on
the list.

**Browser gotcha.** `form.requestSubmit()` called synchronously inside
the same form's submit handler is silently ignored (the form is still
"firing submission events"). The editor's flush-then-submit handler only
awaited when there was something to send, so a save with nothing pending
did nothing. Resubmitting from a new task fixes it.

## 2026-09-26: Phases 2–4: login, content, collaboration, the benchmark

### Passkeys (Phase 2)
- Sign-up by emailed link, passkey-only login, recovery by email; WebAuthn
  parsed strictly in Bend (JSON subset, canonical CBOR "none" attestation,
  canonical COSE ES256 key); sessions only from RegOk/LoginOk (laws + lint);
  C re-verifies login signatures with the stored key in the transaction.
- Tested with a pure-Python software authenticator (64 flow/attack tests)
  and in real headless Chrome with a virtual authenticator.
- **Found by the real browser:** textareas submit CRLF; every real save
  failed with 400 until bodies normalized CRLF to LF.
- **BearSSL v0.6 was the wrong pin** (later P-256 carry fixes); pinned
  upstream master and use the portable m31 curve code.

### Markdown (Phase 3)
- Safety is structural: `spec/markup.bend` defines a Node type that can
  only express escaped text, allowlisted tags and url_ok links; stored HTML
  is provably `html(node)` (law markup_rendered). The parser's bugs can only
  mis-format.
- **DoS found and fixed:** strict evaluation made marker searches pay the
  whole window even after a match; unclosed links rescanned. 1 MB of `*`
  would have blocked the event loop for ~12 s. Now linear (~0.4 ms/KB).

### Collaboration (Phase 4)
- Fugue CRDT in Bend with merge commutative and idempotent (proved), and
  the tail-recursive merge the code runs proved equal to the specified one.
- **Bend's JS output overflowed browser stacks** at ~1,000 operations
  (non-tail recursion becomes host recursion; Chrome holds ~10k frames).
  Fixed by tail recursion everywhere, but then:
- **Bend's JS output was too slow per keystroke** (177 ms at 10k characters,
  2.5 s at 100k): each edit rebuilds the tree and walks the document. As
  planned in CLAUDE.md, the browser now runs `src/web/fugue.js`, an
  incremental implementation (0.3 ms per keystroke at 100k, 5 ms at 1M),
  **differentially fuzzed against the Bend reference**: ~32,000 checks over
  1,800 random multi-replica histories with reordered and partial delivery.
- **The fuzzer found a real bug** in the fast implementation: a delete that
  arrived while its target waited for its parent was lost when the target
  attached (replicas diverged). Fixed.
- Loading was O(n²) (2.2 s at 100k); batch application with one O(n)
  rebuild fixed it (377 ms).
- Tested in two real browsers as two users: concurrent edits, same-position
  typing without interleaving, offline editing and reconnect.

### The thesis (docs/PERF.md)
Against Next.js 16 / React 19, same pages and data: 9–25× server
throughput, 0 vs 168 KB (gzip) of JavaScript, 0 vs ~100 ms of main-thread
script per load on a throttled phone, `load` 4× sooner, first paint 15–25%
sooner. Found on the way: two SQLite indexing mistakes, and that
Cross-Origin-Opener-Policy costs 60–90 ms of first paint from about:blank.

### Deployment
- **Spike servers were reachable from the internet.** This machine turned
  out to be the real server (172.236.228.71), and two leftover spike
  processes were listening on 0.0.0.0 (Bend's `TCP.listen` binds all
  interfaces; our `Net.listen` binds loopback). Killed on discovery. Rule:
  anything started for an experiment binds 127.0.0.1 and is stopped after.

### Open problems
- **Novel-length documents on the server:** materializing in native Bend
  takes 1.7 s / 80 MB at 100k characters and 6.2 s / 249 MB at 300k, on the
  single event loop; Markdown rendering of the whole document adds more.
  Needs a fast materializer (C, differentially tested like fugue.js) and
  per-block rendering and storage.
- Associativity of merge is tested, not proved.
- Deterministic simulation, multi-core serving, response buffer pools.


---

## 2026-09-26 — Phase 1: the secure core works end to end

What exists: a strict HTTP parser, authorization, database, sessions, CSRF
defense and pages for blogs, posts, drafts and authors. Login (passkeys)
is not built yet; tests create sessions directly in SQLite.

### Guarantees, and what each rests on

| Guarantee | How | Kind |
|---|---|---|
| Escaped text never contains `< > " '` or controls | `html_esc_safe` | proved about the code |
| Parsed paths never contain `.`/`..`, encoded bytes; header values never CR/LF | refinement types (`http_*_ok`) | proved about the code |
| `Transfer-Encoding` always rejected, any case | `http_te_rejected` | proved about the code (per header line) |
| A read header can never be set twice | `http_no_dup` | proved about the code |
| Every Permit was allowed by the policy | `authz_permit_ok` | proved about the code |
| Policy: anon read-only, no cross-blog writes, owner-only management, no self-removal, drafts private, members-only writes | `authz_*` | proved about the spec |
| Cross-site POST never reaches a write; only POST writes | `route_csrf`, `route_only_post_writes` | proved about the code |
| User text is valid scalars without controls | `text_*_ok` | proved about the code |
| A Permit's facts are true when the write happens | `db_apply` re-check in `BEGIN IMMEDIATE` | tested (forged, stale, TOCTOU) |
| Drafts are unreadable to non-members through any query | SQL floor on every private query | tested |
| Owner membership survives any bug above | schema triggers | tested |
| Head scanning and session tokens are memory safe and correct | CBMC | bounded proof (16-byte heads; all tokens) |

### Numbers

- 21 laws, `bend PROOF.bend` in ~0.6 s.
- Mutation testing: 32 of 33 plausible bugs across all laws caught; the
  one miss (members-only writes) became a new law.
- Tests: 36 parser, 34 text, 49 end-to-end, 16 integration, C unit tests
  under ASan/UBSan, 4 CBMC harnesses, libFuzzer, 20k-request server fuzz.
- Throughput before the DB layer: 8,787 req/s vs 10,127 for a do-nothing
  C server (loopback, 2 cores).

### Findings

- **A law is only as strong as its predicates' location.** Predicates in
  code under test get weakened along with the code (found by mutation).
  All predicates now live in `spec/` (human-owned) or `LAWS.bend`.
- **Refinement types are the cheapest proofs.** Smart constructors carry a
  proof of the spec check; invariants then hold everywhere by typing, and
  forging one fails to type-check. Most HTTP and text laws cost ~5 lines.
- **In-band markers were a latent draft leak.** Replaced by typed segments
  plus an SQL floor on the body fetch.
- **Unary `Nat` literals blow the checker's stack** (`1048576` via
  `U32.to_nat`). Use `U32` for large limits.
- **BearSSL v0.6 was the wrong pin**: later upstream commits fix P-256
  carry bugs and a buffer overflow. Pinned upstream master instead.
- **`-ftrivial-auto-var-init=zero` breaks clang on Bend's runtime** (runs
  out of registers). Dropped for the combined build only.
- **`head_end` had an unstated precondition**, found by a unit test and
  now documented; the fuzzer and CBMC check the calling protocol.
- **Lingering close is necessary**: without it, a 431 for an oversized
  head was destroyed by a TCP reset before the client read it.
- Bend ergonomics: definition order, no mutual recursion (pass the class
  of the next character as an argument instead), no `let` before a
  `match`, binder order in matches, `+`/`-` quantities. `tools/bend_order.py`
  sorts definitions automatically.

### Known gaps (to do)

- Login: passkeys and email recovery.
- Markdown rendering (bodies are escaped plain text for now).
- The editor: local-first with a CRDT.
- Responses and query results still `malloc` (C_STYLE wants pools).
- Multi-core serving (`SO_REUSEPORT` is set; one process per core not yet
  run or measured).
- Rate limiting.
- Deterministic simulation.


Machine for all numbers below: cloud container, 2 vCPUs (x86-64), 3 GB RAM.
Server pinned to core 0, load generator (`spike/loadgen`) to core 1, loopback,
`Connection: close`, 32 connections, 5 s. Bend 2.0.29, clang 19.1.7.
Treat absolute numbers as rough; ratios are what matter.

---

## 2026-09-26 — Phase 0 spike: GO, with one design constraint

### 1. Bend Strings are expensive per character (confirmed, worse than expected)

Rendering a 14.7 KB blog index 2,000 times (`spike/render`):

| | per page | vs C |
|---|---|---|
| C, byte buffers | 0.033 ms | 1× |
| Bend native | 0.69 ms | ~21× |
| Bend JS lane | 1.86 ms | ~56× |

Breakdown (`spike/render/parts.bend`): every list node costs roughly
17–37 ns (allocate, write, free). The escaping logic itself is cheap; the
cost is text living in cons cells at all. Bend's own lexer benchmark shows
~2× vs C, but that workload does more work per character than copying.

### 2. Bend's event loop and TCP are nearly as fast as C

| server (tiny response) | req/s |
|---|---|
| C, blocking accept loop | 10,093 |
| Bend HTTP demo | 9,157 |

### 3. The fix: Bend emits a small "render plan", C splices bytes

Bend builds only escaped user fields plus markers; a custom C effect
(`Page.send`) expands markers into static template chunks and stored,
pre-sanitized bodies, then sends. Output is byte-identical.

| 14.7 KB page | req/s |
|---|---|
| C, static bytes | 9,884 |
| Bend, whole page as a String | 1,136 |
| Bend, bodies as markers | 1,648 |
| Bend, bodies + template chunks as markers | 1,864 |
| same, and bulk text never enters Bend at all | **9,017** |

The last row is the design: **within ~9% of a C server that does no work.**
Rule: bulk text must never become a Bend String, not even to be dropped
(dropping walks the list too).

### 4. SQLite from Bend works

A foreign effect queries the 40 newest post titles from a 100k-post DB
(`spike/db`), per request:

| | req/s |
|---|---|
| query on an IO helper thread (`io_work`) | 3,921 |
| query inline on the event loop | **5,344** |
| (same query in plain C: 24 µs) | |

The helper-thread handoff costs ~120 µs on a single pinned core. Short
indexed reads should run inline (the better-sqlite3 argument); writes and
anything slow go to helpers or a single writer.

### 5. Proofs work, and are fast to check

`LAWS.bend: html_esc_safe`: for any input, `Html.esc` emits no `<` `>` `"`
`'` and no control characters. Proved in ~60 lines; `bend PROOF.bend`
checks in 0.44 s.

**Important negative finding.** The first version of the law used a
predicate defined in the implementation file. Mutation testing showed that
weakening the implementation weakened the law too, and the proof still
passed. Fixed by defining the spec in `LAWS.bend`. After the fix, 6/6
mutations are rejected (raw `<`, control chars, DEL, `"`, a broken entity,
no escaping at all).

Rule: **laws may only use predicates defined in `LAWS.bend`**, and every
law gets mutation-tested once to show it can fail.

### 6. Security issue the spike found

The marker design means a control character in user text could forge a
reference to another post's body. The proven escaper drops all control
characters, and the law covers it. Every path that puts user text into a
render plan must go through `Html.esc`; that needs its own law later
(e.g. render plans are built only from escaped text and typed markers).

### 7. Friction and gaps

- No bytes type: `TCP.send`/`recv` use `String`. Bulk I/O needs custom
  effects.
- `bend -o bin` has no hook for linker flags or extra objects. We build
  `bend x.bend -o x.c`, then clang ourselves (which we need anyway for the
  hardening flags in `docs/C_STYLE.md`).
- `TCP.listen` doesn't set `SO_REUSEPORT`, and there is one event loop per
  process. Multi-core serving needs a custom listen effect and one process
  per core. Not measured yet (2 cores, one used by the load generator).
- Container setup: no root, so LLVM 19 lives in `~/opt` and `spike/cc.sh`
  wraps it (lld + compiler-rt, no GCC toolchain).
- Checker errors are terse but accurate; the main things to learn were
  declaration order, termination (shrinking argument first), affinity
  (`+`), and erasing proof-only parameters (`-`).

### Verdict

**Go.** Bend works for this, with one hard design rule: Bend decides and
escapes; C moves bulk bytes.
