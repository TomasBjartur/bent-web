import { byTag } from "../../../lib/db";
import { Feed, Pager, pageOf } from "../../../lib/ui";
export const dynamic = "force-dynamic";

export default async function Tag({ params, searchParams }) {
  const { tag } = await params;
  const page = pageOf(await searchParams);
  const rows = byTag(tag, (page - 1) * 30);
  return (
    <>
      <title>{"#" + tag + " · slopstack"}</title>
      <header className="masthead"><h1>#{tag}</h1><p className="muted">Posts tagged {tag}</p></header>
      <Feed rows={rows} empty="No posts with this tag yet." />
      <Pager base={`/t/${tag}`} page={page} rows={rows} />
    </>
  );
}
