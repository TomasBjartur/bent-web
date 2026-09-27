// Security headers sent on every response (by src/effects/net.c and
// src/effects/db.c). The CSP allows only same-origin scripts, styles and
// connections; there is no inline script or style anywhere. HTML pages get
// the same policy plus a fresh nonce per response (NET_HTML_CSP_FMT), which
// Datastar uses to compile the page's data-* expressions into scripts; no
// page ever allows 'unsafe-eval'.
#ifndef BLOG_HTTP_HEADERS_H
#define BLOG_HTTP_HEADERS_H

static const char NET_SECURITY_HEADERS[] =
  "Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; "
  "img-src 'self'; connect-src 'self'; form-action 'self'; frame-ancestors 'none'; "
  "base-uri 'none'\r\n"
  "X-Content-Type-Options: nosniff\r\n"
  "Referrer-Policy: same-origin\r\n"
  "Cross-Origin-Opener-Policy: same-origin\r\n"
  "Cross-Origin-Resource-Policy: same-origin\r\n";

// The same policy for HTML pages, with the response's nonce (32 hex).
#define NET_HTML_CSP_FMT \
  "Content-Security-Policy: default-src 'none'; script-src 'self' 'nonce-%s'; style-src 'self'; " \
  "img-src 'self'; connect-src 'self'; form-action 'self'; frame-ancestors 'none'; " \
  "base-uri 'none'\r\n"
#define NET_OTHER_HEADERS \
  "X-Content-Type-Options: nosniff\r\n" \
  "Referrer-Policy: same-origin\r\n" \
  "Cross-Origin-Opener-Policy: same-origin\r\n" \
  "Cross-Origin-Resource-Policy: same-origin\r\n"

// Pages are never cached (they depend on the session); assets are served
// under versioned URLs and cached forever.
static const char NET_NO_STORE[] = "Cache-Control: no-store\r\n";
// A signed-out visitor's page is public: revalidated every time and never
// kept by shared caches, but the browser may keep it for Back (its
// back/forward cache restores the page as it was: loaded posts, scroll).
// Anything seen signed in stays no-store (Back after logging out on a
// shared computer must not show it).
static const char NET_REVALIDATE[] = "Cache-Control: private, no-cache\r\n";
static const char NET_IMMUTABLE[] = "Cache-Control: public, max-age=31536000, immutable\r\n";

#endif
