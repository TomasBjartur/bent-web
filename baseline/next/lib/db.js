// The same SQLite database the Bend server uses (read-only here).
import { DatabaseSync } from "node:sqlite";

let db;
export function q(sql, ...args) {
  db ??= new DatabaseSync(process.env.BLOG_DB, { readOnly: true });
  return db.prepare(sql).all(...args);
}
