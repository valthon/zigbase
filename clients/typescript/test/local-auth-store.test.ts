import { describe, it, expect } from "vitest";
import { LocalAuthStore } from "../src/auth-store.js";

function fakeStorage(): Storage {
  const map = new Map<string, string>();
  return {
    get length() { return map.size; },
    clear: () => map.clear(),
    getItem: (k) => (map.has(k) ? map.get(k)! : null),
    key: (i) => Array.from(map.keys())[i] ?? null,
    removeItem: (k) => void map.delete(k),
    setItem: (k, v) => void map.set(k, v),
  } as Storage;
}

describe("LocalAuthStore", () => {
  it("persists to and rehydrates from storage", () => {
    const storage = fakeStorage();
    const a = new LocalAuthStore("zb_auth", storage);
    a.save("x.y.z", { id: "u1", email: "a@b.c" });

    const b = new LocalAuthStore("zb_auth", storage);
    expect(b.token).toBe("x.y.z");
    expect(b.record?.id).toBe("u1");
  });

  it("clears storage on clear()", () => {
    const storage = fakeStorage();
    const a = new LocalAuthStore("zb_auth", storage);
    a.save("x.y.z", { id: "u1" });
    a.clear();
    expect(storage.getItem("zb_auth")).toBeNull();
  });
});
