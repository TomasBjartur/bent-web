// Shared pieces of the public pages, matching the Bend server's markup
// (src/pages.bend) so the same stylesheet applies and the pages weigh
// about the same.
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
export const date = (d) => `${MONTHS[Number(d.slice(5, 7)) - 1]} ${Number(d.slice(8, 10))}, ${d.slice(0, 4)}`;
export const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;

export function Meta({ r }) {
  return (
    <div className="meta">
      <a href={`/u/${r.aid}`}>{r.author}</a>
      <span className="dot"></span>
      {date(r.date)}
      <span className="dot"></span>
      {r.minutes} min read
    </div>
  );
}

export function Feed({ rows, empty, pub = true }) {
  if (rows.length === 0) return <div className="empty"><p>{empty}</p></div>;
  return (
    <ul className="feed" id="feed">
      {rows.slice(0, 30).map((r) => (
        <li key={r.bs + "/" + r.ps}>
          {pub && <a className="pub" href={`/b/${r.bs}`}>{r.bt}</a>}
          <h3><a href={`/b/${r.bs}/${r.ps}`}>{r.title}</a></h3>
          <p className="excerpt">{r.excerpt}</p>
          <Meta r={r} />
        </li>
      ))}
    </ul>
  );
}

export function Pager({ base, page, rows }) {
  const sep = base.includes("?") ? "&" : "?";
  return (
    <nav className="pager" id="pager">
      {page > 1 ? <a href={`${base}${sep}page=${page - 1}`}>← Newer</a> : <span></span>}
      {rows.length > 30 && <a href={`${base}${sep}page=${page + 1}`}>Older posts →</a>}
    </nav>
  );
}

export const pageOf = (sp) => Math.max(1, Number.parseInt(sp?.page ?? "1", 10) || 1);
