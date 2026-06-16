import { describe, it, expect } from "vitest";
import { parseFilter, analyzeFilter } from "../src/live/filter-eval.js";

describe("analyzeFilter", () => {
  it("classifies own-scalar-field filters as locally evaluable", () => {
    const a = analyzeFilter(parseFilter("status = 'published' && views > 10"));
    expect(a.locallyEvaluable).toBe(true);
    expect(a.referencesRelations).toBe(false);
    expect(a.referencesMacros).toBe(false);
  });

  it("flags relation-traversal filters as NOT locally evaluable", () => {
    const a = analyzeFilter(parseFilter("author.name = 'Ada'"));
    expect(a.locallyEvaluable).toBe(false);
    expect(a.referencesRelations).toBe(true);
  });

  it("flags @request.* / macro filters as NOT locally evaluable", () => {
    const a = analyzeFilter(parseFilter("@request.auth.id = owner"));
    expect(a.locallyEvaluable).toBe(false);
    expect(a.referencesMacros).toBe(true);
  });

  it("treats an empty filter (undefined) as locally evaluable (matches all)", () => {
    const a = analyzeFilter(undefined);
    expect(a.locallyEvaluable).toBe(true);
  });
});
