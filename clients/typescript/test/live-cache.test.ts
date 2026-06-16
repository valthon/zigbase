import { describe, it, expect, vi } from "vitest";
import { RecordCache } from "../src/live/cache.js";

describe("RecordCache + LiveRecord", () => {
  it("returns the SAME wrapped object for a given id across lookups", () => {
    const cache = new RecordCache();
    const a = cache.retain({ id: "p1", title: "First" });
    const b = cache.get("p1");
    expect(b).toBe(a);
    expect(a.get().title).toBe("First");
    // The wrapper "looks like" the record it wraps.
    expect((a as unknown as { title: string }).title).toBe("First");
    expect(a.id).toBe("p1");
  });

  it("patches fields in place, bumps version, and notifies on update", () => {
    const cache = new RecordCache();
    const live = cache.retain({ id: "p1", title: "First", views: 1 });
    const cb = vi.fn();
    live.subscribe(cb);
    const v0 = live.version;

    cache.applyUpdate({ id: "p1", title: "Edited", views: 2 });

    expect(live.get().title).toBe("Edited");
    expect((live as unknown as { views: number }).views).toBe(2);
    expect(live.version).toBe(v0 + 1);
    expect(cb).toHaveBeenCalledTimes(1);
    // Identity is stable through the patch.
    expect(cache.get("p1")).toBe(live);
  });

  it("flags a record deleted on a delete event and notifies", () => {
    const cache = new RecordCache();
    const live = cache.retain({ id: "p1", title: "First" });
    const cb = vi.fn();
    live.subscribe(cb);
    cache.applyDelete("p1");
    expect(live.deleted).toBe(true);
    expect(cb).toHaveBeenCalledTimes(1);
  });

  it("ref-counts: a record is evicted only when the last referer releases it", () => {
    const cache = new RecordCache();
    const a1 = cache.retain({ id: "p1", title: "First" }); // refcount 1
    const a2 = cache.retain({ id: "p1", title: "First" }); // refcount 2 (same object)
    expect(a2).toBe(a1);

    cache.release("p1"); // -> 1
    expect(cache.has("p1")).toBe(true);
    cache.release("p1"); // -> 0, evicted
    expect(cache.has("p1")).toBe(false);
  });

  it("patch skips reserved keys and does not prototype-pollute", () => {
    const cache = new RecordCache();
    const live = cache.retain({ id: "p1", title: "First", version: 0 });
    const v0 = live.version;

    // A hostile/server payload (correct id, but trying to clobber reserved
    // fields and reassign the prototype via __proto__).
    const evil = JSON.parse(
      '{"id":"p1","version":999,"deleted":true,"__proto__":{"polluted":true},"title":"Edited"}',
    );
    cache.applyUpdate(evil);

    // Only safe fields applied.
    expect(live.get().title).toBe("Edited");
    // Reserved fields untouched.
    expect(live.id).toBe("p1");
    expect(live.deleted).toBe(false);
    expect(live.version).toBe(v0 + 1); // bumped by the cache, not the payload's 999
    // No prototype pollution on the live record or plain objects.
    expect((live as unknown as { polluted?: boolean }).polluted).toBeUndefined();
    expect(({} as { polluted?: boolean }).polluted).toBeUndefined();
    expect(Object.getPrototypeOf(live.get())).toBe(Object.prototype);
  });

  it("patch removes accessors and proxied entries for keys dropped from the payload", () => {
    const cache = new RecordCache();
    const live = cache.retain({ id: "p1", title: "First", subtitle: "Sub" });
    expect(Object.keys(live)).toContain("subtitle");
    expect((live as unknown as { subtitle?: string }).subtitle).toBe("Sub");

    // Update omits subtitle -> it should disappear entirely.
    cache.applyUpdate({ id: "p1", title: "First" });
    expect(Object.keys(live)).not.toContain("subtitle");
    expect((live as unknown as { subtitle?: string }).subtitle).toBeUndefined();
    expect("subtitle" in live).toBe(false);

    // Re-adding it later works.
    cache.applyUpdate({ id: "p1", title: "First", subtitle: "Back" });
    expect(Object.keys(live)).toContain("subtitle");
    expect((live as unknown as { subtitle?: string }).subtitle).toBe("Back");
  });

  it("unsubscribing a record observer stops further notifications", () => {
    const cache = new RecordCache();
    const live = cache.retain({ id: "p1", n: 0 });
    const cb = vi.fn();
    const off = live.subscribe(cb);
    cache.applyUpdate({ id: "p1", n: 1 });
    off();
    cache.applyUpdate({ id: "p1", n: 2 });
    expect(cb).toHaveBeenCalledTimes(1);
  });
});
