import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { createClient } from "@zigbase/client";
import { startBlog, type BlogServer } from "./harness.js";

// Tier 1 — base dynamic client (@zigbase/client). No codegen: collections are
// addressed by name via zb.collection(...), and types are supplied by the caller.

let server: BlogServer;
beforeAll(async () => { server = await startBlog(); });
afterAll(() => server?.stop());

interface Post { id: string; title: string; status: string; author: string }

describe("blog — base @zigbase/client (Tier 1: dynamic)", () => {
  it("serves the Zigapagos release from the runtime static directory", async () => {
    const home = await fetch(`${server.url}/`);
    expect(home.status).toBe(200);
    const html = await home.text();
    expect(html).toContain("ZigBase Blog");
    expect(html).toContain("PostList.island");

    const write = await fetch(`${server.url}/write/`);
    expect(write.status).toBe(200);
    expect(await write.text()).toContain("Sign in to write");
  });

  it("signs up, authenticates, and does CRUD on posts", async () => {
    const zb = createClient(server.url);

    // sign up an author on the `users` auth collection, then authenticate.
    const email = `writer-${Date.now()}@blog.local`;
    const user = await zb.collection("users").create({
      email, password: "writer-pass-1", passwordConfirm: "writer-pass-1", name: "Ada",
    });
    expect(user.id).toBeTruthy();
    await zb.collection("users").authWithPassword(email, "writer-pass-1");
    expect(zb.authStore.token).toBeTruthy();

    // create a published post (create rule requires auth; list/view require published).
    // The beforeCreate hook (setAuthor) automatically stamps the author field from
    // the authenticated identity, so the author field is set server-side.
    const created = await zb.collection("posts").create<Post>({
      title: "Hello from the base SDK", body: "Dynamic client, no codegen.",
      status: "published", author: user.id,
    });
    expect(created.title).toBe("Hello from the base SDK");

    // read it back (list is filtered to published server-side).
    const list = await zb.collection("posts").getList<Post>(1, 20, { filter: "status = 'published'" });
    expect(list.items.some((p) => p.id === created.id)).toBe(true);

    const one = await zb.collection("posts").getOne<Post>(created.id);
    expect(one.id).toBe(created.id);

    // update + delete (update/delete rule: author only — @request.auth.id = author).
    const updated = await zb.collection("posts").update<Post>(created.id, { title: "Edited" });
    expect(updated.title).toBe("Edited");
    await zb.collection("posts").delete(created.id);
  });
});
