import { describe, it, expect } from "vitest";
import { filter } from "../src/query.js";

describe("filter template tag", () => {
  it("inlines numbers, booleans, and null without quotes", () => {
    expect(filter`n > ${5}`).toBe("n > 5");
    expect(filter`active = ${true}`).toBe("active = true");
    expect(filter`deleted = ${null}`).toBe("deleted = null");
    expect(filter`x = ${3.14}`).toBe("x = 3.14");
  });

  it("single-quotes strings", () => {
    expect(filter`status = ${"published"}`).toBe("status = 'published'");
  });

  it("escapes embedded single quotes and backslashes", () => {
    expect(filter`name = ${"O'Brien"}`).toBe("name = 'O\\'Brien'");
    expect(filter`path = ${"a\\b"}`).toBe("path = 'a\\\\b'");
  });

  it("escapes control characters (newline, tab)", () => {
    expect(filter`note = ${"a\nb\tc"}`).toBe("note = 'a\\nb\\tc'");
  });

  it("neutralizes an injection attempt", () => {
    const evil = "' || 1=1 --";
    // the quote is escaped, so the whole value stays a single string literal
    expect(filter`name = ${evil}`).toBe("name = '\\' || 1=1 --'");
  });

  it("serializes Date as an ISO string literal", () => {
    const d = new Date("2026-06-16T00:00:00.000Z");
    expect(filter`created > ${d}`).toBe("created > '2026-06-16T00:00:00.000Z'");
  });

  it("throws on array operands (ambiguous; callers must expand explicitly)", () => {
    expect(() => filter`id = ${["a", "b"]}`).toThrow(/array/i);
  });

  it("composes multiple interpolations with static text", () => {
    const q = "ab";
    expect(filter`status = ${"x"} && author.name ~ ${q}`).toBe(
      "status = 'x' && author.name ~ 'ab'",
    );
  });
});
