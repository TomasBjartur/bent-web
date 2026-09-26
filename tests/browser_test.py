#!/usr/bin/env python3
"""Real-browser passkey test: headless Chrome with a virtual authenticator.

Drives Chrome over the DevTools protocol (a minimal WebSocket client, stdlib
only). Exercises the real passkey.js, the CSP, the Secure cookie on
localhost, and Chrome's own WebAuthn encodings end to end.

usage: CHROME=path/to/chrome-headless-shell tests/browser_test.py
"""
import json, os, re, socket, sqlite3, subprocess, sys, tempfile, time, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cdp import WS, wait_port, start_chrome, page_ws

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORT = 8097
BASE = f"http://localhost:{PORT}"
fails = 0


def check(name, ok, detail=""):
    global fails
    fails += 0 if ok else 1
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else f"   {detail}"))


def main():
    tmp = tempfile.mkdtemp()
    dbpath = os.path.join(tmp, "blog.db")
    env = dict(os.environ, PORT=str(PORT), BLOG_DB=dbpath, BLOG_ORIGIN=BASE, BLOG_RP_ID="localhost")
    srv = subprocess.Popen([os.path.join(ROOT, "build/server")], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    chrome = start_chrome(9333, f"{tmp}/chrome")
    try:
        wait_port(PORT)
        run(dbpath)
    finally:
        chrome.terminate()
        srv.terminate()
        chrome.wait()
        srv.wait()
    print(f"\n{fails} failure(s)")
    sys.exit(1 if fails else 0)


def run(dbpath):
    ws = page_ws(9333)
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
       "document.querySelector('[name=title]').value = 'Eve <writes>';"
       "document.querySelector('form[action=\"/blogs\"]').submit()")
    check("blog created", wait_path("/dash/eve"), js("location.href"))
    js("document.querySelector('input[name=slug]').value = 'hello';"
       "document.querySelector('[name=title]').value = 'Hello';"
       "document.querySelector('form[action=\"/dash/eve/posts\"]').submit()")
    time.sleep(0.8)
    check("post created, editor open", (js("location.pathname") or "").startswith("/edit/"), js("location.href"))
    # Type, then press Publish: saves the text and publishes in one step.
    js("const t = document.getElementById('editor'); t.value = 'First line\\n<img src=x onerror=alert(1)>';"
       "t.dispatchEvent(new Event('input', {bubbles: true}));"
       "document.querySelector('button[value=publish]').click()")
    time.sleep(1.5)
    check("Publish button: now published", "Unpublish" in (js("document.body.innerText") or ""), js("document.body.innerText"))
    go(BASE + "/b/eve/hello")
    check("published post renders", "First line" in (js("document.body.innerText") or ""))
    check("XSS payload is inert text", js("document.querySelectorAll('img').length") == 0 and
          "<img src=x onerror=alert(1)>" in (js("document.body.innerText") or ""))

    # Nothing was blocked by the CSP, and there were no console errors.
    errors = [e for e in ws.events if e.get("method") in ("Log.entryAdded", "Runtime.exceptionThrown")
              and (e["params"].get("entry", {}).get("level") == "error" or e.get("method") == "Runtime.exceptionThrown")]
    check("no console errors or CSP violations", not errors, [e["params"] for e in errors][:3])


main()
