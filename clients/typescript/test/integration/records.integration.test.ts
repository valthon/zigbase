import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { startServer, superuserToken, createCollection, type TestServer } from "./harness.js";
import { createClient } from "../../src/index.js";

let server: TestServer;

beforeAll(async () => {
  server = await startServer();
  const token = await superuserToken(server);
  // Field shape confirmed against src/schema.zig: each field needs an `id` key (may be ""),
  // `name`, `type`; `required`/`unique` are top-level; type-specific options live under `options`.
  await createCollection(server, token, {
    name: "posts",
    type: "base",
    fields: [
      { id: "", name: "title", type: "text", required: true, options: {} },
      { id: "", name: "views", type: "number", options: {} },
      { id: "", name: "cover", type: "file", options: { maxSelect: 1 } },
    ],
    // Rule semantics confirmed against src/rules.zig: "@public" is the ONLY allow-all
    // sentinel; an empty string "" is LOCKED (superuser-only), NOT public.
    listRule: "@public",
    viewRule: "@public",
    createRule: "@public",
    updateRule: "@public",
    deleteRule: "@public",
  });
});

afterAll(() => server?.stop());

describe("records (live backend)", () => {
  it("creates, reads, paginates, cursors, uploads, updates, and deletes", async () => {
    const zb = createClient(server.url);
    const posts = zb.collection("posts");

    // --- create (JSON) a handful of records with distinct sort keys ---
    const created: string[] = [];
    for (let i = 0; i < 5; i++) {
      const rec = await posts.create({ title: `Post ${i}`, views: i });
      expect(rec.id).toBeTruthy();
      created.push(rec.id as string);
    }

    // --- getOne ---
    const one = await posts.getOne(created[0]!);
    expect(one.title).toBe("Post 0");

    // --- getList with filter + sort ---
    const list = await posts.getList(1, 30, { filter: "views >= 2", sort: "-views" });
    expect(list.items.length).toBe(3);
    expect((list.items[0] as { views: number }).views).toBe(4); // desc

    // --- offset pagination across 2 pages ---
    const p1 = await posts.getList(1, 2, { sort: "views" });
    const p2 = await posts.getList(2, 2, { sort: "views" });
    expect(p1.items.length).toBe(2);
    expect(p2.items.length).toBe(2);
    expect(p1.totalItems).toBe(5);

    // --- cursor getPage forward across 2 pages ---
    const c1 = await posts.getPage({ limit: 2, sort: "views" });
    expect(c1.items.length).toBe(2);
    expect(c1.hasNext).toBe(true);
    const c2 = await posts.getPage({ limit: 2, sort: "views", cursor: c1.nextCursor! });
    expect(c2.items.length).toBe(2);
    // forward progress: no overlap with page 1
    const p1ids = new Set(c1.items.map((i) => i.id));
    for (const rec of c2.items) expect(p1ids.has(rec.id)).toBe(false);

    // --- iterate counts every record ---
    let count = 0;
    for await (const _ of posts.iterate({ sort: "views", batch: 2 })) count += 1;
    expect(count).toBe(5);

    // --- multipart create with a small Blob, then files.getUrl GETs 200 ---
    const blob = new Blob(["hello-file"], { type: "text/plain" });
    const withFile = await posts.create({ title: "With cover", cover: blob });
    const coverName = (withFile as { cover?: string }).cover;
    expect(coverName).toBeTruthy();
    const fileUrl = zb.files.getUrl(
      { id: withFile.id as string, collectionName: "posts" },
      coverName as string,
    );
    const fileRes = await fetch(fileUrl);
    expect(fileRes.status).toBe(200);
    expect(await fileRes.text()).toBe("hello-file");

    // --- update ---
    const updated = await posts.update(created[0]!, { title: "Renamed" });
    expect(updated.title).toBe("Renamed");

    // --- delete ---
    await posts.delete(created[0]!);
    await expect(posts.getOne(created[0]!)).rejects.toMatchObject({ status: 404 });
  });
});
