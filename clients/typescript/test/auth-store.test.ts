import { describe, it, expect, vi } from "vitest";
import { MemoryAuthStore } from "../src/auth-store.js";

function makeJwt(payload: Record<string, unknown>): string {
  const b64url = (o: unknown) => Buffer.from(JSON.stringify(o)).toString("base64url");
  return `${b64url({ alg: "HS256" })}.${b64url(payload)}.sig`;
}

describe("MemoryAuthStore", () => {
  it("starts empty and invalid", () => {
    const s = new MemoryAuthStore();
    expect(s.token).toBeNull();
    expect(s.record).toBeNull();
    expect(s.isValid).toBe(false);
  });

  it("saves token+record and computes validity from exp", () => {
    const s = new MemoryAuthStore();
    const token = makeJwt({ id: "u1", exp: Math.floor(Date.now() / 1000) + 3600 });
    s.save(token, { id: "u1", email: "a@b.c" });
    expect(s.token).toBe(token);
    expect(s.record?.id).toBe("u1");
    expect(s.isValid).toBe(true);
  });

  it("clears state", () => {
    const s = new MemoryAuthStore();
    s.save("x.y.z", { id: "u1" });
    s.clear();
    expect(s.token).toBeNull();
    expect(s.record).toBeNull();
  });

  it("notifies and unsubscribes onChange listeners", () => {
    const s = new MemoryAuthStore();
    const cb = vi.fn();
    const off = s.onChange(cb);
    s.save("x.y.z", { id: "u1" });
    expect(cb).toHaveBeenCalledTimes(1);
    off();
    s.clear();
    expect(cb).toHaveBeenCalledTimes(1);
  });
});
