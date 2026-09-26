# Project: proven blog platform in Bend 2

A multi-user blogging app (sign up, create blogs, write posts, edit together)
built to test two theses:

1. **Performance:** server-rendered hypermedia (Datastar) plus small,
   hand-written vanilla JS beats React-based apps on real metrics.
2. **Correctness:** most of a real web app can carry machine-checked proofs
   of its security properties, with a small, heavily tested C core for the rest.

This is an experiment. Record results honestly, including negative ones
("Bend was too slow for X", "this law was too costly to prove"), in
`docs/FINDINGS.md`.

## Standing goals

- **Formalize as much as possible.** For every new feature, ask what laws it
  should obey and try to prove them. When something can't be proved, write
  down why and how it's checked instead.
- **Real and non-trivial.** Not a demo: real auth, real multi-user data,
  real concurrency, production-grade limits and error handling.

## Features (v1)

- Sign up and log in with a passkey; recover or add a device via email link.
- Users create blogs and write posts (Markdown).
- Multiple authors per blog; invite and remove authors.
- Real-time collaborative, offline-capable post editor.
- Public reading pages: blog index, post page, author page.

Anything beyond this list (comments, feeds, search, images) is a later
decision.

## Choosing how each part runs

Decide per feature, and note the choice in the code:

- **Datastar SSR** when the work is bound by the database or shared state
  (reading pages, listings, settings, auth flows).
- **Local-first with sync** when users benefit from offline use, instant
  response, or real-time collaboration (the editor).
- **Vanilla JS** for purely client-side interaction, where a round trip to
  the server would be slower than doing it in the browser.

## Stack

- **Bend 2** (https://github.com/bendlang/bend): dependently typed, compiles to
  C (server) and JS (browser). Rules go in `LAWS.bend`, proofs in `PROOF.bend`.
  Run `bend guide` to learn it. Run `bend PROOF.bend` before every commit.
  Pin the compiler version: the C effect interface has no stability promise.
- **TigerStyle C** for foreign effects only. **Read `docs/C_STYLE.md` before
  writing or reviewing any C.** It is mandatory, not advisory.
- **SQLite**: WAL mode, busy timeout, one serialized writer, many readers,
  prepared statements only.
- **Datastar** for server-rendered pages and updates over SSE.
- **Vanilla JS** where the client must own the work (the editor).
- **Caddy** (or similar) in front for TLS. We do not implement TLS.
- Minimal dependencies. Each one needs a written reason.

## Where code goes

Default to Bend. Use C only when Bend can't do it or measurements show it's
too slow, and keep each C effect small.

**C (foreign effects):**
- SQLite binding
- Crypto: P-256 verification (passkeys), SHA-256, OS randomness. Use a vetted
  library; never hand-roll crypto.
- Byte passthrough for stored HTML and static files
- Handoff to a local mail relay for email

**Bend (with laws):**
- HTTP parsing with explicit bounds
- Routing, sessions, authorization, passkey and email-recovery flows
- HTML sanitizer and page templates
- Sync protocol and text CRDT, compiled to both C and JS

## Design rules

- **Bulk text never becomes a Bend String.** Bend strings cost ~17–37 ns per
  character (see `docs/FINDINGS.md`). Bend builds a small render plan: escaped
  user fields plus markers for static template chunks and stored bodies. A C
  effect splices in the bytes and sends. Posts are sanitized once, on save.
- **Laws only use predicates defined in `LAWS.bend`.** Never state a law with
  a predicate from the code under test. Mutation-test every new law once to
  show it can fail.
- **Explicit trust boundary.** Everything in Bend is proved or marked
  `@unsafe`. Everything foreign is listed, and for each one we record how it
  was checked (tests, fuzzing, CBMC, simulation).
- **Label every guarantee** as "proved about the code" or "proved about a
  model". Never blur the two.
- **Deterministic simulation.** The server must be able to run with simulated
  effects (TCP, time, randomness) driven by one seed, to test faults the
  proofs don't cover: drops, reordering, crashes, clock skew.
- **Auth:** passkeys only, with email as backup. Account security is only as
  strong as the email inbox; say so wherever it matters.

## Target laws

- Authorization: no request authenticated as user A modifies content owned by B.
- Sessions: every mutating handler requires a verified session, and none is
  issued without a successful passkey or email check.
- No XSS: stored and rendered HTML contains only allowed markup.
- Sync: merge is commutative, associative and idempotent (replicas converge).
- HTTP parser: never reads out of bounds; header and body sizes are limited.

## Editor

Multi-user, local-first. Text CRDT: **Fugue**. Content is Markdown, not rich
text (rich-text CRDTs roughly double the proof work). The merge is written and
proved in Bend. If Bend's JS output is too slow for typing, a hand-written JS
replica is kept and checked against it with differential fuzzing.

## JavaScript style

Performance-aware habits that help on every engine: stable object shapes,
monomorphic call sites, typed arrays for numeric data, no allocation in hot
loops, no `delete` on objects, batched DOM reads and writes. Tune further only
where profiling shows a problem. Test on Safari (JavaScriptCore), not just V8.

## Measuring the thesis

Build a React/Next baseline of the same core pages. Compare TTFB, LCP, INP,
JS bytes shipped, and server throughput. Without the baseline there is no
result.

## Known Bend 2 limits (as of v2.0.29)

- Strings are cons lists (~2× C on Bend's own lexer benchmark; check ourselves).
- Numbers: Nat up to 2^48, U32, F32. No U64. F32 has no proofs.
- No TLS, HTTP, JSON or regex libraries.
- Handle types must come from Base (a SQLite handle reuses an existing one).
- One event loop per process; `TCP.listen` has no `SO_REUSEPORT`.
  Blocking C work goes through `io_work` (costly handoff; short reads inline).
- No bytes type: TCP effects take and return `String`.
- No tactics or proof search: proofs are written by hand.
- The compiler is young and not fully audited. Report bugs upstream.

## Building

- Bend 2.0.29 (pinned). `bend PROOF.bend` must print "All terms check."
- Native builds: `bend x.bend -o x.c`, then clang with our own flags and
  objects (e.g. `vendor/sqlite`). `bend -o bin` can't add link flags.
- This container has no root: LLVM 19 is in `~/opt`, use `CC=spike/cc.sh`.

## Status

Phase 0 spike: **done, verdict GO** (details in `docs/FINDINGS.md`).
`spike/` holds throwaway measurement code (not C_STYLE-compliant).
`src/html.bend` + `LAWS.bend`/`PROOF.bend` hold the first real, proved code.
