import { recent } from "../lib/db";
import { Feed, Pager, pageOf } from "../lib/ui";
export const dynamic = "force-dynamic";
export const metadata = { title: "Home · slopstack" };

export default async function Home({ searchParams }) {
  const page = pageOf(await searchParams);
  const rows = recent((page - 1) * 30);
  return (
    <>
      <section className="masthead">
        <h1>A quiet place to write</h1>
        <p className="lede">Fast pages, no trackers, no passwords: you sign in with a passkey. Write alone or with co-authors, even offline.</p>
        <a className="btn primary big" href="/signup">Start writing</a>
      </section>
      <div className="feed-head"><h2>Recent posts</h2><a href="/search">Search</a></div>
      <Feed rows={rows} empty="Nothing published yet. Be the first!" />
      <Pager base="/" page={page} rows={rows} />
    </>
  );
}
