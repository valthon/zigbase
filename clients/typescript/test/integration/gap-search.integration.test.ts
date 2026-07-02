import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { startAppServer, DATING_BIN, type TestServer } from "./harness.js";
import { createClient } from "../codegen/dating/zbase.gen.js";
import { createClient as createBaseClient } from "../../src/index.js";
import { isZigbaseError } from "../../src/errors.js";

let server: TestServer;
beforeAll(async () => {
  server = await startAppServer({ bin: DATING_BIN });
});
afterAll(() => server?.stop());

async function authedProfile(email: string) {
  const zb = createClient(server.url, { WebSocket: globalThis.WebSocket });
  const profile = await zb.db.profiles.create({
    email,
    password: "member-pass-1",
    passwordConfirm: "member-pass-1",
    name: email.split("@")[0]!,
    age: 30,
  });
  await zb.db.profiles.authWithPassword(email, "member-pass-1");
  return { zb, profile };
}

describe("search / native in / typed sort (live)", () => {
  it("FTS hit + miss on messages.body; 400 on an unsearchable collection", async () => {
    const { zb, profile } = await authedProfile("fts@d.app");
    await zb.db.messages.create({ from: profile.id, to: profile.id, body: "zig database rocks" });
    await zb.db.messages.create({ from: profile.id, to: profile.id, body: "unrelated chatter" });

    const hit = await zb.db.messages.getList({ search: "database" });
    expect(hit.items.length).toBe(1);
    expect(hit.items[0]!.body).toContain("database");
    const miss = await zb.db.messages.getList({ search: "nomatchterm" });
    expect(miss.items.length).toBe(0);

    // Unsearchable collection: the typed tier rejects at compile time; the SERVER 400 is
    // proven through the base client.
    const base = createBaseClient(server.url);
    try {
      await base.collection("tags").getList(1, 30, { search: "x" });
      expect.unreachable();
    } catch (e) {
      expect(isZigbaseError(e)).toBe(true);
      expect((e as { status: number }).status).toBe(400);
    }
  });

  it("vector on a default (non -Dvector) build answers a clean 400", async () => {
    const { zb } = await authedProfile("vec@d.app");
    try {
      await zb.db.subscriptions.getList({ vector: { field: "metadata", values: [0.1, 0.2] } });
      expect.unreachable();
    } catch (e) {
      expect(isZigbaseError(e)).toBe(true);
      expect((e as { status: number }).status).toBe(400);
    }
  });

  it("native `in` round-trips against the live grammar (incl. empty list)", async () => {
    const { zb, profile } = await authedProfile("innat@d.app");
    await zb.db.photos.create({ owner: profile.id, caption: "alpha" });
    await zb.db.photos.create({ owner: profile.id, caption: "beta" });
    await zb.db.photos.create({ owner: profile.id, caption: "gamma" });

    const some = await zb.db.photos.getList({
      where: { owner: profile.id, caption: { in: ["alpha", "gamma"] } },
    });
    expect(some.items.map((p) => p.caption).sort()).toEqual(["alpha", "gamma"]);

    const none = await zb.db.photos.getList({
      where: { owner: profile.id, caption: { in: [] } },
    });
    expect(none.items.length).toBe(0);
  });

  it("typed sort accepts single + array forms", async () => {
    const { zb, profile } = await authedProfile("sort@d.app");
    await zb.db.photos.create({ owner: profile.id, caption: "b" });
    await zb.db.photos.create({ owner: profile.id, caption: "a" });
    const list = await zb.db.photos.getList({
      where: { owner: profile.id },
      sort: ["caption", "-created"],
    });
    expect(list.items.map((p) => p.caption)).toEqual(["a", "b"]);
  });
});
