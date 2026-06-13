import { useEffect, useState } from 'react';
import { listPosts, subscribePosts, type Post } from '../lib/api';

export default function PostList() {
  const [posts, setPosts] = useState<Post[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    // Initial fetch
    listPosts().then(setPosts).catch((e) => setError(e.message));

    // Realtime updates: subscribe to published post events. The subscription is
    // filtered to status = 'published' server-side, so any record we receive is
    // one that should appear in the list (delete events are id-only).
    const unsub = subscribePosts((ev) => {
      setPosts((prev) => {
        if (!prev) return prev;
        if (ev.action === 'delete') {
          return prev.filter((p) => p.id !== ev.record.id);
        }
        // create OR update: upsert by id. Dedupe so a create that races the
        // initial fetch (or an update for a post already shown) never produces
        // duplicate React keys; replace in place if present, else prepend.
        if (prev.some((p) => p.id === ev.record.id)) {
          return prev.map((p) => (p.id === ev.record.id ? ev.record : p));
        }
        return [ev.record, ...prev];
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
