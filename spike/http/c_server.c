// Baseline: single-threaded blocking C server, same behavior as the Bend demo
// (read request, send fixed response, close). Spike code, not production style.
// usage: c_server <port> <body_bytes>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static char resp[1 << 20];

int main(int argc, char **argv) {
  int port = atoi(argv[1]);
  int body = argc > 2 ? atoi(argv[2]) : 22;
  int hn = snprintf(resp, sizeof resp,
                    "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n");
  memset(resp + hn, 'x', (size_t)body);
  size_t len = (size_t)hn + (size_t)body;
  int l = socket(AF_INET, SOCK_STREAM, 0), one = 1;
  setsockopt(l, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons((uint16_t)port)};
  if (bind(l, (struct sockaddr *)&a, sizeof a) || listen(l, 1024)) { perror("bind"); return 1; }
  char buf[8192];
  for (;;) {
    int s = accept(l, NULL, NULL);
    if (s < 0) continue;
    if (recv(s, buf, sizeof buf, 0) > 0) send(s, resp, len, MSG_NOSIGNAL);
    close(s);
  }
}
