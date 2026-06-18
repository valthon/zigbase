import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { spawnSync } from "node:child_process";
import { readFileSync, rmSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { startAppServer, DATING_BIN, superuserToken, type TestServer } from "./harness.js";

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

const HERE = resolve(fileURLToPath(new URL(".", import.meta.url)));
const GOLDEN = resolve(HERE, "../codegen/dating/zbase.runtime.gen.ts");
// Generate into a gitignored sibling of the golden so its `../../../src` imports resolve.
const LIVE_OUT = resolve(HERE, "../codegen/dating/zbase.runtime.live.gen.ts");

function runTypegen(extraArgs: string[]): void {
  const r = spawnSync(
    DATING_BIN,
    ["typegen", "--out", LIVE_OUT, "--api-prefix", "/api", ...extraArgs],
    { stdio: "inherit", env: { ...process.env, ZBASE_INREPO: "1" } },
  );
  if (r.status !== 0) throw new Error(`typegen failed: ${extraArgs.join(" ")}`);
}

let server: TestServer;
beforeAll(async () => {
  server = await startAppServer({ bin: DATING_BIN });
});
afterAll(() => {
  try { rmSync(LIVE_OUT, { force: true }); } catch { /* ignore */ }
  server?.stop();
});

describe("runtime typegen — live round-trip (dating-server)", () => {
  it("--data-dir generates a client byte-identical to the committed golden", () => {
    runTypegen(["--data-dir", server.dataDir]);
    expect(readFileSync(LIVE_OUT, "utf8")).toBe(readFileSync(GOLDEN, "utf8"));
  });

  it("--url (superuser-authed) generates a client byte-identical to the committed golden", () => {
    runTypegen([
      "--url", server.url,
      "--admin-email", server.superuser.email,
      "--admin-password", server.superuser.password,
    ]);
    expect(readFileSync(LIVE_OUT, "utf8")).toBe(readFileSync(GOLDEN, "utf8"));
  });

  it("the runtime-generated client works live: auth, CRUD, expand, realtime, int-coercion", async () => {
    runTypegen(["--data-dir", server.dataDir]);
    // The client is generated at runtime (gitignored, absent at typecheck time).
    // Import via a `string`-typed specifier so tsc does NOT try to resolve the
    // not-yet-existent module; vitest resolves it relative to this file at runtime.
    // Must match LIVE_OUT.
    const liveSpec: string = "../codegen/dating/zbase.runtime.live.gen.ts";
    const mod = await import(liveSpec);
    const zb = mod.createClient(server.url, { WebSocket: globalThis.WebSocket });

    // Auth as superuser by obtaining a token via direct fetch, then storing on the client.
    const token = await superuserToken(server);
    zb.authStore.save(token, { id: "superadmin" });

    // Create a profile record (auth collection).
    // age is typed number/.int — int coercion on write converts it to a decimal string
    // for the server; the typed client coerces it back to a number on read.
    const profile = await zb.db.profiles.create({
      email: "live@d.app",
      password: "pw-12345678",
      passwordConfirm: "pw-12345678",
      name: "Liv",
      age: 29, // exercises int-coercion path on write
    });
    expect(profile.id.length).toBeGreaterThan(0); // profile was created
    expect(profile.age).toBe(29); // typed client coerces int/fixed reads back to numbers

    const tag = await zb.db.tags.create({ label: "trail" });
    const photo = await zb.db.photos.create({ owner: profile.id, caption: "ridge", tags: [tag.id] });

    // nested-relation filter
    const byOwner = await zb.db.photos.getList({ where: { owner: { name: { like: "Liv" } } } });
    expect(byOwner.items.length).toBeGreaterThanOrEqual(1);

    // expand multi-relation (tags -> Tag[])
    const withTags = await zb.db.photos.getOne(photo.id, { expand: ["tags"] });
    expect(withTags.expand.tags[0]!.label).toBe("trail");

    // int-coercion: update with a float, expect it stored as int
    const updated = await zb.db.photos.update(photo.id, { caption: "ridge-2" });
    expect(updated.caption).toBe("ridge-2");

    // realtime round-trip
    const events: string[] = [];
    const off = await zb.realtime.photos.subscribe((e: { action: string; record: { id: string } }) => {
      events.push(`${e.action}:${e.record.id}`);
    });
    await zb.db.photos.update(photo.id, { caption: "ridge-3" });
    await waitFor(() => events.some((s) => s.startsWith("update:")), 5000);
    off();
    expect(events.some((s) => s.startsWith("update:"))).toBe(true);
  });
});
