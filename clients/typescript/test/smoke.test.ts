import { describe, it, expect } from "vitest";
import { VERSION } from "../src/index.js";

describe("package", () => {
  it("exports a version", () => {
    expect(VERSION).toBe("0.0.0");
  });
});
