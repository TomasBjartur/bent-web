// Security headers sent on every response (by src/effects/net.c and
// src/effects/db.c). The CSP allows only same-origin scripts, styles and
// connections; there is no inline script or style anywhere.
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

// Pages are never cached (they depend on the session); assets are served
// under versioned URLs and cached forever.
static const char NET_NO_STORE[] = "Cache-Control: no-store\r\n";
static const char NET_IMMUTABLE[] = "Cache-Control: public, max-age=31536000, immutable\r\n";

#endif
