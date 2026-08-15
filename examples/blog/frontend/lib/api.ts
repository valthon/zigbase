import { host } from '@z/runtime';

// Tiny same-origin client for the ZigBase records/auth API.
const TOKEN_KEY = 'blog_token';

export type Post = {
  id: string;
  title: string;
  slug: string;
  body: string;
  status: string;
  created: string;
  updated_at?: string;
  reading_time?: number;
  author?: string;
};

export type RealtimeEvent = {
  type: 'event';
  topic: string;
  action: 'create' | 'update' | 'delete';
  record: Post;
};

export function token(): string | null {
  if (typeof localStorage === 'undefined') return null;
  return localStorage.getItem(TOKEN_KEY);
}

export function logout(): void {
  if (typeof localStorage !== 'undefined') localStorage.removeItem(TOKEN_KEY);
}

/**
 * Read the zb_csrf cookie value (JS-readable: http_only=false).
 * Returns empty string when not present (no cookie session active).
 */
function csrfToken(): string {
  return host.cookies.get('zb_csrf');
}

async function req(path: string, init: RequestInit = {}): Promise<any> {
  const headers: Record<string, string> = {};
  const t = token();
  const csrf = csrfToken();
  if (t) headers['Authorization'] = `Bearer ${t}`;
  // Include cookie credentials and CSRF token when a cookie session is active.
  // CSRF is required for unsafe methods (POST/PATCH/DELETE) with cookie auth.
  if (!t && csrf) headers['x-csrf-token'] = csrf;
  if (init.body) headers['Content-Type'] = 'application/json';
  const credentials: RequestCredentials = (!t && csrf) ? 'include' : 'same-origin';
  const r = await fetch(path, { ...init, headers: { ...init.headers, ...headers }, credentials });
  if (!r.ok) {
    const err = await r.json().catch(() => null);
    throw new Error(err?.message ?? `HTTP ${r.status}`);
  }
  return r.json();
}

export async function login(email: string, password: string): Promise<void> {
  const out = await req('/api/collections/users/auth-with-password', {
    method: 'POST',
    body: JSON.stringify({ identity: email, password }),
  });
  if (typeof localStorage !== 'undefined') localStorage.setItem(TOKEN_KEY, out.token);
}

export async function signup(email: string, password: string): Promise<void> {
  await req('/api/collections/users/records', {
    method: 'POST',
    body: JSON.stringify({ email, password, passwordConfirm: password }),
  });
  await login(email, password);
}

export async function listPosts(): Promise<Post[]> {
  const out = await req('/api/collections/posts/records?sort=-created');
  return out.items;
}

export async function getPost(slug: string): Promise<Post | null> {
  const filter = encodeURIComponent(`slug = "${slug}"`);
  const out = await req(`/api/collections/posts/records?filter=${filter}`);
  return out.items[0] ?? null;
}

export async function createPost(title: string, body: string): Promise<Post> {
  return req('/api/collections/posts/records', {
    method: 'POST',
    body: JSON.stringify({ title, body, status: 'published' }),
  });
}

/**
 * Subscribe to realtime post events via WebSocket.
 * Returns an unsubscribe function; call it to close the socket.
 *
 * Usage:
 *   const unsub = subscribePosts((ev) => { ... });
 *   // later:
 *   unsub();
 */
export function subscribePosts(onEvent: (ev: RealtimeEvent) => void): () => void {
  if (typeof WebSocket === 'undefined') return () => {};
  // Pick ws/wss to match the page protocol so realtime works behind HTTPS.
  const proto = location.protocol === 'https:' ? 'wss' : 'ws';
  const ws = new WebSocket(`${proto}://${location.host}/api/realtime`);
  ws.addEventListener('open', () => {
    ws.send(JSON.stringify({ action: 'subscribe', topic: 'posts', filter: "status = 'published'" }));
  });
  ws.addEventListener('message', (msg) => {
    try {
      const data = JSON.parse(msg.data);
      if (data.type === 'event' && data.topic === 'posts') {
        onEvent(data as RealtimeEvent);
      }
    } catch {
      // ignore malformed messages
    }
  });
  return () => ws.close();
}

/**
 * Initiate a magic-link login. Always resolves (server returns 204 — enumeration-safe).
 * The server emails (or logs in dev) a link to the consume endpoint.
 * Set ZIGBASE_PUBLIC_URL on the server so the link is a full clickable URL.
 */
export async function initiateLogin(email: string): Promise<void> {
  await fetch('/api/collections/users/auth/magic_link/initiate', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ identity: email }),
  });
  // 204 — no body, always resolves regardless of whether the email exists (enumeration-safe).
}

/**
 * Return the current user record if a session cookie is active (set by the
 * magic-link consume redirect), or null if unauthenticated.
 * Uses auth-refresh (POST, cookie-based) — the framework's session-detection endpoint.
 * Requires zb_csrf cookie to be present (set alongside zb_auth by the consume redirect).
 */
export type Me = { id: string; email: string; name?: string };
export async function getMe(): Promise<Me | null> {
  try {
    const csrf = csrfToken();
    if (!csrf) return null; // no cookie session — skip the round-trip
    const r = await fetch('/api/collections/users/auth-refresh', {
      method: 'POST',
      credentials: 'include',
      headers: { 'x-csrf-token': csrf },
    });
    if (!r.ok) return null;
    const out = await r.json();
    return (out?.record as Me) ?? null;
  } catch {
    return null;
  }
}

/**
 * Server-side logout: clears the zb_auth and zb_csrf session cookies.
 * Call this in addition to clearing localStorage when the user logs out.
 */
export async function logoutCookie(): Promise<void> {
  const csrf = csrfToken();
  if (!csrf) return; // no cookie session
  await fetch('/api/collections/users/auth-logout', {
    method: 'POST',
    credentials: 'include',
    headers: { 'x-csrf-token': csrf },
  }).catch(() => {}); // best-effort: fire-and-forget; local state is cleared regardless
}
