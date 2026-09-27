import { search } from "../../lib/db";
import { Feed } from "../../lib/ui";
export const dynamic = "force-dynamic";
export const metadata = { title: "Search · slopstack" };

// As src/text.bend fts_query for a submitted search: up to 8 words, each
// quoted (quotes doubled), no prefix.
const fts = (s) => s.split(/[ \t\r\n]+/).filter(Boolean).slice(0, 8).map((w) => `"${w.slice(0, 126).replaceAll('"', '""')}"`).join(" ");

export default async function Search({ searchParams }) {
  const qs = String((await searchParams)?.q ?? "").slice(0, 200);
  const f = fts(qs);
  const rows = f ? search(f) : [];
  return (
    <>
      <form method="get" action="/search" className="searchbar" role="search">
        <input name="q" type="search" maxLength={200} placeholder="Search posts" aria-label="Search posts" autoComplete="off" defaultValue={qs} />
        <button className="primary">Search</button>
      </form>
      <div id="results">{f && <Feed rows={rows} empty="Nothing found." />}</div>
    </>
  );
}
