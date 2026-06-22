export type Author = { id: string; name: string; contact_email?: string; bio?: string };
export type Post = { id: string; title: string; status: string; author: string; expand?: { author?: Author } };
// Comment relation: `post` is a relation id; `approved` must be true to appear
// (enforced by the comptime list rule on the comments collection).
// `commenter` is now a relation to the commenters auth collection (replaces author_name).
export type Commenter = { id: string; display_name?: string };
export type Comment = {
  id: string;
  body: string;
  post: string;
  commenter: string;
  expand?: { commenter?: Commenter };
};

async function req(path: string): Promise<any> {
  const r = await fetch(path);
  if (!r.ok) {
    const err = await r.json().catch(() => null);
    throw new Error(err?.message ?? `HTTP ${r.status}`);
  }
  return r.json();
}

export async function listAuthors(): Promise<Author[]> {
  return (await req('/api/collections/authors/records?sort=name')).items;
}

export async function listPosts(): Promise<Post[]> {
  // Only status="published" is listable (the collection's comptime list rule).
  return (await req('/api/collections/posts/records?expand=author&sort=-created')).items;
}

export async function listComments(): Promise<Comment[]> {
  // Only approved=true comments are listable (the comptime list rule).
  // expand=commenter resolves the relation so we can display display_name.
  return (await req('/api/collections/comments/records?sort=-created&per_page=10&expand=commenter')).items;
}

// ---- Auth: commenters magic-link -------------------------------------------

/** Attempt to get the currently-logged-in commenter via session cookie. */
export async function getMe(): Promise<Commenter | null> {
  // POST auth-refresh with credentials (cookie) -- returns {token, record} if session valid.
  const r = await fetch('/api/collections/commenters/auth-refresh', {
    method: 'POST',
    credentials: 'include',
  });
  if (r.status === 401 || r.status === 403 || r.status === 404) return null;
  if (!r.ok) return null;
  const data = await r.json().catch(() => null);
  return data?.record ?? null;
}

/** Initiate magic-link login: POST the email, server sends the link. */
export async function initiateLogin(email: string): Promise<void> {
  const r = await fetch('/api/collections/commenters/auth/magic_link/initiate', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ identity: email }),
  });
  if (!r.ok) {
    const err = await r.json().catch(() => null);
    throw new Error(err?.message ?? `HTTP ${r.status}`);
  }
}

/** Submit a comment. Requires an active session (cookie + CSRF token). */
export async function createComment(postId: string, body: string): Promise<void> {
  // Read the JS-readable CSRF token from the zb_csrf cookie.
  const csrf = document.cookie
    .split('; ')
    .find((c) => c.startsWith('zb_csrf='))
    ?.split('=')[1] ?? '';
  const r = await fetch('/api/collections/comments/records', {
    method: 'POST',
    credentials: 'include',
    headers: {
      'Content-Type': 'application/json',
      'x-csrf-token': csrf,
    },
    // commenter field is auto-populated by the beforeCreateComment hook from the session.
    body: JSON.stringify({ post: postId, body }),
  });
  if (!r.ok) {
    const err = await r.json().catch(() => null);
    throw new Error(err?.message ?? `HTTP ${r.status}`);
  }
}
