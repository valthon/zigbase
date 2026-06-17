import { describe, it, expect } from "vitest";
import { quoteFilterValue } from "../../src/query.js";

describe("quoteFilterValue", () => {
  it("quotes and escapes strings injection-safely", () => {
    expect(quoteFilterValue("published")).toBe("'published'");
    // A closing-quote injection attempt stays escaped inside the literal.
    expect(quoteFilterValue("a' || 1=1 --")).toBe("'a\\' || 1=1 --'");
  });
  it("passes numbers and booleans bare", () => {
    expect(quoteFilterValue(10)).toBe("10");
    expect(quoteFilterValue(true)).toBe("true");
  });
  it("serializes Date as a quoted ISO string", () => {
    expect(quoteFilterValue(new Date("2020-01-01T00:00:00.000Z"))).toBe(
      "'2020-01-01T00:00:00.000Z'",
    );
  });
  it("rejects array and object operands", () => {
    expect(() => quoteFilterValue([1, 2])).toThrow();
    expect(() => quoteFilterValue({})).toThrow();
  });
});
