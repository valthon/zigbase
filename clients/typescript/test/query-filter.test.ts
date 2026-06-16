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

  it("always single-quotes and escapes an embedded single quote", () => {
    // The server lexer (src/query/lexer.zig) unescapes backslash sequences, so a
    // single quote inside the value is carried as \' rather than by swapping quotes.
    expect(filter`name = ${"O'Brien"}`).toBe("name = 'O\\'Brien'");
  });

  it("single-quotes a value that contains a double quote (left literal)", () => {
    expect(filter`q = ${'say "hi"'}`).toBe("q = 'say \"hi\"'");
  });

  it("represents a value with BOTH single and double quotes (no throw)", () => {
    // The escape-aware lexer makes any value representable: single-quote the value
    // and escape only the single quotes; the double quotes stay literal.
    expect(filter`x = ${`he said "hi" to O'Brien`}`).toBe(
      "x = 'he said \"hi\" to O\\'Brien'",
    );
  });

  it("escapes backslashes (a\\b -> 'a\\\\b')", () => {
    // A literal backslash must be doubled so the lexer unescapes it back to one byte.
    expect(filter`path = ${"a\\b"}`).toBe("path = 'a\\\\b'");
  });

  it("escapes control characters into \\n / \\t / \\r", () => {
    expect(filter`note = ${"a\nb\tc"}`).toBe("note = 'a\\nb\\tc'");
    expect(filter`note = ${"x\ry"}`).toBe("note = 'x\\ry'");
  });

  it("neutralizes an injection attempt (escaped, inert single token)", () => {
    const evil = "' || 1=1 --";
    // The leading single quote is escaped, so the whole payload stays inside one
    // single-quoted literal and cannot break out of it.
    expect(filter`name = ${evil}`).toBe("name = '\\' || 1=1 --'");
  });

  it("serializes Date as a single-quoted ISO string literal", () => {
    const d = new Date("2026-06-16T00:00:00.000Z");
    expect(filter`created > ${d}`).toBe("created > '2026-06-16T00:00:00.000Z'");
  });

  it("throws on array operands (ambiguous; callers must expand explicitly)", () => {
    expect(() => filter`id = ${["a", "b"]}`).toThrow(/array/i);
  });

  it("throws on non-finite numbers", () => {
    expect(() => filter`n > ${Infinity}`).toThrow(/non-finite/i);
    expect(() => filter`n > ${NaN}`).toThrow(/non-finite/i);
  });

  it("throws on objects / functions / symbols / bigint", () => {
    expect(() => filter`x = ${{ a: 1 }}`).toThrow(/unsupported operand/i);
    expect(() => filter`x = ${() => 0}`).toThrow(/unsupported operand/i);
    expect(() => filter`x = ${Symbol("s")}`).toThrow(/unsupported operand/i);
    expect(() => filter`x = ${10n}`).toThrow(/unsupported operand/i);
  });

  it("composes multiple interpolations with static text", () => {
    const q = "ab";
    expect(filter`status = ${"x"} && author.name ~ ${q}`).toBe(
      "status = 'x' && author.name ~ 'ab'",
    );
  });
});
