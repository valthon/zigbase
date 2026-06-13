import { useEffect, useState } from 'react';
import { listPosts, subscribePosts, type Post } from '../lib/api';

export default function PostList() {
  const [posts, setPosts] = useState<Post[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    // Initial fetch
    listPosts().then(setPosts).catch((e) => setError(e.message));

    // Realtime updates: subscribe to published post events
    const unsub = subscribePosts((ev) => {
      setPosts((prev) => {
        if (!prev) return prev;
        if (ev.action === 'create') {
          // Prepend new post (sorted by newest first)
          return [ev.record, ...prev];
        }
        if (ev.action === 'update') {
          return prev.map((p) => (p.id === ev.record.id ? ev.record : p));
        }
        if (ev.action === 'delete') {
          return prev.filter((p) => p.id !== ev.record.id);
        }
        return prev;
      });
    });

    return unsub;
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
          <p className="muted">
            {new Date(p.created).toLocaleDateString()}
            {p.reading_time != null && <> &middot; {p.reading_time} min read</>}
          </p>
          <p>{p.body.slice(0, 200)}{p.body.length > 200 ? '…' : ''}</p>
        </article>
      ))}
    </>
  );
}
