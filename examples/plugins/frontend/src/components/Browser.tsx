import { useEffect, useState } from 'react';
import { listAuthors, listPosts, listComments, type Author, type Post, type Comment } from '../lib/api';

export default function Browser() {
  const [authors, setAuthors] = useState<Author[] | null>(null);
  const [posts, setPosts] = useState<Post[] | null>(null);
  const [comments, setComments] = useState<Comment[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    Promise.all([listAuthors(), listPosts(), listComments()])
      .then(([a, p, c]) => { setAuthors(a); setPosts(p); setComments(c); })
      .catch((e) => setError(e.message));
  }, []);

  if (error) return <p className="error">{error}</p>;
  if (!authors || !posts || !comments) return <p className="muted">Loading&hellip;</p>;
  return (
    <>
      <section className="card">
        <h2>Authors ({authors.length})</h2>
        {authors.length === 0
          ? <p className="muted">None yet &mdash; add some via the <a href="/_/" data-astro-reload>admin UI</a>.</p>
          : <ul>{authors.map((a) => <li key={a.id}>{a.name}{a.bio ? <span className="muted"> &mdash; {a.bio}</span> : null}</li>)}</ul>}
      </section>
      <section className="card">
        <h2>Published posts ({posts.length})</h2>
        {posts.length === 0
          ? <p className="muted">None yet &mdash; only posts with status &ldquo;published&rdquo; appear here (the comptime list rule).</p>
          : <ul>{posts.map((p) => <li key={p.id}>{p.title} <span className="muted">by {p.expand?.author?.name ?? '?'}</span></li>)}</ul>}
      </section>
      <section className="card">
        {/* Comments: relation to posts + author_name text + approved bool.
            Only approved=true comments are visible (the comptime list rule). */}
        <h2>Approved comments ({comments.length})</h2>
        {comments.length === 0
          ? <p className="muted">None yet &mdash; only comments with <code>approved=true</code> appear here (the comptime list rule on the comments collection).</p>
          : <ul>{comments.map((c) => (
              <li key={c.id}>
                <span className="muted">{c.author_name ?? 'anonymous'}: </span>{c.body}
              </li>
            ))}</ul>}
      </section>
    </>
  );
}
