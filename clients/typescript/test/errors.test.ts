import { describe, it, expect } from "vitest";
import { ZigbaseError, isZigbaseError, parseErrorResponse } from "../src/errors.js";

describe("ZigbaseError", () => {
  it("captures status, message, and field data", () => {
    const err = new ZigbaseError({
      status: 400,
      message: "Failed to validate the request.",
      data: { email: { code: "validation_required", message: "Missing." } },
      url: "http://x/api/collections/users/records",
    });
    expect(err).toBeInstanceOf(Error);
    expect(err.status).toBe(400);
    expect(err.data.email?.code).toBe("validation_required");
    expect(isZigbaseError(err)).toBe(true);
    expect(isZigbaseError(new Error("x"))).toBe(false);
  });

  it("parses a zigbase error response body", async () => {
    const res = new Response(
      JSON.stringify({ code: 403, message: "Forbidden.", data: {} }),
      { status: 403, headers: { "content-type": "application/json" } },
    );
    const err = await parseErrorResponse(res, "http://x/api/y");
    expect(err.status).toBe(403);
    expect(err.message).toBe("Forbidden.");
  });

  it("falls back to status text when body is not JSON", async () => {
    const res = new Response("oops", { status: 500 });
    const err = await parseErrorResponse(res, "http://x/api/y");
    expect(err.status).toBe(500);
    expect(err.message.length).toBeGreaterThan(0);
  });
});
