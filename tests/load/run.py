#!/usr/bin/env python3
"""Load test: the server on a synthetic database under a mixed workload.

Copies DB (the run writes to it), starts build/server pinned to core 0,
warms up, then runs tests/load/mixgen (core 1) at increasing concurrency,
and once with writes scaled up. Records per-category throughput, latency
percentiles and errors, and the server's memory and WAL size. Writes
docs/load.json.

usage: run.py DB [--secs S] [--conns 1,8,32,128,512]
"""
import argparse, json, os, shutil, sqlite3, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HERE = os.path.dirname(os.path.abspath(__file__))
PORT = 8190


def rss_mb(pid):
    for line in open(f"/proc/{pid}/status"):
        if line.startswith("VmRSS:"):
            return int(line.split()[1]) / 1024
    return 0.0


def mix(db, out, **kw):
    args = [sys.executable, os.path.join(HERE, "make_mix.py"), db, out]
    for k, v in kw.items():
        args += [f"--{k.replace('_', '-')}", str(v)]
    subprocess.run(args, check=True)


def run(port, conns, secs, mixfile, seed):
    out = subprocess.run(["taskset", "-c", "1", os.path.join(ROOT, "build/mixgen"), str(port), str(conns), str(secs), mixfile, str(seed)],
                         capture_output=True, text=True, check=True).stdout
    return json.loads(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("db")
    ap.add_argument("--secs", type=float, default=15)
    ap.add_argument("--conns", default="1,8,32,128,512")
    a = ap.parse_args()
    subprocess.run([os.environ.get("CC", os.path.join(ROOT, "spike/cc.sh")), "-O2", "-o", os.path.join(ROOT, "build/mixgen"), os.path.join(HERE, "mixgen.c")], check=True)
    work = a.db + ".run"
    for suffix in ("", "-wal", "-shm"):
        if os.path.exists(work + suffix):
            os.remove(work + suffix)
    src = sqlite3.connect(a.db)
    dst = sqlite3.connect(work)
    src.backup(dst)
    dst.close()
    src.close()
    mixes = {"normal": work + ".mix", "writes_x5": work + ".mix5"}
    mix(work, mixes["normal"], n=60000, seed=11)
    mix(work, mixes["writes_x5"], n=60000, seed=12, writes_scale=5)
    env = dict(os.environ, BLOG_DB=work, PORT=str(PORT))
    srv = subprocess.Popen(["taskset", "-c", "0", os.path.join(ROOT, "build/server")], env=env,
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    report = {"db_gb": round(os.path.getsize(a.db) / 1e9, 2), "machine": "2 vCPU (server on core 0, load on core 1), 4 GB RAM",
              "runs": []}
    try:
        # Migrations on a big database can take a while: wait for /healthz.
        t0 = time.time()
        while True:
            try:
                import socket
                c = socket.create_connection(("127.0.0.1", PORT), timeout=1)
                c.sendall(b"GET /healthz HTTP/1.1\r\nHost: localhost\r\n\r\n")
                if c.recv(64).startswith(b"HTTP/1.1 200"):
                    c.close()
                    break
                c.close()
            except OSError:
                pass
            if srv.poll() is not None or time.time() - t0 > 600:
                sys.exit("server did not start")
            time.sleep(0.5)
        report["startup_s"] = round(time.time() - t0, 1)
        print(f"server ready after {report['startup_s']} s (migrations)", flush=True)
        run(PORT, 32, 5, mixes["normal"], 1)  # warm up: page cache, SQLite cache
        plan = [("normal", int(c)) for c in a.conns.split(",")] + [("writes_x5", 32)]
        for i, (name, conns) in enumerate(plan):
            r = run(PORT, conns, a.secs, mixes[name], 100 + i)
            r["mix"] = name
            r["server_rss_mb"] = round(rss_mb(srv.pid), 1)
            wal = work + "-wal"
            r["wal_mb"] = round(os.path.getsize(wal) / 1e6, 1) if os.path.exists(wal) else 0
            report["runs"].append(r)
            print(f"{name:10} conns={conns:4}  {r['req_s']:8.0f} req/s  errors={r['errors']}  rss={r['server_rss_mb']} MB  "
                  f"wal={r['wal_mb']} MB", flush=True)
            for k, c in sorted(r["cats"].items(), key=lambda kv: -kv[1]["n"]):
                print(f"   {k:12} {c['req_s']:7.0f}/s  p50 {c['p50_ms']:7.2f}  p99 {c['p99_ms']:8.2f}  max {c['max_ms']:8.1f} ms  "
                      f"2xx {c['2xx']} 3xx {c['3xx']} 4xx {c['4xx']} 5xx {c['5xx']} fail {c['fail']}  {c['kb']:.1f} KB", flush=True)
    finally:
        srv.terminate()
        err = srv.communicate(timeout=10)[1].decode("utf-8", "replace").strip()
        if err:
            report["server_stderr"] = err[-3000:]
            print("server stderr:", err[-1500:])
    json.dump(report, open(os.path.join(ROOT, "docs/load.json"), "w"), indent=1)


main()
