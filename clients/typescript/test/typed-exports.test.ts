import { describe, it, expect } from "vitest";
import * as typed from "../src/typed/index.js";

describe("@zigbase/client/typed public exports", () => {
  it("exports TYPED_CORE_VERSION", () => {
    expect(typeof typed.TYPED_CORE_VERSION).toBe("string");
    expect(typed.TYPED_CORE_VERSION).toBe("0.1.0");
  });

  it("exports runtime factory functions", () => {
    expect(typeof typed.makeRecordService).toBe("function");
    expect(typeof typed.makeFilterBuilder).toBe("function");
    expect(typeof typed.makeTypedRealtime).toBe("function");
    expect(typeof typed.makeTypedFiles).toBe("function");
  });

  it("exports where-DSL compiler + constants", () => {
    expect(typeof typed.compileWhere).toBe("function");
    expect(typeof typed.compileIn).toBe("function");
    expect(typeof typed.OP_MAP).toBe("object");
  });

  it("exports fluent builder constructors", () => {
    expect(typeof typed.Expr).toBe("function");
    expect(typeof typed.FieldExpr).toBe("function");
  });

  it("exports fieldMeta helper", () => {
    expect(typeof typed.fieldMeta).toBe("function");
  });
});
