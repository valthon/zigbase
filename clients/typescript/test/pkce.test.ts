import { describe, it, expect } from "vitest";
import { createPkceChallenge, randomState } from "../src/pkce.js";

describe("pkce", () => {
  it("produces a verifier and a base64url SHA-256 challenge", async () => {
    const { verifier, challenge } = await createPkceChallenge();
    expect(verifier).toMatch(/^[A-Za-z0-9\-._~]{43,128}$/);
    expect(challenge).toMatch(/^[A-Za-z0-9\-_]+$/); // base64url, no padding
    expect(challenge).not.toContain("=");
  });

  it("generates unique random state strings", () => {
    const a = randomState();
    const b = randomState();
    expect(a).not.toBe(b);
    expect(a.length).toBeGreaterThanOrEqual(16);
  });
});
