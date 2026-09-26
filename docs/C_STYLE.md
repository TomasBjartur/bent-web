# C style guide

Based on TigerStyle (TigerBeetle), tightened for security. Applies to every
C file we write: Bend foreign effects, the simulator, tests and tools.

Bend's proofs stop at the foreign boundary. Every law that depends on C is
only as strong as that C. So the C layer is kept **small, simple and
over-checked**. Order of priorities: safety, then performance, then developer
experience.

## 1. Scope: keep C small

- C exists only where Bend can't do the job or measurements show Bend is too
  slow. Each new C effect needs a written reason in its header.
- One effect does one thing. If it grows past ~300 lines, split it or move
  logic back into Bend.
- No business logic in C. Decisions (who may do what) live in Bend, where they
  can be proved. C moves bytes, calls SQLite, and does crypto.

## 2. Every effect file starts with a contract

```c
// EFFECT: Db.post_body(post_id: U32) -> IO(Result<.., Bytes>)
// WHY C:  streams stored HTML without converting to a Bend String.
// PRE:    post_id != 0. Db handle is open.
// POST:   returns exactly the bytes stored for post_id, or Fail.
// LAWS THAT DEPEND ON THIS: no_xss (assumes bytes are unmodified).
// VERIFIED BY: unit tests, fuzz target db_post_body_fuzz, CBMC harness
//              (bound: 4 KiB), deterministic simulation.
```

The list of laws that depend on the effect is required. It is how we keep the
trust boundary honest.

## 3. Assertions

- Use our own `ASSERT(x)` macro. It is **always on, including in production**,
  and fails stop. Never use `assert()`, which `NDEBUG` removes.
- At least **two assertions per function** on average: arguments, return
  values, invariants.
- **Pair assertions:** check a property where data is written and again where
  it is read (e.g. before `sqlite3_bind` and after `sqlite3_column`).
- Assert both the positive space (what must hold) and the negative space (what
  must never happen).
- Check compile-time facts with `_Static_assert` (sizes, limits, struct layout).
- Assertions are for **programmer errors**. Bad input from the network is not
  a programmer error: handle it and return `io_fail`. Never crash on user input.

## 4. Memory

- **No dynamic allocation after startup** in our own code. Fixed-size buffers
  and pools are sized from named limits at init.
  - Exception: Bend's runtime helpers (`io_str`, `io_cstr`) allocate. Keep
    their use at the boundary, and free what we own on every path.
- No variable-length arrays. No `alloca`.
- Every buffer has an explicit length next to it. No NUL-terminated strings
  for untrusted data; use `(ptr, len)` pairs.
- Zero buffers that held secrets with `explicit_bzero` before reuse or return.

## 5. Control flow

- **No recursion.** All call depth is fixed and known.
- **Every loop has a fixed upper bound**, stated as a named constant and
  asserted. A loop that could run forever (like an accept loop) is documented
  as such.
- Functions stay under **70 lines**. Simple, explicit branches; no clever
  macros; no `goto` except a single cleanup label per function.
- Handle **every return value**. Unused results are compile errors
  (`__attribute__((warn_unused_result))` on our functions).

## 6. Integers

- Use sized types only (`uint32_t`, `int64_t`, `size_t` for sizes). No bare
  `int`/`long` for data.
- **All arithmetic on untrusted values uses checked builtins**
  (`__builtin_add_overflow`, `__builtin_mul_overflow`). Lengths and offsets
  from the network are untrusted.
- No implicit narrowing: `-Wconversion` is on and clean.
- Put units and qualifiers last in names: `timeout_ms`, `body_bytes_max`,
  `session_ttl_s`.

## 7. Limits

Everything has a limit, named in one header (`limits.h`) with a comment on why:
request size, header count, body size, post size, users per blog, sessions per
user, SQL rows per query, concurrent connections. Exceeding a limit is a
handled error, never undefined behavior.

## 8. Security rules

- **Banned functions:** `strcpy`, `strcat`, `sprintf`, `vsprintf`, `gets`,
  `strtok`, `atoi`/`atol`, `scanf` family, `rand`, `system`, `popen`. Enforced
  by a check script.
- **SQL:** prepared statements with bound parameters only. Never build SQL
  from strings. Statements are prepared once at startup.
- **SQLite settings:** WAL mode, `SQLITE_DBCONFIG_DEFENSIVE`,
  `SQLITE_DQS=0`, foreign keys on, trusted schema off, busy timeout set.
- **Crypto:** a vetted library only (e.g. BearSSL), pinned by hash. Never
  hand-roll a primitive. Compare secrets in constant time. Randomness comes
  from the OS (`getrandom`), never from a seeded PRNG outside the simulator.
- **Logging:** never log secrets, tokens, passkey data or email links.
- **Threads:** work passed to `io_work` runs on a helper thread and touches
  only its `IoWork`. No shared mutable state between threads.

## 9. Determinism (for the simulator)

- No direct calls to the clock, randomness, or network outside one small
  platform layer. The simulation build swaps that layer for a seeded fake.
- No behavior that depends on uninitialized memory, hash-table iteration
  order, or thread timing.

## 10. Build

Clang only (Bend requires it). All builds:

```
-std=c11 -Wall -Wextra -Werror -Wconversion -Wsign-conversion -Wshadow
-Wvla -Wimplicit-fallthrough -Wformat=2 -Wnull-dereference
-fstack-protector-strong -D_FORTIFY_SOURCE=3 -ftrivial-auto-var-init=zero
-fno-strict-aliasing -fPIE -pie -Wl,-z,relro,-z,now
```

Exception: the server binary is one translation unit containing Bend's
runtime. There, `-ftrivial-auto-var-init=zero` is omitted (clang 19 runs
out of registers on the runtime with it), and warnings are not enforced
because the runtime is not our code. Our pure C cores (`src/c/`) are also
compiled standalone with every flag above and `-Werror`, by
`tests/c/build.sh`. Keep logic in the cores and glue in `src/effects/`
thin.

Debug and test builds also add `-fsanitize=address,undefined` (and
`-fsanitize=thread` for code using `io_work`).

## 11. Verification ladder

Every C effect climbs as high as it can. The contract header records how far.

1. **Assertions** (section 3), always on.
2. **Unit tests**, including every error path.
3. **Sanitizers**: ASan, UBSan, and TSan where threads are involved.
4. **Fuzzing**: a libFuzzer target for every function that touches
   untrusted bytes, run with sanitizers, seed corpus committed.
5. **CBMC**: bounded proofs of memory safety, no overflow and all assertions,
   up to stated input sizes. Required for parsers and anything touching
   untrusted lengths.
6. **Deterministic simulation**: the effect runs inside the whole-system
   simulator under injected faults.

An effect that a law depends on must reach at least level 5, unless its
header explains why it can't.

## 12. Dependencies

Vendored, pinned by hash, with a written reason and a list of what we use
from it. Currently expected: SQLite, one crypto library. Nothing else without
discussion.
