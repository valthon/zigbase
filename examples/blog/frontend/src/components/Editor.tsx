import { useState } from 'react';
import { login, signup, createPost, token, logout } from '../lib/api';

export default function Editor() {
  const [authed, setAuthed] = useState(() => typeof localStorage !== 'undefined' && token() !== null);
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [title, setTitle] = useState('');
  const [body, setBody] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);

  async function run(fn: () => Promise<void>) {
    setBusy(true); setError(null);
    try { await fn(); } catch (e: any) { setError(e.message); } finally { setBusy(false); }
  }

  if (!authed) {
    return (
      <div className="card">
        <h2>Sign in to write</h2>
        <input placeholder="email" value={email} onChange={(e) => setEmail(e.target.value)} />
        <input placeholder="password (8+ chars)" type="password" value={password} onChange={(e) => setPassword(e.target.value)} />
        <button disabled={busy} onClick={() => run(async () => { await login(email, password); setAuthed(true); })}>Log in</button>{' '}
        <button disabled={busy} onClick={() => run(async () => { await signup(email, password); setAuthed(true); })}>Sign up</button>
        {error && <p className="error">{error}</p>}
      </div>
    );
  }

  return (
    <div className="card">
      <h2>New post <button className="muted" onClick={() => { logout(); setAuthed(false); }}>log out</button></h2>
      <input placeholder="Title" value={title} onChange={(e) => setTitle(e.target.value)} />
      <textarea placeholder="Write your post…" rows={10} value={body} onChange={(e) => setBody(e.target.value)} />
      <button
        disabled={busy || !title}
        onClick={() => run(async () => {
          const post = await createPost(title, body);
          setDone(post.slug); setTitle(''); setBody('');
        })}
      >
        Publish
      </button>
      {done && <p>Published! <a href={`/post?slug=${encodeURIComponent(done)}`}>View it</a> (slug was derived by the server-side hook).</p>}
      {error && <p className="error">{error}</p>}
    </div>
  );
}
