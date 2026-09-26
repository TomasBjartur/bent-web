import { notFound } from "next/navigation";
import { q } from "../../../../lib/db";
export const dynamic = "force-dynamic";

export default async function Post({ params }) {
  const { blog, post } = await params;
  const [p] = q(`SELECT p.title, p.body_html, b.slug AS bs, b.title AS bt FROM post p JOIN blog b ON b.id = p.blog_id
                 WHERE b.slug = ? AND p.slug = ? AND p.published = 1`, blog, post);
  if (!p) notFound();
  return (
    <article>
      <p className="crumb"><a href={`/b/${p.bs}`}>{p.bt}</a></p>
      <h1>{p.title}</h1>
      <div className="body" dangerouslySetInnerHTML={{ __html: p.body_html }} />
    </article>
  );
}
