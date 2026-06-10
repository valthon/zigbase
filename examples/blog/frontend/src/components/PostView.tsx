import { useEffect, useState } from 'react';
import { getPost, type Post } from '../lib/api';

export default function PostView() {
  const [post, setPost] = useState<Post | null | undefined>(undefined);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const slug = new URLSearchParams(location.search).get('slug') ?? '';
    getPost(slug).then(setPost).catch((e) => setError(e.message));
  }, []);

  if (error) return <p className="error">{error}</p>;
  if (post === undefined) return <p className="muted">Loading…</p>;
  if (post === null) return <p className="muted">Post not found. <a href="/">Back home</a></p>;
  return (
    <article>
      <h1>{post.title}</h1>
      <p className="muted">{new Date(post.created).toLocaleString()}</p>
      {post.body.split(/\n\n+/).map((para, i) => <p key={i}>{para}</p>)}
    </article>
  );
}
