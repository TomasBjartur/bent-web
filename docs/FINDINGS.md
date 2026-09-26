# Findings

Results of the experiment, including negative ones. Newest first.

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
