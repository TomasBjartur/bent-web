#!/usr/bin/env python3
"""Writes a traffic mix for tests/load/mixgen.c from a database made by
make_data.py: N requests drawn in the proportions below, popularity skewed
like the data (a few posts and blogs get most views).

usage: make_mix.py DB OUT [--n N] [--seed S] [--writes-scale X]
"""
import argparse, hashlib, random, sqlite3, urllib.parse

# category: weight per 10,000 requests. Reads by signed-out visitors
# dominate; signed-in traffic reads too, and writes.
MIX = {
    "home": 700, "blog": 700, "post": 4500, "novel": 30, "rss": 300, "search": 250, "tag": 200, "author": 150,
    "css": 100,
    "post_signed": 1100, "dash": 150, "editor_open": 80, "sync_pull": 150,
    "like": 250, "comment": 100, "sync_write": 50, "save": 20,
}
WRITES = {"like", "comment", "sync_write", "save"}
WORDS = "river evenings boats walls books music weather bread craft writing quiet light water morning letter lamp".split()


def cookie(uid):
    return "sid=" + hashlib.sha256(f"load-{uid}".encode()).digest().hex()


def get(path, uid=None):
    h = f"GET {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n"
    if uid:
        h += f"Cookie: {cookie(uid)}\r\n"
    return h + "\r\n"


def post(path, uid, form):
    body = urllib.parse.urlencode(form)
    return (f"POST {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nCookie: {cookie(uid)}\r\n"
            f"Sec-Fetch-Site: same-origin\r\nContent-Type: application/x-www-form-urlencoded\r\n"
            f"Content-Length: {len(body.encode())}\r\n\r\n{body}")


def esc(s):
    return s.replace("\\", "\\\\").replace("\r", "\\r").replace("\n", "\\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("db")
    ap.add_argument("out")
    ap.add_argument("--n", type=int, default=50_000)
    ap.add_argument("--seed", type=int, default=11)
    ap.add_argument("--writes-scale", type=float, default=1.0)
    a = ap.parse_args()
    rng = random.Random(a.seed)
    db = sqlite3.connect(f"file:{a.db}?mode=ro", uri=True)
    posts = db.execute("SELECT p.id, b.slug, p.slug, p.blog_id FROM post p JOIN blog b ON b.id = p.blog_id "
                       "WHERE p.published = 1 AND p.slug LIKE 'post-%' ORDER BY p.id").fetchall()
    novels = db.execute("SELECT b.slug, p.slug FROM post p JOIN blog b ON b.id = p.blog_id WHERE p.slug LIKE 'novel-%'").fetchall()
    owned = db.execute("SELECT p.id, p.blog_id, p.title, b.body_md FROM post p JOIN post_body b ON b.post_id = p.id "
                       "WHERE p.blog_id <= 3000 AND p.slug LIKE 'post-%' AND p.body_len < 20000 ORDER BY random() LIMIT 400").fetchall()
    blogs = db.execute("SELECT slug FROM blog ORDER BY id").fetchall()
    tags = [r[0] for r in db.execute("SELECT DISTINCT tag FROM post_tag")]
    skew = lambda xs: xs[min(len(xs) - 1, int(len(xs) * rng.random() ** 3))]
    weights = {k: v * (a.writes_scale if k in WRITES else 1.0) for k, v in MIX.items()}
    cats = list(weights)
    total = sum(weights.values())
    with open(a.out, "w") as f:
        for _ in range(a.n):
            r, c = rng.random() * total, cats[-1]
            for k in cats:
                r -= weights[k]
                if r < 0:
                    c = k
                    break
            uid = rng.randint(1, 3000)
            if c == "home":
                q = get("/")
            elif c == "blog":
                q = get(f"/b/{skew(blogs)[0]}")
            elif c in ("post", "post_signed"):
                p = skew(posts)
                q = get(f"/b/{p[1]}/{p[2]}", uid if c == "post_signed" else None)
            elif c == "novel":
                n = rng.choice(novels)
                q = get(f"/b/{n[0]}/{n[1]}")
            elif c == "rss":
                q = get("/feed.xml" if rng.random() < 0.3 else f"/b/{skew(blogs)[0]}/feed.xml")
            elif c == "search":
                q = get("/search?q=" + urllib.parse.quote(" ".join(rng.sample(WORDS, rng.randint(1, 2))), safe=""))
            elif c == "tag":
                q = get(f"/t/{skew(tags)}")
            elif c == "author":
                q = get(f"/u/{skew(list(range(1, 2001)))}")
            elif c == "css":
                q = get("/s/app.css")
            elif c == "dash":
                q = get("/dash", uid)
            elif c in ("editor_open", "sync_pull", "sync_write", "save"):
                p = rng.choice(owned)
                if c == "editor_open":
                    q = get(f"/edit/{p[0]}", p[1])
                elif c == "sync_pull":
                    q = post(f"/edit/{p[0]}/sync", p[1], {"since": "0", "ops": ""})
                elif c == "sync_write":
                    ctr = rng.randint(1, 10**8)
                    q = post(f"/edit/{p[0]}/sync", p[1], {"since": "0", "ops": f"{ctr}.{rng.randint(2, 10**6)}.0.0.0.1.97;"})
                else:
                    q = post(f"/edit/{p[0]}", p[1], {"title": p[2], "body": p[3], "tags": ""})
            elif c == "like":
                p = skew(posts)
                q = post(f"/like/{p[0]}", uid, {"on": rng.choice("01")})
            elif c == "comment":
                p = skew(posts)
                q = post(f"/comment/{p[0]}", uid, {"body": " ".join(rng.choice(WORDS) for _ in range(rng.randint(5, 30)))})
            f.write(c + "\t" + esc(q) + "\n")


main()
