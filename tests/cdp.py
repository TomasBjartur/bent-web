"""A minimal Chrome DevTools Protocol client (stdlib only), and helpers to
start headless Chrome from ~/opt (see tools/setup_chrome.sh)."""
import base64, json, os, socket, struct, subprocess, time, urllib.parse, urllib.request

CHROME = os.environ.get("CHROME", os.path.expanduser("~/opt/chrome-headless-shell-linux64/chrome-headless-shell"))
LIBS = os.path.expanduser("~/opt/chromelibs/usr/lib/x86_64-linux-gnu")


class WS:
    """Just enough of RFC 6455 for the DevTools protocol (client side)."""

    def __init__(self, url):
        u = urllib.parse.urlparse(url)
        self.s = socket.create_connection((u.hostname, u.port), timeout=30)
        key = base64.b64encode(os.urandom(16)).decode()
        self.s.sendall((f"GET {u.path} HTTP/1.1\r\nHost: {u.hostname}:{u.port}\r\nUpgrade: websocket\r\n"
                        f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            buf += self.s.recv(4096)
        assert b" 101 " in buf.split(b"\r\n")[0], buf
        self.rest = buf.split(b"\r\n\r\n", 1)[1]
        self.id = 0
        self.events = []

    def _read(self, n):
        while len(self.rest) < n:
            self.rest += self.s.recv(65536)
        out, self.rest = self.rest[:n], self.rest[n:]
        return out

    def send(self, obj):
        data = json.dumps(obj).encode()
        head = bytearray([0x81])
        n = len(data)
        if n < 126:
            head.append(0x80 | n)
        elif n < 65536:
            head += bytes([0x80 | 126]) + struct.pack(">H", n)
        else:
            head += bytes([0x80 | 127]) + struct.pack(">Q", n)
        mask = os.urandom(4)
        self.s.sendall(bytes(head) + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    def recv(self):
        b0, b1 = self._read(2)
        n = b1 & 0x7F
        if n == 126:
            n = struct.unpack(">H", self._read(2))[0]
        elif n == 127:
            n = struct.unpack(">Q", self._read(8))[0]
        return json.loads(self._read(n))

    def call(self, method, params=None, session=None):
        self.id += 1
        msg = {"id": self.id, "method": method, "params": params or {}}
        if session:
            msg["sessionId"] = session
        self.send(msg)
        while True:
            m = self.recv()
            if m.get("id") == self.id:
                if "error" in m:
                    raise RuntimeError(f"{method}: {m['error']}")
                return m.get("result", {})
            self.events.append(m)


def wait_port(port):
    for _ in range(100):
        try:
            socket.create_connection(("127.0.0.1", port), timeout=0.2).close()
            return
        except OSError:
            time.sleep(0.1)
    raise RuntimeError(f"port {port} never opened")



def start_chrome(port, profile):
    env = dict(os.environ, LD_LIBRARY_PATH=LIBS)
    p = subprocess.Popen([CHROME, "--headless", "--no-sandbox", "--disable-gpu", f"--remote-debugging-port={port}",
                          f"--user-data-dir={profile}", "about:blank"], env=env,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    wait_port(port)
    return p


def page_ws(port):
    targets = json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list"))
    return WS(next(t for t in targets if t["type"] == "page")["webSocketDebuggerUrl"])
