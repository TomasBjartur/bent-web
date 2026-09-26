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
  "Cross-Origin-Resource-Policy: same-origin\r\n"
  "Cache-Control: no-store\r\n";

#endif
