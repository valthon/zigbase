import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { startServer, superuserToken, createCollection, type TestServer } from "./harness.js";
import { createClient } from "../../src/index.js";
import { withRealtime } from "../../src/realtime-entry.js";

let server: TestServer;
let suToken: string;

beforeAll(async () => {
  server = await startServer();
  suToken = await superuserToken(server);
  // A @public-view collection so anonymous realtime subscriptions are allowed.
  // Field shape (id: "", lowercase type, options object) confirmed against the
  // Plan 1/2 records integration harness; "@public" is the ONLY allow-all sentinel.
  await createCollection(server, suToken, {
    name: "feed",
    type: "base",
    fields: [
      { id: "", name: "title", type: "text", options: {} },
      { id: "", name: "rank", type: "number", options: {} },
    ],
    listRule: "@public",
    viewRule: "@public",
    createRule: "@public",
    updateRule: "@public",
    deleteRule: "@public",
  });
});

afterAll(() => server?.stop());

async function createRecord(body: Record<string, unknown>): Promise<{ id: string }> {
  const res = await fetch(`${server.url}/api/collections/feed/records`, {
    method: "POST",
    headers: { "content-type": "application/json", Authorization: `Bearer ${suToken}` },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`create failed: ${res.status} ${await res.text()}`);
  return (await res.json()) as { id: string };
}

async function patchRecord(id: string, body: Record<string, unknown>): Promise<void> {
  const res = await fetch(`${server.url}/api/collections/feed/records/${id}`, {
    method: "PATCH",
    headers: { "content-type": "application/json", Authorization: `Bearer ${suToken}` },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`patch failed: ${res.status}`);
}

async function deleteRecord(id: string): Promise<void> {
  const res = await fetch(`${server.url}/api/collections/feed/records/${id}`, {
    method: "DELETE",
    headers: { Authorization: `Bearer ${suToken}` },
  });
  if (!res.ok) throw new Error(`delete failed: ${res.status}`);
}

function waitFor(cond: () => boolean, timeoutMs = 5000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  return new Promise((resolve, reject) => {
    const tick = () => {
      if (cond()) return resolve();
      if (Date.now() > deadline) return reject(new Error("timeout waiting for realtime event"));
      setTimeout(tick, 25);
    };
    tick();
  });
}

describe("realtime (live backend)", () => {
  it("delivers a create event to a low-level subscriber", async () => {
    const zb = withRealtime(createClient(server.url));
    const events: unknown[] = [];
    const unsub = await zb.realtime.subscribe("feed", (e) => events.push(e));

    const created = await createRecord({ title: "Hello", rank: 1 });
    await waitFor(() => events.length > 0);

    const ev = events[0] as { action: string; record: { id: string } };
    expect(ev.action).toBe("create");
    expect(ev.record.id).toBe(created.id);
    await unsub();
  });

  it("keeps a LiveList in sync: insert, in-place patch, remove", async () => {
    const seedA = await createRecord({ title: "A", rank: 10 });
    const zb = withRealtime(createClient(server.url));
    const live = zb.realtime.collection("feed");
    const list = await live.getList(1, 50, { sort: "rank" });
    let notified = 0;
    list.subscribe(() => (notified += 1));

    const before = list.items.length;

    // insert
    const seedB = await createRecord({ title: "B", rank: 5 });
    await waitFor(() => list.items.some((r) => r.id === seedB.id));
    expect(list.items.length).toBe(before + 1);
    // sorted: rank 5 (B) before rank 10 (A)
    const idxA = list.items.findIndex((r) => r.id === seedA.id);
    const idxB = list.items.findIndex((r) => r.id === seedB.id);
    expect(idxB).toBeLessThan(idxA);

    // in-place patch
    const liveA = list.items.find((r) => r.id === seedA.id)!;
    await patchRecord(seedA.id, { title: "A2" });
    await waitFor(() => (liveA as unknown as { title: string }).title === "A2");

    // remove
    await deleteRecord(seedB.id);
    await waitFor(() => !list.items.some((r) => r.id === seedB.id));

    expect(notified).toBeGreaterThan(0);
  });
});
