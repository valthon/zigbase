import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { startPlugins, type PluginsServer } from "./harness.js";

// Issue #183 AC5 — "Custom build with static_routes: mappings resolve per the
// examples; ..." The /app/** catch-all in src/main.zig serves the embedded
// frontend shell (comptime-validated against the static_assets manifest) for any
// static miss below /app/.

let server: PluginsServer;
beforeAll(async () => { server = await startPlugins(); }, 120_000);
afterAll(() => server?.stop());

describe("plugins — comptime static_routes SPA fallback (#183)", () => {
  it("serves the Zigapagos release embedded in the executable at GET /", async () => {
    const res = await fetch(`${server.url}/`);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type") ?? "").toContain("text/html");
    const body = await res.text();
    expect(body).toContain("Everything in one binary");
    expect(body).toContain("data-z-island");
    expect(body).toContain("/islands/Browser.island.js");
  });

  it("keeps the authors, posts, comments, and commenter-auth API flows reachable", async () => {
    for (const collection of ["authors", "posts", "comments"]) {
      const res = await fetch(`${server.url}/api/collections/${collection}/records`);
      expect(res.status, collection).toBe(200);
      expect((await res.json()) as { items?: unknown[] }).toHaveProperty("items");
    }

    const login = await fetch(`${server.url}/api/collections/commenters/auth/magic_link/initiate`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ identity: "zigapagos-plugin-test@example.com" }),
    });
    expect(login.status).toBe(204);
  });

  it("serves the embedded shell for a deep link under /app/", async () => {
    const res = await fetch(`${server.url}/app/some/deep/client/route`);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type") ?? "").toContain("text/html");
    const body = await res.text();
    expect(body.toLowerCase()).toContain("one binary"); // the frontend shell's copy
  });

  it("does not match the bare /app... prefix outside the segment boundary", async () => {
    // '/application' shares only a string prefix with '/app/**' — segment matching
    // must NOT rewrite it, so it stays a plain static 404.
    const res = await fetch(`${server.url}/application`);
    expect(res.status).toBe(404);
  });

  it("never rewrites the API namespace (JSON 404 envelope preserved)", async () => {
    const res = await fetch(`${server.url}/api/definitely-missing`);
    expect(res.status).toBe(404);
    expect(res.headers.get("content-type") ?? "").toContain("application/json");
  });
});
