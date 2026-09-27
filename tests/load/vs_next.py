#!/usr/bin/env python3
"""The load test's signed-out reads against the Next.js baseline
(baseline/next: the same public pages, the same SQLite file, the same
queries). Next has no sign-in or writes, so the mix is the load test's
signed-out page views only: posts, blog pages, home, tags, authors,
search (about 80% of the full mix).

Each server alone on core 0, the load generator on core 1: ours with its
page cache (as deployed), ours with none (BLOG_PAGE_CACHE=0: every page
made per request, as Next's force-dynamic pages are), and Next. Two rounds.
Prints requests per second and, per category, the median latency.

usage: tests/load/vs_next.py DB   (DB: from make_data.py; needs build/server,
       build/mixgen, baseline/next built, ~/opt/node)
"""
import json, os, socket, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HERE = os.path.dirname(os.path.abspath(__file__))
NODE = os.path.expanduser("~/opt/node/bin")
PUBLIC = {"post", "blog", "home", "tag", "author", "search"}


def wait(port, path, secs=120):
    end = time.time() + secs
    while time.time() < end:
        try:
            s = socket.create_connection(("127.0.0.1", port), timeout=1)
            s.sendall(f"GET {path} HTTP/1.1\r\nHost: localhost\r\n\r\n".encode())
            if s.recv(64).startswith(b"HTTP/1.1 200"):
                s.close()
                return
            s.close()
        except OSError:
            pass
        time.sleep(0.3)
    sys.exit(f"port {port} did not come up")


def run(port, mixfile, seed, secs=15):
    out = subprocess.run(["taskset", "-c", "1", os.path.join(ROOT, "build/mixgen"), str(port), "32", str(secs), mixfile, str(seed)],
                         capture_output=True, text=True, check=True).stdout
    return json.loads(out)


def main():
    db = sys.argv[1]
    tmp = tempfile.mkdtemp()
    full, mix = os.path.join(tmp, "full.mix"), os.path.join(tmp, "public.mix")
    subprocess.run([sys.executable, os.path.join(HERE, "make_mix.py"), db, full, "--n", "60000", "--seed", "11"], check=True)
    with open(full) as f, open(mix, "w") as g:
        g.writelines(line for line in f if line.split("\t", 1)[0] in PUBLIC)
    env = dict(os.environ, BLOG_DB=db, NEXT_TELEMETRY_DISABLED="1", PATH=NODE + ":" + os.environ["PATH"], BLOG_WORKERS="1")
    servers = {
        "ours": (8095, ["taskset", "-c", "0", os.path.join(ROOT, "build/server")], dict(env, PORT="8095"), ROOT),
        "ours, no cache": (8096, ["taskset", "-c", "0", os.path.join(ROOT, "build/server")], dict(env, PORT="8096", BLOG_PAGE_CACHE="0"), ROOT),
        "next": (3000, ["taskset", "-c", "0", os.path.join(NODE, "node"), "node_modules/next/dist/bin/next", "start", "-p", "3000"], env,
                 os.path.join(ROOT, "baseline/next")),
    }
    results = {}
    for rnd in (1, 2):
        for name, (port, cmd, e, cwd) in servers.items():
            srv = subprocess.Popen(cmd, env=e, cwd=cwd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                wait(port, "/")
                run(port, mix, 1, 5)  # warm up
                r = run(port, mix, 100 + rnd)
                results.setdefault(name, []).append(r)
                cats = "  ".join(f"{k} {c['p50_ms']:.1f}" for k, c in sorted(r["cats"].items()))
                print(f"round {rnd}  {name:15} {r['req_s']:7.0f} req/s  errors {r['errors']}   p50 ms: {cats}", flush=True)
            finally:
                srv.terminate()
                srv.wait(timeout=20)
    json.dump(results, open(os.path.join(ROOT, "docs/vs_next_load.json"), "w"), indent=1)


main()
