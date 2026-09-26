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
  body_html   TEXT NOT NULL CHECK (length(body_html) <= 4194304),
  published   INTEGER NOT NULL CHECK (published IN (0, 1)),
  created_ms  INTEGER NOT NULL,
  updated_ms  INTEGER NOT NULL,
  UNIQUE (blog_id, slug)
) STRICT;

CREATE INDEX IF NOT EXISTS post_blog_updated ON post(blog_id, updated_ms DESC);

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
