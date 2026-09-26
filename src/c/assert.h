// Always-on assertions (docs/C_STYLE.md section 3). Never compiled out.
#ifndef BLOG_ASSERT_H
#define BLOG_ASSERT_H

#include <stdio.h>
#include <stdlib.h>

#define ASSERT(x)                                                          \
  do {                                                                     \
    if (!(x)) {                                                            \
      fprintf(stderr, "ASSERT failed: %s:%d: %s\n", __FILE__, __LINE__, #x); \
      abort();                                                             \
    }                                                                      \
  } while (0)

#endif
