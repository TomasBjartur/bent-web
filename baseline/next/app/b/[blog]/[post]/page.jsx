import { notFound } from "next/navigation";
import { comments, lastComment, postView, tags } from "../../../../lib/db";
import { date, plural } from "../../../../lib/ui";
export const dynamic = "force-dynamic";

// Rows in thread order -> a tree of the first 20 threads.
function threads(rows) {
  const top = [], byId = new Map();
  let more = false;
  for (const r of rows) {
    const c = { ...r, kids: [] };
    if (r.depth === 0) {
      if (top.length === 20) { more = true; break; }
      top.push(c);
    } else {
      const p = byId.get(r.parent);
      if (!p) continue;
      p.kids.push(c);
    }
    byId.set(r.id, c);
  }
  return { top, more };
}

function Comment({ c, collapse }) {
  return (
    <div className="comment" id={`c${c.id}`} data-parent={c.parent}>
      <div className="meta">
        <a href={`/u/${c.aid}`}>{c.name}</a>{" "}{c.handle && <span className="handle">@{c.handle}</span>}
        <span className="dot"></span><a href={`#c${c.id}`}>{date(c.date)}</a>
      </div>
      {c.deleted ? <div className="cbody" id={`cb${c.id}`}><p className="muted">[deleted]</p></div>
                 : <div className="cbody" id={`cb${c.id}`} dangerouslySetInnerHTML={{ __html: c.body }} />}
      <div className="cactions" id={`ca${c.id}`}></div>
      <div className="rf" id={`rf${c.id}`}></div>
      <details className="replies" id={`r${c.id}`} open={!(collapse && c.depth === 0 && c.replies > 0)}>
        {collapse && c.depth === 0 && c.replies > 0 && <summary>{plural(c.replies, "reply", "replies")}</summary>}
        {c.kids.map((k) => <Comment key={k.id} c={k} collapse={collapse} />)}
      </details>
    </div>
  );
}

export default async function Post({ params }) {
  const { blog, post } = await params;
  const p = postView(blog, post);
  if (!p) notFound();
  const t = tags(p.id);
  const last = lastComment(p.id);
  const { top, more } = threads(comments(p.id));
  const lastTop = top.length ? top[top.length - 1].id : 0;
  return (
    <>
      <title>{p.title + " · slopstack"}</title>
      <article className="article">
        <header>
          <a className="pub" href={`/b/${p.bs}`}>{p.bt}</a>
          <h1>{p.title}</h1>
          <div className="byline">
            <strong><a href={`/u/${p.aid}`}>{p.author}</a></strong>{" "}{p.handle && <span className="handle">@{p.handle}</span>}
            <span className="dot"></span>{date(p.date)}<span className="dot"></span>{p.minutes} min read
          </div>
        </header>
        <div className="body" dangerouslySetInnerHTML={{ __html: p.body }} />
        {t.length > 0 && <div className="tags">{t.map((x) => <a key={x.tag} className="tag" href={`/t/${x.tag}`}>#{x.tag}</a>)}</div>}
        <div className="social" id="social">
          <a className="btn like" href="/login" title="Log in to like">♥ {p.likes}</a>
          <a className="btn quiet" href="#comments">{plural(p.comments, "comment", "comments")}</a>
        </div>
        <footer><a href={`/b/${p.bs}`}>← More from {p.bt}</a><a href="/">Recent posts</a></footer>
      </article>
      <section className="comments" id="comments">
        <h2>Comments</h2>
        <p className="muted"><a href="/login">Log in</a> or <a href="/signup">sign up</a> to comment.</p>
        <div id="thread">
          {top.map((c) => <Comment key={c.id} c={c} collapse={p.comments > 20} />)}
          {more && <div id="more-comments" className="more-comments">
            <a className="btn" href={`/comments/${p.id}?after=${lastTop}&upto=${last}`}>More comments</a></div>}
        </div>
      </section>
    </>
  );
}
