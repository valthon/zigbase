import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { startServer, superuserToken, createCollection, type TestServer } from "./harness.js";
import { createClient } from "../../src/index.js";
import { filter } from "../../src/query.js";

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
    expect(list.items[0]!.views as number).toBe(4); // desc

    // --- offset pagination across 2 pages ---
    const p1 = await posts.getList(1, 2, { sort: "views" });
    const p2 = await posts.getList(2, 2, { sort: "views" });
    expect(p1.items.length).toBe(2);
    expect(p2.items.length).toBe(2);
    expect(p1.totalItems).toBe(5);

    // --- native cursor getPage: page through the whole collection with -created ---
    // The server mints opaque tokens; we just follow nextCursor across pages and
    // assert full coverage with no overlap.
    const seenIds: string[] = [];
    let cpage = await posts.getPage({ limit: 2, sort: "-created" });
    expect(cpage.items.length).toBe(2);
    expect(cpage.hasNext).toBe(true);
    expect(cpage.nextCursor).not.toBeNull();
    for (;;) {
      for (const rec of cpage.items) seenIds.push(rec.id as string);
      if (!cpage.hasNext || !cpage.nextCursor) break;
      cpage = await posts.getPage({ limit: 2, sort: "-created", cursor: cpage.nextCursor });
    }
    // Coverage + no overlap: every record seen exactly once.
    expect(seenIds.length).toBe(5);
    expect(new Set(seenIds).size).toBe(5);

    // --- iterate yields every record exactly once ---
    const iterated: string[] = [];
    for await (const rec of posts.iterate({ sort: "views", batch: 2 })) {
      iterated.push(rec.id as string);
    }
    expect(iterated.length).toBe(5);
    expect(new Set(iterated).size).toBe(5);

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

  it("round-trips a value containing a single quote through the filter tag", async () => {
    const zb = createClient(server.url);
    const posts = zb.collection("posts");

    // A value with an embedded single quote must reach the server intact and
    // match exactly. The filter tag single-quotes and escapes it (O'Brien -> 'O\'Brien');
    // this proves client quoting and the merged server lexer's escapes agree.
    const target = await posts.create({ title: "O'Brien", views: 100 });
    await posts.create({ title: "Smith", views: 101 });

    const list = await posts.getList(1, 30, {
      filter: filter`title = ${"O'Brien"}`,
    });
    expect(list.items.map((r) => r.id)).toEqual([target.id]);
    expect(list.items[0]!.title).toBe("O'Brien");
  });

  it("round-trips a value containing BOTH quote chars (proves client+server escapes agree)", async () => {
    const zb = createClient(server.url);
    const posts = zb.collection("posts");

    // The both-quotes case used to be unrepresentable; the merged lexer's backslash
    // escapes make it work. The tag emits 'he said "hi" to O\'Brien' — single-quoted,
    // single quote escaped, double quotes literal — and the server must match exactly.
    const tricky = `he said "hi" to O'Brien`;
    const target = await posts.create({ title: tricky, views: 200 });
    await posts.create({ title: `he said "bye"`, views: 201 });

    const list = await posts.getList(1, 30, {
      filter: filter`title = ${tricky}`,
    });
    expect(list.items.map((r) => r.id)).toEqual([target.id]);
    expect(list.items[0]!.title).toBe(tricky);
  });
});
