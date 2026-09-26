# Vendored dependencies

Each entry: version, source, sha256, and why we need it.

## sqlite
- Version 3.53.4, amalgamation from https://sqlite.org/2026/sqlite-amalgamation-3530400.zip
- sha256(sqlite3.c) = b1dd5d74ec7f29055a6684fa06fb3c2f6821c87dd38f9a458dfd2e8a1db28189
- Why: the database. `shell.c` removed (not needed).

## bearssl
- Upstream git https://www.bearssl.org/git/BearSSL, pinned at commit
  7bea48e5e850ab4cafbe68d3765cdaba13a86d6f (2026-04-06), `inc/` and `src/` only.
- Not the v0.6 release: commits after v0.6 fix two P-256 carry-propagation
  bugs (m62, m64 implementations) and a buffer overflow in private key
  decoding. The v0.6 tarball (sha256 6705bba1...ff14) was checked to equal
  git tag v0.6, so provenance of the tag is established; the pinned commit
  is on the same upstream history.
- Why: SHA-256 (session token hashes), ECDSA P-256 verification (passkeys),
  HMAC. Constant-time, no dynamic allocation.
- We use the portable `br_ec_p256_m31` implementation for signature
  verification (conservative; not the m62/m64 code that had carry bugs).
