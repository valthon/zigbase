import { describe, it, expect } from "vitest";
import { CookieAuthStore } from "../src/auth-store.js";

describe("CookieAuthStore", () => {
  it("exports state to a cookie string and reloads it", () => {
    const a = new CookieAuthStore("zb_auth");
    a.save("x.y.z", { id: "u1", email: "a@b.c" });
    const cookie = a.exportToCookie();
    expect(cookie).toContain("zb_auth=");

    const b = new CookieAuthStore("zb_auth");
    b.loadFromCookie(cookie);
    expect(b.token).toBe("x.y.z");
    expect(b.record?.id).toBe("u1");
  });

  it("ignores an unrelated cookie header", () => {
    const b = new CookieAuthStore("zb_auth");
    b.loadFromCookie("other=1; somethingelse=2");
    expect(b.token).toBeNull();
  });

  it("does not throw on a non-string / undefined cookie header", () => {
    const b = new CookieAuthStore("zb_auth");
    expect(() => b.loadFromCookie(undefined as unknown as string)).not.toThrow();
    expect(b.token).toBeNull();
    // Empty string is a no-op too.
    expect(() => b.loadFromCookie("")).not.toThrow();
    expect(b.token).toBeNull();
    // A valid cookie still loads after the guarded calls.
    const a = new CookieAuthStore("zb_auth");
    a.save("x.y.z", { id: "u1" });
    b.loadFromCookie(a.exportToCookie());
    expect(b.token).toBe("x.y.z");
  });
});
