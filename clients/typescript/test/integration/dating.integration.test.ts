import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { startAppServer, DATING_BIN, type TestServer } from "./harness.js";
import { createClient } from "../codegen/dating/zbase.gen.js";

let server: TestServer;

beforeAll(async () => {
  server = await startAppServer({ bin: DATING_BIN });
});
afterAll(() => server?.stop());

/** Poll until cond() is true or timeoutMs elapses (no fixed sleeps). */
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

/** Register a profile (public signup) and authenticate it; returns an authed client + the profile. */
async function authedProfile(email: string) {
  const zb = createClient(server.url, { WebSocket: globalThis.WebSocket });
  const profile = await zb.db.profiles.create({
    email,
    password: "member-pass-1",
    passwordConfirm: "member-pass-1",
    name: email.split("@")[0]!,
  });
  await zb.db.profiles.authWithPassword(email, "member-pass-1");
  return { zb, profile };
}

describe("dating client (live dating-server)", () => {
  it("CRUD + nested-relation filter + expand (single & multi) + native cursor", async () => {
    const { zb, profile } = await authedProfile("crud@d.app");
    const t1 = await zb.db.tags.create({ label: "hiking" });
    const t2 = await zb.db.tags.create({ label: "coffee" });

    // create photos owned by the profile, tagged.
    const p1 = await zb.db.photos.create({ owner: profile.id, caption: "trail", tags: [t1.id, t2.id] });
    await zb.db.photos.create({ owner: profile.id, caption: "espresso", tags: [t2.id] });
    expect(p1.id.length).toBeGreaterThan(0);

    // nested-relation filter: photos whose owner.name matches.
    const byOwner = await zb.db.photos.getList({ where: { owner: { name: { like: profile.name } } } });
    expect(byOwner.items.length).toBe(2);

    // expand single (owner -> Profile) and multi (tags -> Tag[]).
    const withOwner = await zb.db.photos.getOne(p1.id, { expand: ["owner"] });
    expect(withOwner.expand.owner.id).toBe(profile.id);
    const withTags = await zb.db.photos.getOne(p1.id, { expand: ["tags"] });
    expect(withTags.expand.tags.map((t) => t.label).sort()).toEqual(["coffee", "hiking"]);

    // update + delete.
    const upd = await zb.db.photos.update(p1.id, { caption: "summit" });
    expect(upd.caption).toBe("summit");
    await zb.db.photos.delete(p1.id);
    const remaining = await zb.db.photos.getList({ where: { owner: profile.id } });
    expect(remaining.items.length).toBe(1);

    // native cursor: walk the 2 tags one per page.
    const page1 = await zb.db.tags.getPage({ limit: 1, sort: "-created" });
    expect(page1.items.length).toBe(1);
    expect(page1.hasNext).toBe(true);
    const page2 = await zb.db.tags.getPage({ limit: 1, sort: "-created", cursor: page1.nextCursor! });
    expect(page2.items[0]!.id).not.toBe(page1.items[0]!.id);
  });

  it("realtime create -> typed event", async () => {
    const { zb, profile } = await authedProfile("rt@d.app");
    const events: string[] = [];
    const off = await zb.realtime.photos.subscribe((e) => events.push(`${e.action}:${e.record.id}`));
    const made = await zb.db.photos.create({ owner: profile.id, caption: "live" });
    await waitFor(() => events.some((s) => s === `create:${made.id}`), 5000);
    off();
    expect(events.some((s) => s === `create:${made.id}`)).toBe(true);
  });

  it("file upload: public avatar via fileUrl; private photo gated, accessible only with a token", async () => {
    const { zb, profile } = await authedProfile("files@d.app");

    // public avatar on the (public) profile -> fileUrl is fetchable anonymously.
    const avatar = new File([new Uint8Array([1, 2, 3, 4])], "a.png", { type: "image/png" });
    const withAvatar = await zb.db.profiles.update(profile.id, { avatar });
    const avatarUrl = zb.db.profiles.fileUrl(withAvatar, "avatar");
    const pub = await fetch(avatarUrl);
    expect(pub.ok).toBe(true);

    // private photo: owner-only view -> the image file is gated by the viewRule.
    const img = new File([new Uint8Array([5, 6, 7, 8])], "secret.png", { type: "image/png" });
    const priv = await zb.db.privatePhotos.create({ owner: profile.id, image: img, caption: "hidden" });
    const privUrlNoTok = zb.db.privatePhotos.fileUrl(priv, "image");

    // Anonymous fetch (no token) is denied.
    const anon = await fetch(privUrlNoTok);
    expect(anon.ok).toBe(false);

    // With a fresh file-access token (owner is authed), the file is fetchable.
    const token = await zb.files.getToken();
    const privUrlTok = zb.db.privatePhotos.fileUrl(priv, "image", { token });
    const ok = await fetch(privUrlTok);
    expect(ok.ok).toBe(true);
  });
});
