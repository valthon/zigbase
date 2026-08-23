import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { startServer, superuserToken, createCollection, type TestServer } from "./harness.js";
import { createClient } from "../fixtures/blog.gen.js";

let server: TestServer;

beforeAll(async () => {
  server = await startServer();
  const token = await superuserToken(server);

  // "@public" is the ONLY allow-all rule sentinel in ZigBase — an empty string ""
  // means locked/superuser-only. The typed client below is anonymous, so every
  // collection must use "@public" or CRUD will return 403/empty.
  //
  // Field shape confirmed against src/schema.zig: each field needs an `id` key
  // (may be ""), `name`, `type`; type-specific options live under `options` object.
  // Relation fields use `targetCollectionId` inside `options` (NOT top-level `collectionId`).

  // users (auth) — public create/list/view for the test.
  const usersCol = await createCollection(server, token, {
    name: "users",
    type: "auth",
    fields: [{ id: "", name: "name", type: "text", options: {} }],
    createRule: "@public",
    listRule: "@public",
    viewRule: "@public",
  });
  const usersId = usersCol.id as string;

  // tags (base) — public list/view/create.
  const tagsCol = await createCollection(server, token, {
    name: "tags",
    type: "base",
    fields: [{ id: "", name: "label", type: "text", required: true, options: {} }],
    listRule: "@public",
    viewRule: "@public",
    createRule: "@public",
  });
  const tagsId = tagsCol.id as string;

  // posts (base) with relation + multi-relation + select + file + autodate.
  // Relation fields use `targetCollectionId` (confirmed against src/schema.zig line 22).
  // Type-specific options nest under the `options` object.
  await createCollection(server, token, {
    name: "posts",
    type: "base",
    fields: [
      { id: "", name: "title", type: "text", required: true, options: {} },
      { id: "", name: "status", type: "select", options: { maxSelect: 1, values: ["draft", "published"] } },
      { id: "", name: "price", type: "number", options: {} },
      { id: "", name: "author", type: "relation", options: { maxSelect: 1, targetCollectionId: usersId } },
      { id: "", name: "tags", type: "relation", options: { maxSelect: 99, targetCollectionId: tagsId } },
      { id: "", name: "cover", type: "file", options: { maxSelect: 1 } },
      // No `created` field here: every base collection already carries the engine's own
      // id/created/updated columns, and `created` is a reserved field name. Declaring it was
      // always a no-op — the engine dropped it silently — so the `-created` sorts below have
      // only ever exercised the engine's column, and still do. Since #382 the same
      // declaration is refused outright (`validation_reserved_name`) instead of dropped.
    ],
    listRule: "@public",
    viewRule: "@public",
    createRule: "@public",
    updateRule: "@public",
    deleteRule: "@public",
  });
});

afterAll(() => server?.stop());

/** Poll until cond() returns true or timeoutMs elapses. */
function waitFor(cond: () => boolean, timeoutMs = 5000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  return new Promise((resolve, reject) => {
    const tick = () => {
      if (cond()) return resolve();
      if (Date.now() > deadline) return reject(new Error("timeout waiting for condition"));
      setTimeout(tick, 25);
    };
    tick();
  });
}

describe("typed blog client (live backend)", () => {
  it("typed CRUD + where + expand (author & tags) + cursor", async () => {
    const zb = createClient(server.url, { WebSocket: globalThis.WebSocket });

    // Seed a user + tags.
    const u = await zb.db.users.create({
      email: "a@b.c",
      password: "member-pass-1",
      passwordConfirm: "member-pass-1",
      name: "Ann",
    });
    const t1 = await zb.db.tags.create({ label: "zig" });
    const t2 = await zb.db.tags.create({ label: "ts" });

    // Create posts.
    const p1 = await zb.db.posts.create({
      title: "Hello",
      status: "published",
      price: 10,
      author: u.id,
      tags: [t1.id, t2.id],
    });
    await zb.db.posts.create({ title: "Draft", status: "draft", price: 0, author: u.id });

    expect(p1.id.length).toBeGreaterThan(0);
    expect(p1.status).toBe("published");

    // where filter.
    const published = await zb.db.posts.getList({ where: { status: "published" } });
    expect(published.items.length).toBe(1);
    expect(published.items[0]!.title).toBe("Hello");

    // expand author (single) — typed as User on .expand.author.
    const withAuthor = await zb.db.posts.getOne(p1.id, { expand: ["author"] });
    expect(withAuthor.expand.author.name).toBe("Ann");

    // expand tags (multi) — typed as Tag[] on .expand.tags.
    const withTags = await zb.db.posts.getOne(p1.id, { expand: ["tags"] });
    expect(withTags.expand.tags.map((t) => t.label).sort()).toEqual(["ts", "zig"]);

    // nested relation where: author.name ~ 'An'.
    const byAuthor = await zb.db.posts.getList({
      where: { author: { name: { like: "An" } } },
    });
    expect(byAuthor.items.length).toBe(2);

    // native cursor getPage — two-page keyset walk (seed has exactly 2 posts).
    const page1 = await zb.db.posts.getPage({ limit: 1, sort: "-created" });
    expect(page1.items.length).toBe(1);
    expect(page1.hasNext).toBe(true);
    expect(typeof page1.nextCursor).toBe("string");
    const page2 = await zb.db.posts.getPage({ limit: 1, sort: "-created", cursor: page1.nextCursor! });
    expect(page2.items.length).toBe(1);
    expect(page2.items[0]!.id).not.toBe(page1.items[0]!.id); // no overlap between pages
    expect(page2.hasNext).toBe(false); // exactly 2 posts seeded

    // fluent filter -> filter string the server accepts.
    const f = zb.db.posts.filter((b) => b.price.gte(5));
    const expensive = await zb.db.posts.getList({ where: { price: { gte: 5 } } });
    expect(f).toBe("price >= 5");
    expect(expensive.items.length).toBe(1);
  });

  it("authWithPassword sets the authStore token", async () => {
    const zb = createClient(server.url, { WebSocket: globalThis.WebSocket });
    // Create a user with password (SP1 auth requires password + passwordConfirm, min length 8).
    await zb.db.users.create({
      email: "auth@test.local",
      password: "test-pass-456",
      passwordConfirm: "test-pass-456",
      name: "AuthUser",
    });
    // authWithPassword routes through SP1's client.collection('users').authWithPassword.
    const authResult = await zb.db.users.authWithPassword("auth@test.local", "test-pass-456");
    expect(typeof authResult.token).toBe("string");
    expect(authResult.token.length).toBeGreaterThan(0);
    expect(authResult.record.email).toBe("auth@test.local");
    // The authStore should be populated.
    expect(zb.authStore.token).toBe(authResult.token);
  });

  it("realtime create -> typed event", async () => {
    const zb = createClient(server.url, { WebSocket: globalThis.WebSocket });
    const u = await zb.db.users.create({
      email: "rt@b.c",
      password: "member-pass-2",
      passwordConfirm: "member-pass-2",
      name: "Rt",
    });

    const events: string[] = [];
    const off = await zb.realtime.posts.subscribe((e) => {
      // `e.record` is typed Post in the fixture.
      events.push(`${e.action}:${e.record.title}`);
    });

    await zb.db.posts.create({ title: "Live", status: "draft", price: 1, author: u.id });

    // Poll for the event rather than fixed sleep to reduce flakiness.
    await waitFor(() => events.some((s) => s.startsWith("create:") && s.endsWith("Live")), 5000);
    off();
    expect(events.some((s) => s.startsWith("create:") && s.endsWith("Live"))).toBe(true);
  });
});
