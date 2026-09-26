# Findings

Results of the experiment, including negative ones. Newest first.

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
