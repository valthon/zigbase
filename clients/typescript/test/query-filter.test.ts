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

  it("switches to double quotes when the value contains a single quote", () => {
    // The server lexer reads quoted strings RAW (no backslash unescaping), so
    // an embedded single quote must be carried by switching the quote char.
    expect(filter`name = ${"O'Brien"}`).toBe('name = "O\'Brien"');
  });

  it("single-quotes a value that contains a double quote", () => {
    expect(filter`q = ${'say "hi"'}`).toBe("q = 'say \"hi\"'");
  });

  it("throws when a value contains BOTH single and double quotes", () => {
    expect(() => filter`x = ${`O'Brien said "hi"`}`).toThrow(/both single and double quote/i);
  });

  it("preserves backslashes literally (server reads raw bytes, no unescaping)", () => {
    // a\b must stay a\b — NOT a\\b — because the server does not unescape.
    expect(filter`path = ${"a\\b"}`).toBe("path = 'a\\b'");
  });

  it("preserves control characters literally", () => {
    expect(filter`note = ${"a\nb\tc"}`).toBe("note = 'a\nb\tc'");
  });

  it("neutralizes an injection attempt (single quote -> double-quoted inert token)", () => {
    const evil = "' || 1=1 --";
    // value contains a single quote -> emitted double-quoted; the chosen quote
    // char never appears inside, so it cannot break out of the literal.
    expect(filter`name = ${evil}`).toBe('name = "\' || 1=1 --"');
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
