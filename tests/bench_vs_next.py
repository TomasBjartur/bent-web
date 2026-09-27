#!/usr/bin/env python3
"""The thesis test: this server against a Next.js (React) baseline serving
the same pages from the same SQLite database.

Measures (1) server throughput and latency per page (server pinned to core
0, load generator to core 1), (2) bytes shipped (HTML + JavaScript, raw and
gzipped), (3) browser metrics in headless Chrome with 4x CPU throttling
(a mid-range phone): FCP, LCP, load, main-thread script time. Medians of
5 runs. Writes docs/bench.json.

usage: tests/bench_vs_next.py   (needs build/server, baseline/next built,
       spike/loadgen/loadgen, tools/setup_chrome.sh, ~/opt/node)
"""
import gzip, hashlib, html, json, os, random, re, socket, sqlite3, statistics, subprocess, sys, tempfile, time, urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cdp import start_chrome, page_ws, wait_port

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BEND, BEND_NC, NEXT = 8095, 8096, 3000
NODE = os.path.expanduser("~/opt/node/bin")
rng = random.Random(7)
WORDS = ("the quiet river of long evenings carries small boats past old walls where people talk about "
         "books music weather bread and the slow craft of writing well").split()


def sentence(n):
    w = [rng.choice(WORDS) for _ in range(n)]
    return " ".join(w).capitalize() + "."


def body_html():
    parts = []
    for i in range(12):
        if i % 4 == 3:
            parts.append("<h2>" + html.escape(sentence(4)) + "</h2>")
        elif i % 5 == 4:
            parts.append("<ul>" + "".join("<li>" + html.escape(sentence(6)) + "</li>" for _ in range(4)) + "</ul>")
        else:
            parts.append("<p>" + html.escape(" ".join(sentence(rng.randint(10, 20)) for _ in range(3))) + "</p>")
    return "".join(parts)


def make_db(path):
    """The current schema (our server creates it and runs every migration on
    an empty file), then 50 blogs of 40 posts, tags, likes, and comments:
    post-3 of each blog has 30 threads with replies (a post page shows 20)."""
    sys.path.insert(0, os.path.join(ROOT, "tests/load"))
    srv = subprocess.Popen([os.path.join(ROOT, "build/server")], env=dict(os.environ, BLOG_DB=path, PORT="8198", BLOG_WORKERS="1"),
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    wait_port(8198)
    srv.terminate()
    srv.wait()
    db = sqlite3.connect(path)
    for u in range(1, 201):
        db.execute("INSERT INTO user(id, email, name, handle, created_ms) VALUES (?, ?, ?, ?, 1)", (u, f"w{u}@example.com", f"Writer {u}", f"writer_{u}"))
    t, pid, cid = 1_700_000_000_000, 0, 0
    for b in range(1, 51):
        db.execute("INSERT INTO blog(id, slug, title, owner_id, created_ms) VALUES (?, ?, ?, ?, 1)", (b, f"blog-{b}", f"Blog number {b}", b))
        db.execute("INSERT INTO member VALUES (?, ?, 1)", (b, b))
        for p in range(40):
            t += 1000
            pid += 1
            h = body_html()
            text = re.sub(r"<[^>]+>", " ", h)
            db.execute("INSERT INTO post(id, blog_id, slug, title, body_md, body_html, published, created_ms, updated_ms, author_id, published_ms, "
                       "excerpt, body_len) VALUES (?, ?, ?, ?, '', '', 1, ?, ?, ?, ?, ?, ?)",
                       (pid, b, f"post-{p}", sentence(5)[:-1], t, t, b, t, " ".join(text.split())[:240], len(text)))
            db.execute("INSERT INTO post_body(post_id, body_md, body_html) VALUES (?, ?, ?)", (pid, text, h))
            for tag in rng.sample(["river", "books", "music", "bread", "craft"], 2):
                db.execute("INSERT INTO post_tag(post_id, tag) VALUES (?, ?)", (pid, tag))
            for u in rng.sample(range(1, 201), rng.randint(0, 12)):
                db.execute("INSERT INTO post_like VALUES (?, ?, 1)", (pid, u))
            threads = 30 if p == 3 else rng.randint(0, 3)
            for _ in range(threads):
                cid += 1
                top = cid
                c = sentence(rng.randint(8, 30))
                db.execute("INSERT INTO comment(id, post_id, parent_id, author_id, body_md, body_html, created_ms) VALUES (?, ?, NULL, ?, ?, ?, ?)",
                           (cid, pid, rng.randint(1, 200), c, f"<p>{html.escape(c)}</p>", t))
                for _ in range(rng.randint(0, 2)):
                    cid += 1
                    c = sentence(rng.randint(5, 20))
                    db.execute("INSERT INTO comment(id, post_id, parent_id, author_id, body_md, body_html, created_ms) VALUES (?, ?, ?, ?, ?, ?, ?)",
                               (cid, pid, top, rng.randint(1, 200), c, f"<p>{html.escape(c)}</p>", t))
    db.commit()
    db.execute("PRAGMA optimize")
    db.close()


def get(port, path):
    s = socket.create_connection(("127.0.0.1", port), timeout=10)
    s.sendall(f"GET {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".encode())
    out = b""
    while True:
        b = s.recv(65536)
        if not b:
            break
        out += b
    s.close()
    head, _, body = out.partition(b"\r\n\r\n")
    if b"transfer-encoding: chunked" in head.lower():
        data, rest = b"", body
        while rest:
            n, _, rest = rest.partition(b"\r\n")
            n = int(n, 16)
            if n == 0:
                break
            data, rest = data + rest[:n], rest[n + 2:]
        body = data
    return int(head.split(b" ")[1]), body


def weight(port, path):
    st, body = get(port, path)
    scripts = re.findall(rb'<script[^>]+src="([^"]+)"', body)
    js = b""
    for src in scripts:
        _, b = get(port, src.decode())
        js += b
    inline = b"".join(re.findall(rb"<script(?![^>]*src=)[^>]*>(.*?)</script>", body, re.S))
    return {"status": st, "html": len(body), "html_gz": len(gzip.compress(body)), "js_files": len(scripts),
            "js": len(js) + len(inline), "js_gz": len(gzip.compress(js)) + (len(gzip.compress(inline)) if inline else 0)}


def load(port, path, seconds=5):
    out = subprocess.run(["taskset", "-c", "1", os.path.join(ROOT, "spike/loadgen/loadgen"), str(port), "32", str(seconds), path],
                         capture_output=True, text=True).stdout
    m = dict(kv.split("=") for kv in out.split() if "=" in kv)
    return {"req_s": float(m["req/s"]), "p50_us": int(m["p50"][:-2]), "p99_us": int(m["p99"][:-2]), "errors": int(m["err"])}


# Each load starts from a page on another site (like a visitor arriving from
# a search engine): Chrome's site isolation then swaps renderer processes
# for both servers alike. Starting from about:blank instead would charge
# the Cross-Origin-Opener-Policy header an extra process swap (~60-90 ms of
# first paint in this setup) that a real visitor from another site already
# pays; see COOP_COST in the report.
def browser(ws, url, runs=5, start="http://127.0.0.1:8117/start.html"):
    res = []
    for _ in range(runs):
        ws.call("Network.clearBrowserCache")
        ws.call("Page.navigate", {"url": start})
        time.sleep(0.4)
        ws.call("Performance.enable")
        ws.call("Page.navigate", {"url": url})
        for _ in range(100):
            time.sleep(0.05)
            r = ws.call("Runtime.evaluate", {"expression": "document.readyState", "returnByValue": True})
            if r["result"]["value"] == "complete":
                break
        time.sleep(1.0)
        v = ws.call("Runtime.evaluate", {"expression": """(async () => {
            const nav = performance.getEntriesByType('navigation')[0];
            const fcp = (performance.getEntriesByName('first-contentful-paint')[0] || {}).startTime || 0;
            const lcp = await new Promise((r) => { let v = 0; new PerformanceObserver((l) => { for (const e of l.getEntries()) v = e.startTime; })
                              .observe({type: 'largest-contentful-paint', buffered: true}); setTimeout(() => r(v), 300); });
            return {ttfb: nav.responseStart, fcp, lcp, dcl: nav.domContentLoadedEventEnd, load: nav.loadEventEnd};
          })()""", "awaitPromise": True, "returnByValue": True})["result"]["value"]
        m = {x["name"]: x["value"] for x in ws.call("Performance.getMetrics")["metrics"]}
        v["script_ms"] = m.get("ScriptDuration", 0) * 1000
        v["task_ms"] = m.get("TaskDuration", 0) * 1000
        ws.call("Performance.disable")
        res.append(v)
    return {k: round(statistics.median(r[k] for r in res), 1) for k in res[0]}


def main():
    tmp = tempfile.mkdtemp()
    dbpath = os.path.join(tmp, "blog.db")
    make_db(dbpath)
    env = dict(os.environ, BLOG_DB=dbpath, PORT=str(BEND), NEXT_TELEMETRY_DISABLED="1", PATH=NODE + ":" + os.environ["PATH"])
    bend = subprocess.Popen(["taskset", "-c", "0", os.path.join(ROOT, "build/server")], env=dict(env, BLOG_WORKERS="1"),
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    # The same server with no page cache: every page made per request, as
    # Next's force-dynamic pages are (the fair per-request comparison).
    bend_nc = subprocess.Popen(["taskset", "-c", "0", os.path.join(ROOT, "build/server")],
                               env=dict(env, BLOG_WORKERS="1", PORT=str(BEND_NC), BLOG_PAGE_CACHE="0"),
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    nxt = subprocess.Popen(["taskset", "-c", "0", os.path.join(NODE, "node"), "node_modules/next/dist/bin/next", "start", "-p", str(NEXT)],
                           cwd=os.path.join(ROOT, "baseline/next"), env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    os.makedirs(os.path.join(tmp, "other"), exist_ok=True)
    open(os.path.join(tmp, "other", "start.html"), "w").write("<!doctype html><title>elsewhere</title><p>another site")
    other = subprocess.Popen([sys.executable, "-m", "http.server", "8117", "--bind", "127.0.0.1", "--directory", os.path.join(tmp, "other")],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    chrome = None
    report = {"machine": "cloud container, 2 vCPU; server on core 0, load generator on core 1",
              "pages": {"home": "/", "blog": "/b/blog-7", "post": "/b/blog-7/post-3", "tag": "/t/river", "author": "/u/7",
                        "search": "/search?q=river"}}
    try:
        wait_port(BEND)
        wait_port(BEND_NC)
        wait_port(NEXT)
        for port in (BEND, BEND_NC, NEXT):
            for path in report["pages"].values():
                for _ in range(30):
                    get(port, path)
        report["bend_nocache"] = {"server": {p: load(BEND_NC, path) for p, path in report["pages"].items()}}
        for name, port in (("bend", BEND), ("next", NEXT)):
            report[name] = {"weight": {}, "server": {}, "browser": {}}
            for page, path in report["pages"].items():
                report[name]["weight"][page] = weight(port, path)
                report[name]["server"][page] = load(port, path)
        chrome = start_chrome(9351, f"{tmp}/chrome")
        ws = page_ws(9351)
        ws.call("Page.enable")
        ws.call("Network.enable")
        ws.call("Emulation.setCPUThrottlingRate", {"rate": 4})
        wait_port(8117)
        for name, port in (("bend", BEND), ("next", NEXT)):
            for page, path in report["pages"].items():
                report[name]["browser"][page] = browser(ws, f"http://localhost:{port}{path}")
        report["coop_cost_from_about_blank"] = {
            "bend_post": browser(ws, f"http://localhost:{BEND}/b/blog-7/post-3", start="about:blank"),
            "next_post": browser(ws, f"http://localhost:{NEXT}/b/blog-7/post-3", start="about:blank")}
    finally:
        if chrome:
            chrome.terminate()
        bend.terminate()
        bend_nc.terminate()
        nxt.terminate()
        other.terminate()
    os.makedirs(os.path.join(ROOT, "docs"), exist_ok=True)
    json.dump(report, open(os.path.join(ROOT, "docs/bench.json"), "w"), indent=2)
    for page in report["pages"]:
        print(f"\n== {page}")
        s = report["bend_nocache"]["server"][page]
        print(f"  {'nocache':7} {s['req_s']:>8.0f} req/s  p50 {s['p50_us'] / 1000:6.1f} ms  p99 {s['p99_us'] / 1000:6.1f} ms  (ours, no page cache)")
        for name in ("bend", "next"):
            w, s, b = report[name]["weight"][page], report[name]["server"][page], report[name]["browser"][page]
            print(f"  {name:5} {s['req_s']:>8.0f} req/s  p50 {s['p50_us'] / 1000:6.1f} ms  p99 {s['p99_us'] / 1000:6.1f} ms  "
                  f"html {w['html'] / 1024:5.1f} KB  js {w['js'] / 1024:6.1f} KB ({w['js_gz'] / 1024:5.1f} gz, {w['js_files']} files)  "
                  f"fcp {b['fcp']:6.0f}  lcp {b['lcp']:6.0f}  load {b['load']:6.0f}  script {b['script_ms']:6.0f} ms")


main()
