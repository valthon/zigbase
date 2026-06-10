import { useEffect, useState } from 'react';
import { listAuthors, listPosts, type Author, type Post } from '../lib/api';

export default function Browser() {
  const [authors, setAuthors] = useState<Author[] | null>(null);
  const [posts, setPosts] = useState<Post[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    Promise.all([listAuthors(), listPosts()])
      .then(([a, p]) => { setAuthors(a); setPosts(p); })
      .catch((e) => setError(e.message));
  }, []);

  if (error) return <p className="error">{error}</p>;
  if (!authors || !posts) return <p className="muted">Loading&hellip;</p>;
  return (
    <>
      <section className="card">
        <h2>Authors ({authors.length})</h2>
        {authors.length === 0
          ? <p className="muted">None yet &mdash; add some via the <a href="/_/" data-astro-reload>admin UI</a>.</p>
          : <ul>{authors.map((a) => <li key={a.id}>{a.name}</li>)}</ul>}
      </section>
      <section className="card">
        <h2>Published posts ({posts.length})</h2>
        {posts.length === 0
          ? <p className="muted">None yet &mdash; only posts with status &ldquo;published&rdquo; appear here (the comptime list rule).</p>
          : <ul>{posts.map((p) => <li key={p.id}>{p.title} <span className="muted">by {p.expand?.author?.name ?? '?'}</span></li>)}</ul>}
      </section>
    </>
  );
}
