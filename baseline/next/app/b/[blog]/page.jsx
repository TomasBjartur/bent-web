import { notFound } from "next/navigation";
import { q } from "../../../lib/db";
export const dynamic = "force-dynamic";

export default async function Blog({ params }) {
  const { blog } = await params;
  const [b] = q("SELECT id, title, slug FROM blog WHERE slug = ?", blog);
  if (!b) notFound();
  const posts = q("SELECT slug, title FROM post WHERE blog_id = ? AND published = 1 ORDER BY updated_ms DESC LIMIT 100", b.id);
  return (
    <>
      <h1>{b.title}</h1>
      <ul className="posts">
        {posts.map((p) => <li key={p.slug}><a href={`/b/${b.slug}/${p.slug}`}>{p.title}</a></li>)}
      </ul>
    </>
  );
}
