# Datastar 1.0.4

- Source: https://cdn.jsdelivr.net/gh/starfederation/datastar@1.0.4/bundles/datastar.js
- SHA-256: 727844adfc825ee651fb93c544a2a739986f9a21820a94524b35f0cac470cf91
  (checked by tools/bundle.py; a different file fails the build)
- License: MIT (LICENSE.md)

Why: server-driven interactivity (likes, comments, live updates, search
as you type, pagination) by patching HTML the server renders, with DOM
morphing. Used in CSP mode only: pages carry a fresh nonce per response
(src/effects/db.c) and the CSP never allows 'unsafe-eval'. Every data-*
attribute is code to Datastar; only templates may write them
(tools/lint.sh), and user text can never produce an attribute (the
proved escaper).
