// The same SQLite database the Bend server uses (read-only here), and the
// same queries (src/c/db_core.c) for the public pages.
import { DatabaseSync } from "node:sqlite";

let db;
const stmts = new Map();
export function q(sql, ...args) {
  db ??= new DatabaseSync(process.env.BLOG_DB, { readOnly: true });
  let st = stmts.get(sql);
  if (!st) {
    st = db.prepare(sql);
    stmts.set(sql, st);
  }
  return st.all(...args);
}

const AUTHOR = "coalesce((SELECT name FROM user WHERE id = p.author_id), '')";
const DATE = "strftime('%Y-%m-%d', coalesce(p.published_ms, p.updated_ms) / 1000, 'unixepoch')";
const MINUTES = "max(1, (p.body_len + 999) / 1100)";
export const FEED = `b.slug AS bs, p.slug AS ps, p.title AS title, b.title AS bt, ${AUTHOR} AS author, ${DATE} AS date,
  p.excerpt AS excerpt, ${MINUTES} AS minutes, p.author_id AS aid`;

export const recent = (offset) =>
  q(`SELECT ${FEED} FROM post p JOIN blog b ON b.id = p.blog_id WHERE p.published = 1 ORDER BY p.published_ms DESC LIMIT 31 OFFSET ?`, offset);
export const blogBySlug = (slug) =>
  q("SELECT b.id, b.title, b.slug, coalesce((SELECT name FROM user WHERE id = b.owner_id), '') AS owner FROM blog b WHERE b.slug = ?", slug)[0];
export const blogPosts = (id, offset) =>
  q(`SELECT ${FEED} FROM post p JOIN blog b ON b.id = p.blog_id WHERE p.blog_id = ? AND p.published = 1 ORDER BY p.published_ms DESC LIMIT 31 OFFSET ?`, id, offset);
export const byTag = (tag, offset) =>
  q(`SELECT ${FEED} FROM post_tag t CROSS JOIN post p ON p.id = t.post_id JOIN blog b ON b.id = p.blog_id
     WHERE t.tag = ? AND t.pub_ms IS NOT NULL ORDER BY t.pub_ms DESC LIMIT 31 OFFSET ?`, tag, offset);
export const author = (id) =>
  q("SELECT u.name, coalesce(u.handle, '') AS handle FROM user u WHERE u.id = ? AND EXISTS (SELECT 1 FROM post p WHERE p.author_id = u.id AND p.published = 1)", id)[0];
export const byAuthor = (id, offset) =>
  q(`SELECT ${FEED} FROM post p JOIN blog b ON b.id = p.blog_id WHERE p.author_id = ? AND p.published = 1 ORDER BY p.published_ms DESC LIMIT 31 OFFSET ?`, id, offset);
export const search = (fts) =>
  q(`WITH m AS MATERIALIZED (SELECT rowid AS rid FROM post_fts WHERE post_fts MATCH ? ORDER BY rowid DESC LIMIT 40)
     SELECT ${FEED} FROM m CROSS JOIN post p ON p.id = m.rid JOIN blog b ON b.id = p.blog_id WHERE p.published = 1 ORDER BY m.rid DESC LIMIT 30`, fts);
export const postView = (blog, slug) =>
  q(`SELECT p.id, p.slug AS ps, p.title, b.slug AS bs, b.title AS bt, ${AUTHOR} AS author, ${DATE} AS date, ${MINUTES} AS minutes,
       p.author_id AS aid, coalesce((SELECT handle FROM user WHERE id = p.author_id), '') AS handle, pb.body_html AS body,
       p.like_count AS likes, p.comment_count AS comments
     FROM post p JOIN blog b ON b.id = p.blog_id JOIN post_body pb ON pb.post_id = p.id
     WHERE b.slug = ? AND p.slug = ? AND p.published = 1`, blog, slug)[0];
export const tags = (pid) => q("SELECT tag FROM post_tag WHERE post_id = ? ORDER BY rowid LIMIT 5", pid);
export const lastComment = (pid) => q("SELECT coalesce(max(id), 0) AS id FROM comment WHERE post_id = ?", pid)[0].id;
// A page of threads (as Q_COMMENTS), with each comment's stored HTML.
export const comments = (pid) =>
  q(`WITH RECURSIVE t(id, depth, path) AS (
       SELECT id, 0, printf('%010d', id) FROM (SELECT id FROM comment WHERE post_id = ? AND parent_id IS NULL ORDER BY id LIMIT 21)
       UNION ALL SELECT c.id, t.depth + 1, t.path || printf('%010d', c.id) FROM t CROSS JOIN comment c
       ON c.parent_id = t.id WHERE t.depth < 50 ORDER BY 3 LIMIT 300)
     SELECT c.id, t.depth, c.author_id AS aid, coalesce(u.name, '') AS name, strftime('%Y-%m-%d', c.created_ms / 1000, 'unixepoch') AS date,
       c.deleted, coalesce(c.parent_id, 0) AS parent, coalesce(u.handle, '') AS handle,
       (SELECT count(*) FROM comment r WHERE r.parent_id = c.id) AS replies, c.body_html AS body
     FROM t CROSS JOIN comment c ON c.id = t.id LEFT JOIN user u ON u.id = c.author_id ORDER BY t.path LIMIT 300`, pid);
