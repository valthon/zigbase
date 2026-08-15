import { useState, useEffect } from '@z/runtime';
import { login, signup, createPost, token, logout, logoutCookie, initiateLogin, getMe, type Me } from '../lib/api';

export interface Props {}

export default function Editor(_props: Props) {
  // authed is true when a localStorage JWT OR a cookie session is present.
  const [authed, setAuthed] = useState(() => typeof localStorage !== 'undefined' && token() !== null);
  const [me, setMe] = useState<Me | null>(null);
  // login flow state
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [linkSent, setLinkSent] = useState(false);
  // write flow state
  const [title, setTitle] = useState('');
  const [body, setBody] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);

  // On mount: check for a cookie session (set by the magic-link consume redirect).
  useEffect(() => {
    if (authed) return; // already authed via localStorage token — no need to call getMe
    getMe().then((m) => {
      if (m) { setMe(m); setAuthed(true); }
    });
  }, [authed]);

  async function run(fn: () => Promise<void>) {
    setBusy(true); setError(null);
    try { await fn(); } catch (e: unknown) { setError(e instanceof Error ? e.message : String(e)); } finally { setBusy(false); }
  }

  if (!authed) {
    if (linkSent) {
      return (
        <div className="card">
          <h2>Check your email</h2>
          <p>
            A sign-in link has been sent to <strong>{email}</strong>.
            Click it to log in — no password needed.
          </p>
          <p className="muted">
            In local dev the link appears in the server log (look for{' '}
            <code>magic_link</code>). The link uses the host configured by{' '}
            <code>ZIGBASE_PUBLIC_URL</code>.
          </p>
          <button className="muted" onClick={() => setLinkSent(false)}>&larr; Back</button>
        </div>
      );
    }

    return (
      <div className="card">
        <h2>Sign in to write</h2>
        {/* Magic-link flow (primary) */}
        <input placeholder="email" value={email} onChange={(e) => setEmail(e.currentTarget.value)} />
        <button
          disabled={busy || !email}
          onClick={() => run(async () => {
            await initiateLogin(email);
            setLinkSent(true);
          })}
        >
          Send magic link
        </button>
        {/* Password fallback (secondary, collapsed by default) */}
        <details style={{ marginTop: '0.75rem' }}>
          <summary className="muted" style={{ cursor: 'pointer' }}>Sign in with password instead</summary>
          <div style={{ marginTop: '0.5rem' }}>
            <input placeholder="password (8+ chars)" type="password" value={password} onChange={(e) => setPassword(e.currentTarget.value)} />
            <button disabled={busy} onClick={() => run(async () => { await login(email, password); setAuthed(true); })}>Log in</button>{' '}
            <button disabled={busy} onClick={() => run(async () => { await signup(email, password); setAuthed(true); })}>Sign up</button>
          </div>
        </details>
        {error && <p className="error">{error}</p>}
      </div>
    );
  }

  return (
    <div className="card">
      <h2>New post <button className="muted" onClick={() => { logout(); logoutCookie(); setAuthed(false); setMe(null); }}>log out</button></h2>
      <input placeholder="Title" value={title} onChange={(e) => setTitle(e.currentTarget.value)} />
      <textarea placeholder="Write your post…" rows={10} value={body} onChange={(e) => setBody(e.currentTarget.value)} />
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
