# Vendored dependencies

Each entry: version, source, sha256, and why we need it.

## sqlite
- Version 3.53.4, amalgamation from https://sqlite.org/2026/sqlite-amalgamation-3530400.zip
- sha256(sqlite3.c) = b1dd5d74ec7f29055a6684fa06fb3c2f6821c87dd38f9a458dfd2e8a1db28189
- Why: the database. `shell.c` removed (not needed).
