import { useEffect, useState } from 'react';
import { listPosts, type Post } from '../lib/api';

export default function PostList() {
  const [posts, setPosts] = useState<Post[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    listPosts().then(setPosts).catch((e) => setError(e.message));
  }, []);

  if (error) return <p className="error">Failed to load posts: {error}</p>;
  if (!posts) return <p className="muted">Loading…</p>;
  if (posts.length === 0)
    return <p className="muted">No posts yet — <a href="/write">write the first one</a>.</p>;
  return (
    <>
      {posts.map((p) => (
        <article className="card" key={p.id}>
          <h2><a href={`/post?slug=${encodeURIComponent(p.slug)}`}>{p.title}</a></h2>
          <p className="muted">{new Date(p.created).toLocaleDateString()}</p>
          <p>{p.body.slice(0, 200)}{p.body.length > 200 ? '…' : ''}</p>
        </article>
      ))}
    </>
  );
}
