import { describe, it, expect } from "vitest";
import * as zb from "../src/index.js";

describe("public exports (Plan 2)", () => {
  it("re-exports the query helpers", () => {
    expect(typeof zb.filter).toBe("function");
    expect(typeof zb.parseSort).toBe("function");
    expect(typeof zb.compareBySort).toBe("function");
  });

  it("re-exports the cursor helpers", () => {
    expect(typeof zb.encodeCursor).toBe("function");
    expect(typeof zb.decodeCursor).toBe("function");
  });

  it("re-exports FilesService", () => {
    expect(typeof zb.FilesService).toBe("function");
  });

  it("re-exports record/multipart helpers", () => {
    expect(typeof zb.hasBlob).toBe("function");
    expect(typeof zb.toFormData).toBe("function");
  });
});
