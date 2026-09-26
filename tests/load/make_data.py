#!/usr/bin/env python3
"""Builds a large synthetic database for load tests.

The server creates the schema (migrations included) on an empty file; this
script then bulk-inserts users, sessions, blogs, posts (bodies of realistic
size, a few of novel length), tags, comments and likes, with popularity
skewed like real traffic (a few blogs and posts get most of it).

Session tokens are derived from user ids (load-<id>), so tests/load/
make_mix.py can sign requests as any of the first SESSIONS users.

usage: make_data.py DB [--posts N] [--seed S]
"""
import argparse, hashlib, os, random, sqlite3, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
USERS, BLOGS, SESSIONS, TAGS, NOVELS = 10_000, 2_000, 3_000, 200, 20
WORDS = ("the river of long evenings carries small boats past old walls where people talk about books music weather "
         "bread and the slow craft of writing well a quiet mind notices light on water in the morning before work "
         "begins every letter holds a promise that someone will read it one day under a lamp far from here").split()


def token(uid):
    raw = hashlib.sha256(f"load-{uid}".encode()).digest()
    return raw.hex(), hashlib.sha256(raw).digest()


def zipf_pick(rng, n):
    """A skewed index in [0, n): P(index < x*n) = x^(1/3), so the top 1% of
    items get ~21% of picks and the top 10% ~46% (popular posts, blogs)."""
    return min(n - 1, int(n * rng.random() ** 3))


def sentence(rng, n):
    return " ".join(rng.choice(WORDS) for _ in range(n)).capitalize() + "."


def body(rng, words):
    md, html, have = [], [], 0
    while have < words:
        if rng.random() < 0.12:
            h = sentence(rng, rng.randint(3, 7))[:-1]
            md.append("## " + h)
            html.append(f"<h2>{h}</h2>")
            have += 5
        else:
            p = " ".join(sentence(rng, rng.randint(8, 24)) for _ in range(rng.randint(2, 6)))
            md.append(p)
            html.append(f"<p>{p}</p>")
            have += len(p.split())
    return "\n\n".join(md), "".join(html)


EXCERPT = ("substr(trim(replace(replace(replace(replace(replace(replace(substr(?, 1, 1200), char(13), ''), char(10), ' '), "
           "'#', ''), '*', ''), '>', ''), '`', '')), 1, 240)")


def insert_posts(db, batch):
    """Rows as (id, blog, slug, title, md, html, published, created, updated,
    author, published_ms): the post row (with its excerpt and length) and
    its body (which the search index is fed from, by trigger)."""
    db.executemany("INSERT INTO post(id, blog_id, slug, title, body_md, body_html, published, created_ms, updated_ms, author_id, "
                   f"published_ms, excerpt, body_len) VALUES (?, ?, ?, ?, '', '', ?, ?, ?, ?, ?, {EXCERPT}, length(?))",
                   [(r[0], r[1], r[2], r[3], r[6], r[7], r[8], r[9], r[10], r[4], r[4]) for r in batch])
    db.executemany("INSERT INTO post_body(post_id, body_md, body_html) VALUES (?, ?, ?)", [(r[0], r[4], r[5]) for r in batch])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("db")
    ap.add_argument("--posts", type=int, default=100_000)
    ap.add_argument("--seed", type=int, default=7)
    a = ap.parse_args()
    rng = random.Random(a.seed)
    if os.path.exists(a.db):
        sys.exit(f"{a.db} exists")
    # The server creates the schema and runs every migration.
    srv = subprocess.Popen([os.path.join(ROOT, "build/server")], env=dict(os.environ, BLOG_DB=a.db, PORT="8199"),
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1.0)
    srv.terminate()
    srv.wait()
    db = sqlite3.connect(a.db)
    db.execute("PRAGMA journal_mode = WAL")
    db.execute("PRAGMA synchronous = OFF")
    db.execute("PRAGMA foreign_keys = ON")
    now = int(time.time() * 1000)
    t = time.time()
    db.executemany("INSERT INTO user(id, email, name, created_ms) VALUES (?, ?, ?, ?)",
                   ((u, f"user{u}@example.com", f"Writer {u}", now - 400 * 86400_000) for u in range(1, USERS + 1)))
    db.executemany("INSERT INTO session VALUES (?, ?, ?, ?)",
                   ((token(u)[1], u, now, now + 30 * 86400_000) for u in range(1, SESSIONS + 1)))
    # Blog b is owned by user b (the first SESSIONS own blogs and can edit).
    db.executemany("INSERT INTO blog(id, slug, title, owner_id, created_ms) VALUES (?, ?, ?, ?, ?)",
                   ((b, f"blog-{b}", f"{sentence(rng, 3)[:-1]} {b}", b, now) for b in range(1, BLOGS + 1)))
    db.executemany("INSERT INTO member VALUES (?, ?, 1)", ((b, b) for b in range(1, BLOGS + 1)))
    db.commit()
    print(f"users, blogs: {time.time() - t:.1f}s", flush=True)
    t = time.time()
    batch, pid = [], 0
    for i in range(a.posts):
        pid += 1
        b = zipf_pick(rng, BLOGS) + 1
        words = int(rng.lognormvariate(6.6, 0.7))  # median ~740 words, long tail
        md, html = body(rng, min(words, 12_000))
        pub_ms = now - int(rng.random() * 730 * 86400_000)
        published = 1 if rng.random() < 0.95 else 0
        batch.append((pid, b, f"post-{pid}", sentence(rng, rng.randint(3, 9))[:-1], md, html, published, pub_ms, pub_ms, b,
                      pub_ms if published else None))
        if len(batch) == 2000:
            insert_posts(db, batch)
            db.commit()
            batch = []
            if pid % 20000 == 0:
                print(f"  posts {pid}: {time.time() - t:.0f}s", flush=True)
    for k in range(NOVELS):
        pid += 1
        md, html = body(rng, 170_000)
        md, html = md[:1_000_000], html[:1_000_000]
        batch.append((pid, k + 1, f"novel-{k + 1}", f"A long novel, part {k + 1}", md, html, 1, now - k * 86400_000,
                      now - k * 86400_000, k + 1, now - k * 86400_000))
    insert_posts(db, batch)
    db.commit()
    print(f"posts: {time.time() - t:.1f}s", flush=True)
    t = time.time()
    tags = [f"topic-{i}" for i in range(TAGS)]
    db.executemany("INSERT OR IGNORE INTO post_tag(post_id, tag) VALUES (?, ?)",
                   ((p, tags[zipf_pick(rng, TAGS)]) for p in range(1, pid + 1) for _ in range(rng.choice((0, 0, 1, 2, 3)))))
    likes = set()
    while len(likes) < 1_000_000:
        likes.add((zipf_pick(rng, pid) + 1, rng.randint(1, USERS)))
    db.executemany("INSERT OR IGNORE INTO post_like VALUES (?, ?, ?)", ((p, u, now) for p, u in likes))
    rows, cid = [], 0
    for _ in range(300_000):
        cid += 1
        p = zipf_pick(rng, pid) + 1
        rows.append((cid, p, None, rng.randint(1, USERS), sentence(rng, rng.randint(5, 40)), now - rng.randint(0, 10**9)))
    # About a third reply to one of the post's 20 latest comments.
    seen, final = {}, []
    for r in rows:
        earlier = seen.setdefault(r[1], [])
        parent = rng.choice(earlier) if earlier and rng.random() < 0.35 else None
        final.append((r[0], r[1], parent, r[3], r[4], f"<p>{r[4]}</p>", r[5]))
        earlier.append(r[0])
        if len(earlier) > 20:
            earlier.pop(0)
    db.executemany("INSERT INTO comment(id, post_id, parent_id, author_id, body_md, body_html, created_ms) VALUES (?, ?, ?, ?, ?, ?, ?)",
                   final)
    db.commit()
    print(f"tags, likes, comments: {time.time() - t:.1f}s", flush=True)
    db.execute("PRAGMA optimize")
    db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    db.close()
    print(f"size: {os.path.getsize(a.db) / 1e9:.2f} GB")


main()
