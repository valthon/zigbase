import { describe, it, expect } from "vitest";
import { decodeJwtPayload, isTokenExpired } from "../src/jwt.js";

function makeJwt(payload: Record<string, unknown>): string {
  const b64url = (o: unknown) =>
    Buffer.from(JSON.stringify(o)).toString("base64url");
  return `${b64url({ alg: "HS256", typ: "JWT" })}.${b64url(payload)}.sig`;
}

describe("jwt", () => {
  it("decodes the payload segment", () => {
    const token = makeJwt({ id: "u1", collection: "users", exp: 9999999999 });
    const p = decodeJwtPayload(token);
    expect(p?.id).toBe("u1");
    expect(p?.collection).toBe("users");
  });

  it("returns null for malformed tokens", () => {
    expect(decodeJwtPayload("not-a-jwt")).toBeNull();
    expect(decodeJwtPayload("")).toBeNull();
  });

  it("detects expiry with leeway", () => {
    const now = Math.floor(Date.now() / 1000);
    expect(isTokenExpired(makeJwt({ exp: now - 10 }))).toBe(true);
    expect(isTokenExpired(makeJwt({ exp: now + 3600 }))).toBe(false);
    expect(isTokenExpired(makeJwt({ exp: now + 5 }), 30)).toBe(true); // leeway pushes it past
    expect(isTokenExpired("garbage")).toBe(true);
  });
});
