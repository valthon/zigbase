// Tiny same-origin client for the ZigBase records/auth API.
const TOKEN_KEY = 'blog_token';

export type Post = {
  id: string;
  title: string;
  slug: string;
  body: string;
  status: string;
  created: string;
};

export function token(): string | null {
  if (typeof localStorage === 'undefined') return null;
  return localStorage.getItem(TOKEN_KEY);
}

export function logout(): void {
  if (typeof localStorage !== 'undefined') localStorage.removeItem(TOKEN_KEY);
}

async function req(path: string, init: RequestInit = {}): Promise<any> {
  const headers: Record<string, string> = {};
  const t = token();
  if (t) headers['Authorization'] = `Bearer ${t}`;
  if (init.body) headers['Content-Type'] = 'application/json';
  const r = await fetch(path, { ...init, headers });
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
