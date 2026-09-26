#include "/home/claude/web/vendor/sqlite/sqlite3.h"
#include <stdio.h>
#include <time.h>
int main(void) {
  sqlite3* db; sqlite3_stmt* st;
  sqlite3_open_v2("blog.db", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, NULL);
  sqlite3_prepare_v3(db, "SELECT title FROM post WHERE blog_id = ?1 ORDER BY created_ms DESC LIMIT ?2", -1, SQLITE_PREPARE_PERSISTENT, &st, NULL);
  struct timespec a, b; clock_gettime(CLOCK_MONOTONIC, &a);
  long bytes = 0;
  for (int k = 0; k < 20000; k++) {
    sqlite3_bind_int(st, 1, 7); sqlite3_bind_int(st, 2, 40);
    while (sqlite3_step(st) == SQLITE_ROW) bytes += sqlite3_column_bytes(st, 0);
    sqlite3_reset(st);
  }
  clock_gettime(CLOCK_MONOTONIC, &b);
  double us = ((b.tv_sec - a.tv_sec) * 1e9 + (b.tv_nsec - a.tv_nsec)) / 1e3 / 20000;
  printf("query: %.1f us each (bytes %ld)\n", us, bytes);
}
