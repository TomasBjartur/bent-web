#!/usr/bin/env python3
"""Real-browser passkey test: headless Chrome with a virtual authenticator.

Drives Chrome over the DevTools protocol (a minimal WebSocket client, stdlib
only). Exercises the real passkey.js, the CSP, the Secure cookie on
localhost, and Chrome's own WebAuthn encodings end to end.

usage: CHROME=path/to/chrome-headless-shell tests/browser_test.py
"""
import base64, json, os, re, socket, sqlite3, struct, subprocess, sys, tempfile, time, urllib.parse, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORT = 8097
BASE = f"http://localhost:{PORT}"
CHROME = os.environ.get("CHROME", os.path.expanduser("~/opt/chrome-headless-shell-linux64/chrome-headless-shell"))
fails = 0


def check(name, ok, detail=""):
    global fails
    fails += 0 if ok else 1
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else f"   {detail}"))


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


def main():
    tmp = tempfile.mkdtemp()
    dbpath = os.path.join(tmp, "blog.db")
    env = dict(os.environ, PORT=str(PORT), BLOG_DB=dbpath, BLOG_ORIGIN=BASE, BLOG_RP_ID="localhost")
    srv = subprocess.Popen([os.path.join(ROOT, "build/server")], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    libs = os.path.expanduser("~/opt/chromelibs/usr/lib/x86_64-linux-gnu")
    cenv = dict(os.environ, LD_LIBRARY_PATH=libs)
    chrome = subprocess.Popen([CHROME, "--headless", "--no-sandbox", "--disable-gpu", "--remote-debugging-port=9333",
                               f"--user-data-dir={tmp}/chrome", "about:blank"], env=cenv,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        wait_port(PORT)
        wait_port(9333)
        run(dbpath)
    finally:
        chrome.terminate()
        srv.terminate()
        chrome.wait()
        srv.wait()
    print(f"\n{fails} failure(s)")
    sys.exit(1 if fails else 0)


def run(dbpath):
    targets = json.load(urllib.request.urlopen("http://127.0.0.1:9333/json/list"))
    page = next(t for t in targets if t["type"] == "page")
    ws = WS(page["webSocketDebuggerUrl"])
    ws.call("Page.enable")
    ws.call("Runtime.enable")
    ws.call("Log.enable")
    ws.call("WebAuthn.enable")
    auth = ws.call("WebAuthn.addVirtualAuthenticator", {"options": {
        "protocol": "ctap2", "transport": "internal", "hasResidentKey": True, "hasUserVerification": True,
        "isUserVerified": True, "automaticPresenceSimulation": True}})["authenticatorId"]

    def go(url):
        ws.call("Page.navigate", {"url": url})
        time.sleep(0.6)

    def js(expr):
        r = ws.call("Runtime.evaluate", {"expression": expr, "awaitPromise": True, "returnByValue": True})
        return r.get("result", {}).get("value")

    def wait_path(path, secs=10):
        for _ in range(secs * 10):
            if js("location.pathname") == path:
                return True
            time.sleep(0.1)
        return False

    # Sign up through the real form.
    go(BASE + "/signup")
    js("document.querySelector('input[name=email]').value = 'eve@example.com';"
       "document.querySelector('input[name=name]').value = 'Eve';"
       "document.querySelector('form').submit()")
    time.sleep(0.8)
    check("sign-up form submitted", "Check your email" in (js("document.body.innerText") or ""), js("document.body.innerText"))
    db = sqlite3.connect(dbpath)
    body = db.execute("SELECT body FROM outbox WHERE to_email = 'eve@example.com'").fetchone()[0]
    link = re.search(r"(http://localhost:\d+/verify\?t=[0-9a-f]{64})", body).group(1)

    # Create a passkey with the virtual authenticator.
    go(link)
    check("verify page has the button", js("!!document.getElementById('passkey-register')") is True)
    js("document.getElementById('passkey-register').click()")
    check("registered and redirected to /dash", wait_path("/dash"), js("location.href + ' ' + document.body.innerText"))
    check("dashboard shows", "Your blogs" in (js("document.body.innerText") or ""))
    creds = ws.call("WebAuthn.getCredentials", {"authenticatorId": auth})["credentials"]
    check("authenticator holds one resident credential", len(creds) == 1 and creds[0]["isResidentCredential"], creds)
    cookies = ws.call("Network.getCookies", {"urls": [BASE]})["cookies"]
    sid = [c for c in cookies if c["name"] == "sid"]
    check("session cookie is HttpOnly, Secure, SameSite=Strict",
          len(sid) == 1 and sid[0]["httpOnly"] and sid[0]["secure"] and sid[0]["sameSite"] == "Strict", sid)
    check("script cannot read the session cookie", "sid=" not in (js("document.cookie") or ""))

    # Log out, then log in with the passkey.
    js("document.querySelector('header form').submit()")
    time.sleep(0.8)
    go(BASE + "/dash")
    check("logged out", js("location.pathname") == "/login")
    js("document.getElementById('passkey-login').click()")
    check("passkey login redirected to /dash", wait_path("/dash"), js("location.href + ' ' + document.body.innerText"))

    # Use the app as a real user: create a blog and a post, publish.
    go(BASE + "/dash")
    js("document.querySelector('input[name=slug]').value = 'eve';"
       "document.querySelector('input[name=title]').value = 'Eve <writes>';"
       "document.querySelector('form[action=\"/blogs\"]').submit()")
    check("blog created", wait_path("/dash/eve"), js("location.href"))
    js("document.querySelector('input[name=slug]').value = 'hello';"
       "document.querySelector('input[name=title]').value = 'Hello';"
       "document.querySelector('form[action=\"/dash/eve/posts\"]').submit()")
    time.sleep(0.8)
    check("post created, editor open", (js("location.pathname") or "").startswith("/edit/"), js("location.href"))
    js("document.querySelector('textarea').value = 'First line\\n<img src=x onerror=alert(1)>';"
       "document.querySelector('form.editor').submit()")
    time.sleep(0.8)
    js("document.querySelector('form[action$=\"/publish\"]').submit()")
    time.sleep(0.8)
    go(BASE + "/b/eve/hello")
    check("published post renders", "First line" in (js("document.body.innerText") or ""))
    check("XSS payload is inert text", js("document.querySelectorAll('img').length") == 0 and
          "<img src=x onerror=alert(1)>" in (js("document.body.innerText") or ""))

    # Nothing was blocked by the CSP, and there were no console errors.
    errors = [e for e in ws.events if e.get("method") in ("Log.entryAdded", "Runtime.exceptionThrown")
              and (e["params"].get("entry", {}).get("level") == "error" or e.get("method") == "Runtime.exceptionThrown")]
    check("no console errors or CSP violations", not errors, [e["params"] for e in errors][:3])


main()
