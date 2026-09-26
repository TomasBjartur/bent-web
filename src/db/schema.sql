-- Database schema. Constraints here are the last line of defense: they hold
-- even if every layer above is wrong.
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS user (
  id          INTEGER PRIMARY KEY,
  email       TEXT NOT NULL UNIQUE COLLATE NOCASE
              CHECK (length(email) BETWEEN 3 AND 254 AND email LIKE '%_@_%'),
  name        TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 64),
  created_ms  INTEGER NOT NULL
) STRICT;

-- A session is stored only as the SHA-256 of its token: a copy of the
-- database does not contain usable sessions.
CREATE TABLE IF NOT EXISTS session (
  token_hash  BLOB PRIMARY KEY CHECK (length(token_hash) = 32),
  user_id     INTEGER NOT NULL REFERENCES user(id) ON DELETE CASCADE,
  created_ms  INTEGER NOT NULL,
  expires_ms  INTEGER NOT NULL CHECK (expires_ms > created_ms)
) STRICT, WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS blog (
  id          INTEGER PRIMARY KEY,
  slug        TEXT NOT NULL UNIQUE
              CHECK (length(slug) BETWEEN 1 AND 64 AND slug NOT GLOB '*[^a-z0-9-]*'),
  title       TEXT NOT NULL CHECK (length(title) BETWEEN 1 AND 200),
  owner_id    INTEGER NOT NULL REFERENCES user(id),
  created_ms  INTEGER NOT NULL
) STRICT;

-- role: 1 = owner, 2 = author (spec/authz.bend: Owner, Author).
CREATE TABLE IF NOT EXISTS member (
  blog_id     INTEGER NOT NULL REFERENCES blog(id) ON DELETE CASCADE,
  user_id     INTEGER NOT NULL REFERENCES user(id) ON DELETE CASCADE,
  role        INTEGER NOT NULL CHECK (role IN (1, 2)),
  PRIMARY KEY (blog_id, user_id)
) STRICT, WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS post (
  id          INTEGER PRIMARY KEY,
  blog_id     INTEGER NOT NULL REFERENCES blog(id) ON DELETE CASCADE,
  slug        TEXT NOT NULL
              CHECK (length(slug) BETWEEN 1 AND 64 AND slug NOT GLOB '*[^a-z0-9-]*'),
  title       TEXT NOT NULL CHECK (length(title) BETWEEN 1 AND 200),
  body_md     TEXT NOT NULL CHECK (length(body_md) <= 1048576),
  body_html   TEXT NOT NULL CHECK (length(body_html) <= 8388608),
  published   INTEGER NOT NULL CHECK (published IN (0, 1)),
  created_ms  INTEGER NOT NULL,
  updated_ms  INTEGER NOT NULL,
  UNIQUE (blog_id, slug)
) STRICT;

-- A blog's published posts, newest first (blog pages). Two equality columns
-- then the sort, so the planner never prefers post_published_updated here
-- (it did, and blog pages fell from 2,100 to 240 req/s).
CREATE INDEX IF NOT EXISTS post_blog_pub_updated ON post(blog_id, published, updated_ms DESC);
-- "Recent posts" on the home page: without this SQLite scans every (wide)
-- post row on each request (found by tests/bench_vs_next.py).
CREATE INDEX IF NOT EXISTS post_published_updated ON post(published, updated_ms DESC);

-- A blog's owner membership row exists exactly as long as the blog: it can
-- be neither removed nor demoted while the blog exists (mirrors the
-- authz_no_self_remove law). Deleting the blog removes it by cascade.
CREATE TRIGGER IF NOT EXISTS member_owner_kept
BEFORE DELETE ON member
WHEN OLD.role = 1 AND EXISTS (SELECT 1 FROM blog WHERE id = OLD.blog_id)
BEGIN
  SELECT RAISE(ABORT, 'owner membership cannot be removed');
END;

CREATE TRIGGER IF NOT EXISTS member_owner_not_demoted
BEFORE UPDATE OF role ON member
WHEN OLD.role = 1 AND NEW.role <> 1
BEGIN
  SELECT RAISE(ABORT, 'owner cannot be demoted');
END;

-- At most one owner per blog, and it is the blog's owner_id.
CREATE TRIGGER IF NOT EXISTS member_single_owner
BEFORE INSERT ON member
WHEN NEW.role = 1 AND NEW.user_id <> (SELECT owner_id FROM blog WHERE id = NEW.blog_id)
BEGIN
  SELECT RAISE(ABORT, 'only the blog owner_id can hold the owner role');
END;

-- PASSKEYS AND EMAIL
-- A passkey (WebAuthn credential): its id, and its P-256 public key.
CREATE TABLE IF NOT EXISTS credential (
  id          BLOB PRIMARY KEY CHECK (length(id) BETWEEN 16 AND 1023),
  user_id     INTEGER NOT NULL REFERENCES user(id) ON DELETE CASCADE,
  x           BLOB NOT NULL CHECK (length(x) = 32),
  y           BLOB NOT NULL CHECK (length(y) = 32),
  sign_count  INTEGER NOT NULL CHECK (sign_count >= 0),
  created_ms  INTEGER NOT NULL
) STRICT, WITHOUT ROWID;

CREATE INDEX IF NOT EXISTS credential_user ON credential(user_id);

-- A single-use WebAuthn challenge, stored as the SHA-256 of its bytes.
-- purpose: 1 = register (bound to an email token), 2 = log in.
CREATE TABLE IF NOT EXISTS challenge (
  hash        BLOB PRIMARY KEY CHECK (length(hash) = 32),
  purpose     INTEGER NOT NULL CHECK (purpose IN (1, 2)),
  token_hash  BLOB CHECK (token_hash IS NULL OR length(token_hash) = 32),
  expires_ms  INTEGER NOT NULL,
  used        INTEGER NOT NULL DEFAULT 0 CHECK (used IN (0, 1)),
  CHECK ((purpose = 1) = (token_hash IS NOT NULL))
) STRICT, WITHOUT ROWID;

-- A single-use emailed link, stored as the SHA-256 of its token.
-- purpose: 1 = sign up (email and name to create), 2 = recover (user_id).
CREATE TABLE IF NOT EXISTS email_token (
  hash        BLOB PRIMARY KEY CHECK (length(hash) = 32),
  purpose     INTEGER NOT NULL CHECK (purpose IN (1, 2)),
  email       TEXT NOT NULL COLLATE NOCASE,
  name        TEXT NOT NULL,
  user_id     INTEGER REFERENCES user(id) ON DELETE CASCADE,
  created_ms  INTEGER NOT NULL,
  expires_ms  INTEGER NOT NULL,
  used        INTEGER NOT NULL DEFAULT 0 CHECK (used IN (0, 1)),
  CHECK ((purpose = 2) = (user_id IS NOT NULL))
) STRICT, WITHOUT ROWID;

CREATE INDEX IF NOT EXISTS email_token_email ON email_token(email, created_ms);

-- Mail to send. A separate sender drains it (transactional outbox): the
-- web server never talks SMTP.
CREATE TABLE IF NOT EXISTS outbox (
  id          INTEGER PRIMARY KEY,
  to_email    TEXT NOT NULL,
  subject     TEXT NOT NULL,
  body        TEXT NOT NULL,
  created_ms  INTEGER NOT NULL,
  sent_ms     INTEGER
) STRICT;

-- COLLABORATIVE EDITING
-- A post's document as a set of CRDT operations (src/crdt.bend). seq orders
-- them by arrival for incremental sync; the UNIQUE constraint makes the
-- table a set (inserting an operation twice changes nothing).
CREATE TABLE IF NOT EXISTS op (
  seq     INTEGER PRIMARY KEY AUTOINCREMENT,
  post_id INTEGER NOT NULL REFERENCES post(id) ON DELETE CASCADE,
  ctr     INTEGER NOT NULL CHECK (ctr >= 1),
  rep     INTEGER NOT NULL CHECK (rep >= 1),
  kind    INTEGER NOT NULL CHECK (kind IN (0, 1)),
  pctr    INTEGER NOT NULL CHECK (pctr >= 0),
  prep    INTEGER NOT NULL CHECK (prep >= 0),
  side    INTEGER NOT NULL CHECK (side IN (0, 1)),
  ch      INTEGER NOT NULL CHECK (ch >= 0 AND ch <= 1114111 AND NOT (ch BETWEEN 55296 AND 57343)),
  -- One operation per id: a client reusing an id with different content is
  -- ignored (first writer wins), so every replica can key nodes by id.
  UNIQUE (post_id, ctr, rep)
) STRICT;

CREATE INDEX IF NOT EXISTS op_post_seq ON op(post_id, seq);
