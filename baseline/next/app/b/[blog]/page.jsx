import { notFound } from "next/navigation";
import { blogBySlug, blogPosts } from "../../../lib/db";
import { Feed, Pager, pageOf } from "../../../lib/ui";
export const dynamic = "force-dynamic";

export default async function Blog({ params, searchParams }) {
  const { blog } = await params;
  const page = pageOf(await searchParams);
  const b = blogBySlug(blog);
  if (!b) notFound();
  const rows = blogPosts(b.id, (page - 1) * 30);
  return (
    <>
      <title>{b.title + " · slopstack"}</title>
      <header className="masthead">
        <h1>{b.title}</h1>
        <p className="muted">by {b.owner}<span className="dot"></span><a href={`/b/${b.slug}/feed.xml`}>RSS</a></p>
      </header>
      <Feed rows={rows} empty="No posts yet." pub={false} />
      <Pager base={`/b/${b.slug}`} page={page} rows={rows} />
    </>
  );
}
