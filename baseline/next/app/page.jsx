import { q } from "../lib/db";
export const dynamic = "force-dynamic";
export const metadata = { title: "bent" };

export default function Home() {
  const rows = q(`SELECT b.slug AS b, p.slug AS p, p.title AS t, b.title AS bt FROM post p JOIN blog b ON b.id = p.blog_id
                  WHERE p.published = 1 ORDER BY p.updated_ms DESC LIMIT 30`);
  return (
    <>
      <h1>Recent posts</h1>
      <ul className="posts">
        {rows.map((r) => (
          <li key={r.b + "/" + r.p}><a href={`/b/${r.b}/${r.p}`}>{r.t}</a> <small>in {r.bt}</small></li>
        ))}
      </ul>
    </>
  );
}
