export type Author = { id: string; name: string; contact_email?: string; bio?: string };
export type Post = { id: string; title: string; status: string; author: string; expand?: { author?: Author } };
// Comment relation: `post` is a relation id; `approved` must be true to appear
// (enforced by the comptime list rule on the comments collection).
export type Comment = { id: string; body: string; author_name?: string; post: string };

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
  return (await req('/api/collections/comments/records?sort=-created&per_page=10')).items;
}
