export type Author = { id: string; name: string; contact_email?: string };
export type Post = { id: string; title: string; status: string; author: string; expand?: { author?: Author } };

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
