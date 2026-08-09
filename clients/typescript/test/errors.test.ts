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
      JSON.stringify({ status: 403, code: "forbidden", message: "Forbidden.", data: {} }),
      { status: 403, headers: { "content-type": "application/json" } },
    );
    const err = await parseErrorResponse(res, "http://x/api/y");
    expect(err.status).toBe(403);
    expect(err.message).toBe("Forbidden.");
    // The frozen machine code must survive the transport — this is what lets a caller
    // branch on `code` instead of matching message text.
    expect(err.code).toBe("forbidden");
  });

  it("exposes a bespoke code so callers never match on message text", async () => {
    const res = new Response(
      JSON.stringify({
        status: 403,
        code: "email_not_verified",
        message: "Email not verified.",
        data: {},
      }),
      { status: 403, headers: { "content-type": "application/json" } },
    );
    const err = await parseErrorResponse(res, "http://x/api/y");
    // Same status as a plain `forbidden`; only `code` distinguishes them.
    expect(err.status).toBe(403);
    expect(err.code).toBe("email_not_verified");
  });

  it("ignores a non-string code and never surfaces an integer as the machine code", async () => {
    // Pre-unification servers put the integer HTTP status in `code`.
    const res = new Response(JSON.stringify({ code: 403, message: "Forbidden." }), {
      status: 403,
      headers: { "content-type": "application/json" },
    });
    const err = await parseErrorResponse(res, "http://x/api/y");
    expect(err.code).toBe("");
  });

  it("leaves code empty when the body is not JSON", async () => {
    const err = await parseErrorResponse(new Response("oops", { status: 502 }), "http://x/y");
    expect(err.code).toBe("");
  });

  it("falls back to status text when body is not JSON", async () => {
    const res = new Response("oops", { status: 500 });
    const err = await parseErrorResponse(res, "http://x/api/y");
    expect(err.status).toBe(500);
    expect(err.message.length).toBeGreaterThan(0);
  });
});
