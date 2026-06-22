import { useEffect, useState } from 'react';
import {
  listAuthors, listPosts, listComments, getMe, initiateLogin, createComment,
  type Author, type Post, type Comment, type Commenter,
} from '../lib/api';

export default function Browser() {
  const [authors, setAuthors] = useState<Author[] | null>(null);
  const [posts, setPosts] = useState<Post[] | null>(null);
  const [comments, setComments] = useState<Comment[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  // Login state for the commenters magic-link flow.
  const [me, setMe] = useState<Commenter | null | 'loading'>('loading');
  const [loginEmail, setLoginEmail] = useState('');
  const [loginState, setLoginState] = useState<'idle' | 'sent' | 'error'>('idle');

  // Comment submission state.
  const [commentBody, setCommentBody] = useState('');
  const [commentPost, setCommentPost] = useState('');
  const [submitState, setSubmitState] = useState<'idle' | 'ok' | 'error'>('idle');
  const [submitError, setSubmitError] = useState<string | null>(null);

  useEffect(() => {
    Promise.all([listAuthors(), listPosts(), listComments()])
      .then(([a, p, c]) => { setAuthors(a); setPosts(p); setComments(c); })
      .catch((e) => setError(e.message));

    // Check if a commenter session is active (cookie-based).
    getMe().then(setMe).catch(() => setMe(null));
  }, []);

  if (error) return <p className="error">{error}</p>;
  if (!authors || !posts || !comments) return <p className="muted">Loading&hellip;</p>;
  return (
    <>
      <section className="card">
        <h2>Authors ({authors.length})</h2>
        {/* authors is now an auth collection (webauthn + api_token).

            WebAuthn (passkey) login for authors:
              POST /api/collections/authors/auth/webauthn/register/begin   -- start registration
              POST /api/collections/authors/auth/webauthn/register/finish  -- complete registration
              POST /api/collections/authors/auth/webauthn/authenticate/begin   -- start login
              POST /api/collections/authors/auth/webauthn/authenticate/finish  -- complete login
            See examples/plugins/README.md for the passkey ceremony outline.
            Building a full WebAuthn UI requires navigator.credentials.create/get and
            CBOR encoding -- see the README for links. */}
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
        <h2>Approved comments ({comments.length})</h2>
        {comments.length === 0
          ? <p className="muted">None yet &mdash; only comments with <code>approved=true</code> appear here.</p>
          : <ul>{comments.map((c) => (
              <li key={c.id}>
                <span className="muted">
                  {c.expand?.commenter?.display_name ?? 'anonymous'}:{' '}
                </span>
                {c.body}
              </li>
            ))}</ul>}

        <h3>Add a comment</h3>
        {me === 'loading' ? (
          <p className="muted">Checking login&hellip;</p>
        ) : me === null ? (
          /* Not logged in: show magic-link email form */
          loginState === 'sent' ? (
            <p className="muted">
              Check your email for a login link.{' '}
              <span className="muted">(In local dev, look in the server log for the magic-link token.)</span>
            </p>
          ) : (
            <form onSubmit={async (e) => {
              e.preventDefault();
              try { await initiateLogin(loginEmail); setLoginState('sent'); }
              catch { setLoginState('error'); }
            }}>
              <input
                type="email"
                placeholder="your@email.com"
                value={loginEmail}
                onChange={(e) => setLoginEmail(e.target.value)}
                required
              />
              <button type="submit">Send login link</button>
              {loginState === 'error' && <p className="error">Login failed. Try again.</p>}
            </form>
          )
        ) : (
          /* Logged in: show comment compose form */
          submitState === 'ok' ? (
            <p className="muted">Comment submitted &mdash; pending approval.</p>
          ) : (
            <form onSubmit={async (e) => {
              e.preventDefault();
              try {
                await createComment(commentPost, commentBody);
                setSubmitState('ok');
                setCommentBody('');
              } catch (err: any) {
                setSubmitState('error');
                setSubmitError(err.message);
              }
            }}>
              <select value={commentPost} onChange={(e) => setCommentPost(e.target.value)} required>
                <option value="">Select a post&hellip;</option>
                {(posts ?? []).map((p) => <option key={p.id} value={p.id}>{p.title}</option>)}
              </select>
              <textarea
                placeholder="Your comment&hellip;"
                value={commentBody}
                onChange={(e) => setCommentBody(e.target.value)}
                required
              />
              <button type="submit">Submit</button>
              {submitState === 'error' && <p className="error">{submitError}</p>}
            </form>
          )
        )}
      </section>
    </>
  );
}
