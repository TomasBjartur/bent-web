# Network effects (implemented in src/effects/net.c).
# Strings from the network are raw bytes: one Char per byte (0..255).
import Base

# Listen on 127.0.0.1:port (the socket made by workers, if any).
def listen(port: U32) -> IO(Result<&1, &1, U32 & String, Listener>):
  import "./effects/net.c"

# With BLOG_WORKERS=n (n > 1): migrates the database (at db), forks n worker
# processes sharing the port and answers each its index; the calling
# process supervises them and never answers (src/effects/net.c). Otherwise
# answers 0. Must come before the database is opened.
def workers(port: U32, db: String) -> IO(U32):
  import "./effects/net.c"

# Read a request head (until CRLFCRLF), at most 8192 bytes, within
# timeout_ms. Answers the bytes read, which may include the start of the
# body. Fails with an HTTP status to answer (503, 431, 408) or 1 (just close).
def read_head(sock: Socket, timeout_ms: U32) -> IO(Socket & Result<&1, &1, U32 & String, String>):
  import "./effects/net.c"

# Read exactly n more body bytes (n <= 1 MiB) within timeout_ms. Fails with
# 503, 413, 408 or 1 (just close).
def read_body(sock: Socket, n: U32, timeout_ms: U32) -> IO(Socket & Result<&1, &1, U32 & String, String>):
  import "./effects/net.c"

# Content types for respond.
def ct_html() -> U32:
  0

def ct_text() -> U32:
  1

def ct_sse() -> U32:
  2

def ct_json() -> U32:
  3

# Send a complete response. The head (status line, Content-Type,
# Content-Length, security headers) is built in C from these numbers.
def respond(sock: Socket, status: U32, ctype: U32, body: String) -> IO(Socket & Result<&1, &1, U32 & String, Unit>):
  import "./effects/net.c"
