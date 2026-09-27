import { notFound } from "next/navigation";
import { author, byAuthor } from "../../../lib/db";
import { Feed, Pager, pageOf } from "../../../lib/ui";
export const dynamic = "force-dynamic";

export default async function Author({ params, searchParams }) {
  const id = Number.parseInt((await params).id, 10);
  const page = pageOf(await searchParams);
  const a = Number.isSafeInteger(id) ? author(id) : undefined;
  if (!a) notFound();
  const rows = byAuthor(id, (page - 1) * 30);
  return (
    <>
      <title>{a.name + " · slopstack"}</title>
      <header className="masthead">
        <h1>{a.name}</h1>
        <p className="muted">{a.handle && <span className="handle">@{a.handle}</span>} · Posts by {a.name}</p>
      </header>
      <Feed rows={rows} empty="Nothing published yet." />
      <Pager base={`/u/${id}`} page={page} rows={rows} />
    </>
  );
}
