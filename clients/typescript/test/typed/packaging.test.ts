import { describe, it, expect } from "vitest";
import { TYPED_CORE_VERSION } from "../../src/typed/index.js";

describe("typed core packaging", () => {
  it("exposes the typed entry", () => {
    expect(TYPED_CORE_VERSION).toBe("0.2.0");
  });
});
