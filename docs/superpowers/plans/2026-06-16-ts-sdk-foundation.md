# TypeScript SDK — Plan 1: Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the foundation of `@zigbase/client` — error model, JWT decode, pluggable AuthStores, the fetch transport, the client core, and the auth service — usable to authenticate against and call a real ZigBase backend.

**Architecture:** Zero-dependency, ESM-first TypeScript package under `clients/typescript/`. A `Transport` wraps `fetch` (Bearer auth from a pluggable `AuthStore`, error mapping, 429 backoff, optional one-shot auto-refresh). `createClient()` returns a `Client` whose `collection(name)` yields a `CollectionService` exposing auth methods now (record CRUD comes in Plan 2) plus a generic `send()` escape hatch.

**Tech Stack:** TypeScript, `tsup` (ESM+CJS build), `vitest` (unit + integration), platform globals (`fetch`, `crypto.subtle`, `atob`). Integration tests run against a real `zigbase serve` binary built with `zig build`.

**Plan context:** This is Plan 1 of 3 for SP1 (base runtime SDK). Plan 2 adds records/cursors/files; Plan 3 adds realtime + live store. Spec: `docs/superpowers/specs/2026-06-16-zigbase-ts-sdk-base-design.md`.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `clients/typescript/package.json` | npm manifest, scripts, `"sideEffects": false`, exports map. |
| `clients/typescript/tsconfig.json` | TS config (ES2022, strict). |
| `clients/typescript/tsup.config.ts` | ESM+CJS bundle config. |
| `clients/typescript/vitest.config.ts` | unit test config. |
| `clients/typescript/vitest.integration.config.ts` | integration test config + global setup. |
| `clients/typescript/src/errors.ts` | `ZigbaseError`, `isZigbaseError`, `parseErrorResponse`. |
| `clients/typescript/src/jwt.ts` | `decodeJwtPayload`, `isTokenExpired` (no signature check). |
| `clients/typescript/src/auth-store.ts` | `AuthStore` interface + `BaseAuthStore`, `MemoryAuthStore`, `LocalAuthStore`, `CookieAuthStore`. |
| `clients/typescript/src/pkce.ts` | `createPkceChallenge`, `randomState`. |
| `clients/typescript/src/transport.ts` | `Transport` (URL/headers/body, error mapping, retries). |
| `clients/typescript/src/collection.ts` | `CollectionService` (auth methods now; records added in Plan 2). |
| `clients/typescript/src/client.ts` | `createClient`, `Client`, `ClientOptions`. |
| `clients/typescript/src/index.ts` | public re-exports. |
| `clients/typescript/test/integration/harness.ts` | build/launch a real `zigbase serve`, superuser + schema helpers. |

---

## Task 1: Package scaffold

**Files:**
- Create: `clients/typescript/package.json`
- Create: `clients/typescript/tsconfig.json`
- Create: `clients/typescript/tsup.config.ts`
- Create: `clients/typescript/vitest.config.ts`
- Create: `clients/typescript/src/index.ts`
- Create: `clients/typescript/.gitignore`
- Test: `clients/typescript/test/smoke.test.ts`

- [ ] **Step 1: Create `package.json`**

```json
{
  "name": "@zigbase/client",
  "version": "0.0.0",
  "description": "Official TypeScript client for ZigBase",
  "type": "module",
  "sideEffects": false,
  "main": "./dist/index.cjs",
  "module": "./dist/index.js",
  "types": "./dist/index.d.ts",
  "exports": {
    ".": {
      "types": "./dist/index.d.ts",
      "import": "./dist/index.js",
      "require": "./dist/index.cjs"
    }
  },
  "files": ["dist"],
  "scripts": {
    "build": "tsup",
    "test": "vitest run",
    "test:watch": "vitest",
    "test:integration": "vitest run --config vitest.integration.config.ts",
    "typecheck": "tsc --noEmit"
  },
  "engines": { "node": ">=18" },
  "license": "SEE LICENSE IN ../../LICENSE",
  "devDependencies": {
    "tsup": "^8.0.0",
    "typescript": "^5.4.0",
    "vitest": "^1.6.0"
  }
}
```

- [ ] **Step 2: Create `tsconfig.json`**

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "lib": ["ES2022", "DOM"],
    "strict": true,
    "declaration": true,
    "noUncheckedIndexedAccess": true,
    "verbatimModuleSyntax": true,
    "skipLibCheck": true,
    "outDir": "dist"
  },
  "include": ["src", "test"]
}
```

- [ ] **Step 3: Create `tsup.config.ts`**

```ts
import { defineConfig } from "tsup";

export default defineConfig({
  entry: ["src/index.ts"],
  format: ["esm", "cjs"],
  dts: true,
  clean: true,
  treeshake: true,
  target: "es2022",
});
```

- [ ] **Step 4: Create `vitest.config.ts`**

```ts
import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["test/**/*.test.ts"],
    exclude: ["test/integration/**"],
    environment: "node",
  },
});
```

- [ ] **Step 5: Create `.gitignore`**

```
node_modules
dist
```

- [ ] **Step 6: Create `src/index.ts` placeholder**

```ts
export const VERSION = "0.0.0";
```

- [ ] **Step 7: Create `test/smoke.test.ts`**

```ts
import { describe, it, expect } from "vitest";
import { VERSION } from "../src/index.js";

describe("package", () => {
  it("exports a version", () => {
    expect(VERSION).toBe("0.0.0");
  });
});
```

- [ ] **Step 8: Install and run**

Run: `cd clients/typescript && npm install && npm test`
Expected: 1 passing test.

- [ ] **Step 9: Commit**

```bash
git add clients/typescript
git commit -m "chore(ts-sdk): scaffold @zigbase/client package"
```

---

## Task 2: Error model

**Files:**
- Create: `clients/typescript/src/errors.ts`
- Test: `clients/typescript/test/errors.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test -- errors`
Expected: FAIL — cannot find `../src/errors.js`.

- [ ] **Step 3: Implement `src/errors.ts`**

```ts
export interface FieldError {
  code: string;
  message: string;
}

export interface ZigbaseErrorInit {
  status: number;
  message: string;
  data?: Record<string, FieldError>;
  url: string;
  response?: Response;
}

export class ZigbaseError extends Error {
  readonly status: number;
  readonly data: Record<string, FieldError>;
  readonly url: string;
  readonly response?: Response;

  constructor(init: ZigbaseErrorInit) {
    super(init.message);
    this.name = "ZigbaseError";
    this.status = init.status;
    this.data = init.data ?? {};
    this.url = init.url;
    this.response = init.response;
  }
}

export function isZigbaseError(e: unknown): e is ZigbaseError {
  return e instanceof ZigbaseError;
}

export async function parseErrorResponse(res: Response, url: string): Promise<ZigbaseError> {
  let message = res.statusText || `Request failed with status ${res.status}`;
  let data: Record<string, FieldError> = {};
  try {
    const body = (await res.clone().json()) as {
      message?: string;
      data?: Record<string, FieldError>;
    };
    if (body && typeof body.message === "string") message = body.message;
    if (body && body.data && typeof body.data === "object") data = body.data;
  } catch {
    // non-JSON body; keep status-text fallback
  }
  return new ZigbaseError({ status: res.status, message, data, url, response: res });
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npm test -- errors`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add clients/typescript/src/errors.ts clients/typescript/test/errors.test.ts
git commit -m "feat(ts-sdk): error model (ZigbaseError + parseErrorResponse)"
```

---

## Task 3: JWT decode + expiry

**Files:**
- Create: `clients/typescript/src/jwt.ts`
- Test: `clients/typescript/test/jwt.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
import { describe, it, expect } from "vitest";
import { decodeJwtPayload, isTokenExpired } from "../src/jwt.js";

function makeJwt(payload: Record<string, unknown>): string {
  const b64url = (o: unknown) =>
    Buffer.from(JSON.stringify(o)).toString("base64url");
  return `${b64url({ alg: "HS256", typ: "JWT" })}.${b64url(payload)}.sig`;
}

describe("jwt", () => {
  it("decodes the payload segment", () => {
    const token = makeJwt({ id: "u1", collection: "users", exp: 9999999999 });
    const p = decodeJwtPayload(token);
    expect(p?.id).toBe("u1");
    expect(p?.collection).toBe("users");
  });

  it("returns null for malformed tokens", () => {
    expect(decodeJwtPayload("not-a-jwt")).toBeNull();
    expect(decodeJwtPayload("")).toBeNull();
  });

  it("detects expiry with leeway", () => {
    const now = Math.floor(Date.now() / 1000);
    expect(isTokenExpired(makeJwt({ exp: now - 10 }))).toBe(true);
    expect(isTokenExpired(makeJwt({ exp: now + 3600 }))).toBe(false);
    expect(isTokenExpired(makeJwt({ exp: now + 5 }), 30)).toBe(true); // leeway pushes it past
    expect(isTokenExpired("garbage")).toBe(true);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test -- jwt`
Expected: FAIL — cannot find `../src/jwt.js`.

- [ ] **Step 3: Implement `src/jwt.ts`**

```ts
export interface JwtPayload {
  id?: string;
  collection?: string;
  type?: string;
  exp?: number;
  iat?: number;
  [key: string]: unknown;
}

function base64UrlDecode(segment: string): string {
  const padded = segment.replace(/-/g, "+").replace(/_/g, "/");
  const pad = padded.length % 4 === 0 ? "" : "=".repeat(4 - (padded.length % 4));
  const b64 = padded + pad;
  // atob is available in browsers and Node 18+.
  const binary = atob(b64);
  // Decode UTF-8 bytes.
  const bytes = Uint8Array.from(binary, (c) => c.charCodeAt(0));
  return new TextDecoder().decode(bytes);
}

export function decodeJwtPayload(token: string): JwtPayload | null {
  if (typeof token !== "string") return null;
  const parts = token.split(".");
  if (parts.length !== 3 || !parts[1]) return null;
  try {
    return JSON.parse(base64UrlDecode(parts[1])) as JwtPayload;
  } catch {
    return null;
  }
}

export function isTokenExpired(token: string, leewaySeconds = 0): boolean {
  const payload = decodeJwtPayload(token);
  if (!payload || typeof payload.exp !== "number") return true;
  const now = Math.floor(Date.now() / 1000);
  return payload.exp - leewaySeconds <= now;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npm test -- jwt`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add clients/typescript/src/jwt.ts clients/typescript/test/jwt.test.ts
git commit -m "feat(ts-sdk): local JWT payload decode + expiry check"
```

---

## Task 4: AuthStore base + MemoryAuthStore

**Files:**
- Create: `clients/typescript/src/auth-store.ts`
- Test: `clients/typescript/test/auth-store.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
import { describe, it, expect, vi } from "vitest";
import { MemoryAuthStore } from "../src/auth-store.js";

function makeJwt(payload: Record<string, unknown>): string {
  const b64url = (o: unknown) => Buffer.from(JSON.stringify(o)).toString("base64url");
  return `${b64url({ alg: "HS256" })}.${b64url(payload)}.sig`;
}

describe("MemoryAuthStore", () => {
  it("starts empty and invalid", () => {
    const s = new MemoryAuthStore();
    expect(s.token).toBeNull();
    expect(s.record).toBeNull();
    expect(s.isValid).toBe(false);
  });

  it("saves token+record and computes validity from exp", () => {
    const s = new MemoryAuthStore();
    const token = makeJwt({ id: "u1", exp: Math.floor(Date.now() / 1000) + 3600 });
    s.save(token, { id: "u1", email: "a@b.c" });
    expect(s.token).toBe(token);
    expect(s.record?.id).toBe("u1");
    expect(s.isValid).toBe(true);
  });

  it("clears state", () => {
    const s = new MemoryAuthStore();
    s.save("x.y.z", { id: "u1" });
    s.clear();
    expect(s.token).toBeNull();
    expect(s.record).toBeNull();
  });

  it("notifies and unsubscribes onChange listeners", () => {
    const s = new MemoryAuthStore();
    const cb = vi.fn();
    const off = s.onChange(cb);
    s.save("x.y.z", { id: "u1" });
    expect(cb).toHaveBeenCalledTimes(1);
    off();
    s.clear();
    expect(cb).toHaveBeenCalledTimes(1);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test -- auth-store`
Expected: FAIL — cannot find `../src/auth-store.js`.

- [ ] **Step 3: Implement `src/auth-store.ts` (base + memory)**

```ts
import { isTokenExpired } from "./jwt.js";

export interface AuthRecord {
  id: string;
  [key: string]: unknown;
}

export type AuthChangeListener = (
  token: string | null,
  record: AuthRecord | null,
) => void;

export interface AuthStore {
  readonly token: string | null;
  readonly record: AuthRecord | null;
  readonly isValid: boolean;
  save(token: string, record: AuthRecord): void;
  clear(): void;
  onChange(cb: AuthChangeListener): () => void;
}

export class BaseAuthStore implements AuthStore {
  protected _token: string | null = null;
  protected _record: AuthRecord | null = null;
  private listeners = new Set<AuthChangeListener>();

  get token(): string | null {
    return this._token;
  }
  get record(): AuthRecord | null {
    return this._record;
  }
  get isValid(): boolean {
    return this._token !== null && !isTokenExpired(this._token);
  }

  save(token: string, record: AuthRecord): void {
    this._token = token;
    this._record = record;
    this.emit();
  }

  clear(): void {
    this._token = null;
    this._record = null;
    this.emit();
  }

  onChange(cb: AuthChangeListener): () => void {
    this.listeners.add(cb);
    return () => this.listeners.delete(cb);
  }

  protected emit(): void {
    for (const cb of this.listeners) cb(this._token, this._record);
  }
}

export class MemoryAuthStore extends BaseAuthStore {}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npm test -- auth-store`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add clients/typescript/src/auth-store.ts clients/typescript/test/auth-store.test.ts
git commit -m "feat(ts-sdk): AuthStore interface + MemoryAuthStore"
```

---

## Task 5: LocalAuthStore

**Files:**
- Modify: `clients/typescript/src/auth-store.ts`
- Test: `clients/typescript/test/local-auth-store.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
import { describe, it, expect } from "vitest";
import { LocalAuthStore } from "../src/auth-store.js";

function fakeStorage(): Storage {
  const map = new Map<string, string>();
  return {
    get length() { return map.size; },
    clear: () => map.clear(),
    getItem: (k) => (map.has(k) ? map.get(k)! : null),
    key: (i) => Array.from(map.keys())[i] ?? null,
    removeItem: (k) => void map.delete(k),
    setItem: (k, v) => void map.set(k, v),
  } as Storage;
}

describe("LocalAuthStore", () => {
  it("persists to and rehydrates from storage", () => {
    const storage = fakeStorage();
    const a = new LocalAuthStore("zb_auth", storage);
    a.save("x.y.z", { id: "u1", email: "a@b.c" });

    const b = new LocalAuthStore("zb_auth", storage);
    expect(b.token).toBe("x.y.z");
    expect(b.record?.id).toBe("u1");
  });

  it("clears storage on clear()", () => {
    const storage = fakeStorage();
    const a = new LocalAuthStore("zb_auth", storage);
    a.save("x.y.z", { id: "u1" });
    a.clear();
    expect(storage.getItem("zb_auth")).toBeNull();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test -- local-auth-store`
Expected: FAIL — `LocalAuthStore` is not exported.

- [ ] **Step 3: Add `LocalAuthStore` to `src/auth-store.ts`**

Append to the file:

```ts
interface StorageLike {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
  removeItem(key: string): void;
}

export class LocalAuthStore extends BaseAuthStore {
  constructor(
    private readonly key = "zb_auth",
    private readonly storage: StorageLike | undefined = globalThis.localStorage,
  ) {
    super();
    this.rehydrate();
  }

  private rehydrate(): void {
    const raw = this.storage?.getItem(this.key);
    if (!raw) return;
    try {
      const parsed = JSON.parse(raw) as { token: string; record: AuthRecord };
      this._token = parsed.token ?? null;
      this._record = parsed.record ?? null;
    } catch {
      // ignore corrupt storage
    }
  }

  override save(token: string, record: AuthRecord): void {
    this.storage?.setItem(this.key, JSON.stringify({ token, record }));
    super.save(token, record);
  }

  override clear(): void {
    this.storage?.removeItem(this.key);
    super.clear();
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npm test -- local-auth-store`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add clients/typescript/src/auth-store.ts clients/typescript/test/local-auth-store.test.ts
git commit -m "feat(ts-sdk): LocalAuthStore (localStorage persistence)"
```

---

## Task 6: CookieAuthStore

**Files:**
- Modify: `clients/typescript/src/auth-store.ts`
- Test: `clients/typescript/test/cookie-auth-store.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
import { describe, it, expect } from "vitest";
import { CookieAuthStore } from "../src/auth-store.js";

describe("CookieAuthStore", () => {
  it("exports state to a cookie string and reloads it", () => {
    const a = new CookieAuthStore("zb_auth");
    a.save("x.y.z", { id: "u1", email: "a@b.c" });
    const cookie = a.exportToCookie();
    expect(cookie).toContain("zb_auth=");

    const b = new CookieAuthStore("zb_auth");
    b.loadFromCookie(cookie);
    expect(b.token).toBe("x.y.z");
    expect(b.record?.id).toBe("u1");
  });

  it("ignores an unrelated cookie header", () => {
    const b = new CookieAuthStore("zb_auth");
    b.loadFromCookie("other=1; somethingelse=2");
    expect(b.token).toBeNull();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test -- cookie-auth-store`
Expected: FAIL — `CookieAuthStore` is not exported.

- [ ] **Step 3: Add `CookieAuthStore` to `src/auth-store.ts`**

Append to the file:

```ts
export interface CookieSerializeOptions {
  path?: string;
  maxAge?: number;
  sameSite?: "strict" | "lax" | "none";
  secure?: boolean;
}

export class CookieAuthStore extends BaseAuthStore {
  constructor(private readonly key = "zb_auth") {
    super();
  }

  exportToCookie(opts: CookieSerializeOptions = {}): string {
    const value = encodeURIComponent(
      JSON.stringify({ token: this._token, record: this._record }),
    );
    const parts = [`${this.key}=${value}`, `Path=${opts.path ?? "/"}`];
    if (opts.maxAge !== undefined) parts.push(`Max-Age=${opts.maxAge}`);
    parts.push(`SameSite=${opts.sameSite ?? "Strict"}`);
    if (opts.secure) parts.push("Secure");
    return parts.join("; ");
  }

  loadFromCookie(cookieHeader: string): void {
    const match = cookieHeader
      .split(";")
      .map((c) => c.trim())
      .find((c) => c.startsWith(`${this.key}=`));
    if (!match) return;
    try {
      const raw = decodeURIComponent(match.slice(this.key.length + 1));
      const parsed = JSON.parse(raw) as { token: string | null; record: AuthRecord | null };
      this._token = parsed.token ?? null;
      this._record = parsed.record ?? null;
      this.emit();
    } catch {
      // ignore malformed cookie
    }
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npm test -- cookie-auth-store`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add clients/typescript/src/auth-store.ts clients/typescript/test/cookie-auth-store.test.ts
git commit -m "feat(ts-sdk): CookieAuthStore (SSR token handoff)"
```

---

## Task 7: PKCE helper

**Files:**
- Create: `clients/typescript/src/pkce.ts`
- Test: `clients/typescript/test/pkce.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
import { describe, it, expect } from "vitest";
import { createPkceChallenge, randomState } from "../src/pkce.js";

describe("pkce", () => {
  it("produces a verifier and a base64url SHA-256 challenge", async () => {
    const { verifier, challenge } = await createPkceChallenge();
    expect(verifier).toMatch(/^[A-Za-z0-9\-._~]{43,128}$/);
    expect(challenge).toMatch(/^[A-Za-z0-9\-_]+$/); // base64url, no padding
    expect(challenge).not.toContain("=");
  });

  it("generates unique random state strings", () => {
    const a = randomState();
    const b = randomState();
    expect(a).not.toBe(b);
    expect(a.length).toBeGreaterThanOrEqual(16);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test -- pkce`
Expected: FAIL — cannot find `../src/pkce.js`.

- [ ] **Step 3: Implement `src/pkce.ts`**

```ts
const UNRESERVED = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~";

function randomString(length: number): string {
  const bytes = new Uint8Array(length);
  crypto.getRandomValues(bytes);
  let out = "";
  for (const b of bytes) out += UNRESERVED[b % UNRESERVED.length];
  return out;
}

function base64UrlEncode(bytes: ArrayBuffer): string {
  const arr = new Uint8Array(bytes);
  let binary = "";
  for (const b of arr) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export async function createPkceChallenge(): Promise<{ verifier: string; challenge: string }> {
  const verifier = randomString(64);
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
  return { verifier, challenge: base64UrlEncode(digest) };
}

export function randomState(): string {
  return randomString(32);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npm test -- pkce`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add clients/typescript/src/pkce.ts clients/typescript/test/pkce.test.ts
git commit -m "feat(ts-sdk): PKCE challenge + random state helpers"
```

---

## Task 8: Transport core (URL, headers, body, error mapping)

**Files:**
- Create: `clients/typescript/src/transport.ts`
- Test: `clients/typescript/test/transport.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
import { describe, it, expect, vi } from "vitest";
import { Transport } from "../src/transport.js";
import { MemoryAuthStore } from "../src/auth-store.js";
import { isZigbaseError } from "../src/errors.js";

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function makeTransport(fetchImpl: typeof fetch, authStore = new MemoryAuthStore()) {
  return new Transport({
    baseUrl: "http://api.test",
    authStore,
    fetch: fetchImpl,
    autoRefresh: false,
    maxRetries: 0,
    sleep: async () => {},
  });
}

describe("Transport", () => {
  it("builds URL with query params and parses JSON", async () => {
    const fetchMock = vi.fn(async (url: string) => {
      expect(url).toBe("http://api.test/api/collections/posts/records?page=2&perPage=10");
      return jsonResponse({ items: [], page: 2 });
    }) as unknown as typeof fetch;
    const t = makeTransport(fetchMock);
    const out = await t.send<{ page: number }>("/api/collections/posts/records", {
      query: { page: 2, perPage: 10, expand: undefined },
    });
    expect(out.page).toBe(2);
  });

  it("attaches Bearer header when authenticated", async () => {
    const store = new MemoryAuthStore();
    store.save("tok.tok.tok", { id: "u1" });
    const fetchMock = vi.fn(async (_url: string, init: RequestInit) => {
      const headers = new Headers(init.headers);
      expect(headers.get("Authorization")).toBe("Bearer tok.tok.tok");
      return jsonResponse({ ok: true });
    }) as unknown as typeof fetch;
    await makeTransport(fetchMock, store).send("/api/health");
  });

  it("serializes a JSON body and sets content-type", async () => {
    const fetchMock = vi.fn(async (_url: string, init: RequestInit) => {
      const headers = new Headers(init.headers);
      expect(headers.get("content-type")).toContain("application/json");
      expect(init.body).toBe(JSON.stringify({ title: "hi" }));
      return jsonResponse({ id: "1" }, 201);
    }) as unknown as typeof fetch;
    await makeTransport(fetchMock).send("/api/collections/posts/records", {
      method: "POST",
      body: { title: "hi" },
    });
  });

  it("passes FormData through without a JSON content-type", async () => {
    const fd = new FormData();
    fd.set("title", "hi");
    const fetchMock = vi.fn(async (_url: string, init: RequestInit) => {
      const headers = new Headers(init.headers);
      expect(headers.get("content-type")).toBeNull();
      expect(init.body).toBe(fd);
      return jsonResponse({ id: "1" }, 201);
    }) as unknown as typeof fetch;
    await makeTransport(fetchMock).send("/api/collections/posts/records", {
      method: "POST",
      body: fd,
    });
  });

  it("returns undefined for 204 responses", async () => {
    const fetchMock = vi.fn(async () => new Response(null, { status: 204 })) as unknown as typeof fetch;
    const out = await makeTransport(fetchMock).send("/api/collections/posts/records/1", {
      method: "DELETE",
    });
    expect(out).toBeUndefined();
  });

  it("throws ZigbaseError on non-2xx", async () => {
    const fetchMock = vi.fn(async () =>
      jsonResponse({ code: 403, message: "Nope.", data: {} }, 403),
    ) as unknown as typeof fetch;
    await expect(makeTransport(fetchMock).send("/api/x")).rejects.toSatisfy(isZigbaseError);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test -- transport`
Expected: FAIL — cannot find `../src/transport.js`.

- [ ] **Step 3: Implement `src/transport.ts`**

```ts
import type { AuthStore } from "./auth-store.js";
import { parseErrorResponse } from "./errors.js";

export type QueryValue = string | number | boolean | undefined | null;

export interface RequestOptions {
  method?: string;
  query?: Record<string, QueryValue>;
  body?: unknown;
  headers?: Record<string, string>;
  signal?: AbortSignal;
  skipAuth?: boolean;
}

export interface TransportConfig {
  baseUrl: string;
  authStore: AuthStore;
  fetch: typeof fetch;
  autoRefresh: boolean;
  maxRetries: number;
  lang?: string;
  refresh?: () => Promise<void>;
  sleep?: (ms: number) => Promise<void>;
}

const defaultSleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

export class Transport {
  constructor(private readonly cfg: TransportConfig) {}

  buildUrl(path: string, query?: Record<string, QueryValue>): string {
    const base = this.cfg.baseUrl.replace(/\/+$/, "");
    let url = path.startsWith("http") ? path : base + path;
    if (query) {
      const params = new URLSearchParams();
      for (const [k, v] of Object.entries(query)) {
        if (v === undefined || v === null) continue;
        params.set(k, String(v));
      }
      const qs = params.toString();
      if (qs) url += (url.includes("?") ? "&" : "?") + qs;
    }
    return url;
  }

  async send<T>(path: string, opts: RequestOptions = {}): Promise<T> {
    const url = this.buildUrl(path, opts.query);
    const isForm = typeof FormData !== "undefined" && opts.body instanceof FormData;
    let didRefresh = false;
    let attempt = 0;

    for (;;) {
      const headers = new Headers(opts.headers);
      if (!opts.skipAuth && this.cfg.authStore.token) {
        headers.set("Authorization", `Bearer ${this.cfg.authStore.token}`);
      }
      if (this.cfg.lang) headers.set("Accept-Language", this.cfg.lang);

      let body: BodyInit | undefined;
      if (opts.body !== undefined && opts.method && opts.method !== "GET") {
        if (isForm) {
          body = opts.body as FormData;
        } else {
          headers.set("Content-Type", "application/json");
          body = JSON.stringify(opts.body);
        }
      }

      const res = await this.cfg.fetch(url, {
        method: opts.method ?? "GET",
        headers,
        body,
        signal: opts.signal,
      });

      if (res.ok) {
        if (res.status === 204) return undefined as T;
        const text = await res.text();
        return (text ? JSON.parse(text) : undefined) as T;
      }

      // One-shot auto-refresh on 401.
      if (res.status === 401 && this.cfg.autoRefresh && this.cfg.refresh && !didRefresh && !opts.skipAuth) {
        didRefresh = true;
        try {
          await this.cfg.refresh();
          continue;
        } catch {
          // fall through to error
        }
      }

      // 429 backoff.
      if (res.status === 429 && attempt < this.cfg.maxRetries) {
        const retryAfter = Number(res.headers.get("Retry-After"));
        const delay = Number.isFinite(retryAfter) && retryAfter > 0
          ? retryAfter * 1000
          : 2 ** attempt * 200;
        attempt += 1;
        await (this.cfg.sleep ?? defaultSleep)(delay);
        continue;
      }

      throw await parseErrorResponse(res, url);
    }
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npm test -- transport`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add clients/typescript/src/transport.ts clients/typescript/test/transport.test.ts
git commit -m "feat(ts-sdk): fetch transport (url/headers/body/error mapping)"
```

---

## Task 9: Transport retries (429 backoff + auto-refresh)

**Files:**
- Test: `clients/typescript/test/transport-retry.test.ts`

(Implementation already exists from Task 8; this task locks the retry behavior under test.)

- [ ] **Step 1: Write the failing test**

```ts
import { describe, it, expect, vi } from "vitest";
import { Transport } from "../src/transport.js";
import { MemoryAuthStore } from "../src/auth-store.js";

function jsonResponse(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...headers },
  });
}

describe("Transport retries", () => {
  it("retries 429 up to maxRetries then succeeds", async () => {
    let calls = 0;
    const fetchMock = vi.fn(async () => {
      calls += 1;
      if (calls <= 2) return jsonResponse({ code: 429, message: "slow down" }, 429, { "Retry-After": "0" });
      return jsonResponse({ ok: true });
    }) as unknown as typeof fetch;
    const t = new Transport({
      baseUrl: "http://api.test",
      authStore: new MemoryAuthStore(),
      fetch: fetchMock,
      autoRefresh: false,
      maxRetries: 3,
      sleep: async () => {},
    });
    const out = await t.send<{ ok: boolean }>("/api/x");
    expect(out.ok).toBe(true);
    expect(calls).toBe(3);
  });

  it("performs a one-shot refresh on 401 then retries", async () => {
    const store = new MemoryAuthStore();
    store.save("old.tok.tok", { id: "u1" });
    let calls = 0;
    const fetchMock = vi.fn(async () => {
      calls += 1;
      if (calls === 1) return jsonResponse({ code: 401, message: "expired" }, 401);
      return jsonResponse({ ok: true });
    }) as unknown as typeof fetch;
    const refresh = vi.fn(async () => {
      store.save("new.tok.tok", { id: "u1" });
    });
    const t = new Transport({
      baseUrl: "http://api.test",
      authStore: store,
      fetch: fetchMock,
      autoRefresh: true,
      maxRetries: 0,
      refresh,
      sleep: async () => {},
    });
    const out = await t.send<{ ok: boolean }>("/api/x");
    expect(out.ok).toBe(true);
    expect(refresh).toHaveBeenCalledTimes(1);
    expect(calls).toBe(2);
  });
});
```

- [ ] **Step 2: Run test to verify it passes**

Run: `npm test -- transport-retry`
Expected: PASS (2 tests). (The implementation from Task 8 already supports this.)

- [ ] **Step 3: Commit**

```bash
git add clients/typescript/test/transport-retry.test.ts
git commit -m "test(ts-sdk): lock 429 backoff + auto-refresh transport behavior"
```

---

## Task 10: Client core + CollectionService skeleton + send()

**Files:**
- Create: `clients/typescript/src/collection.ts`
- Create: `clients/typescript/src/client.ts`
- Modify: `clients/typescript/src/index.ts`
- Test: `clients/typescript/test/client.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
import { describe, it, expect, vi } from "vitest";
import { createClient } from "../src/index.js";
import { MemoryAuthStore } from "../src/index.js";

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

describe("createClient", () => {
  it("exposes baseUrl, authStore, collection(), and send()", async () => {
    const fetchMock = vi.fn(async (url: string) => {
      expect(url).toBe("http://api.test/api/health");
      return jsonResponse({ status: "ok" });
    }) as unknown as typeof fetch;

    const zb = createClient("http://api.test/", { fetch: fetchMock });
    expect(zb.baseUrl).toBe("http://api.test");
    expect(zb.authStore).toBeInstanceOf(MemoryAuthStore);
    expect(typeof zb.collection).toBe("function");

    const health = await zb.send<{ status: string }>("GET", "/api/health");
    expect(health.status).toBe("ok");
  });

  it("returns a CollectionService from collection()", () => {
    const zb = createClient("http://api.test", { fetch: (async () => new Response()) as unknown as typeof fetch });
    const posts = zb.collection("posts");
    expect(typeof posts.authWithPassword).toBe("function");
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test -- client`
Expected: FAIL — `createClient` not exported.

- [ ] **Step 3: Implement `src/collection.ts` (skeleton; auth methods land in Task 11)**

```ts
import type { Transport } from "./transport.js";
import type { AuthStore } from "./auth-store.js";

export class CollectionService {
  constructor(
    protected readonly transport: Transport,
    protected readonly authStore: AuthStore,
    readonly name: string,
  ) {}

  protected base(): string {
    return `/api/collections/${encodeURIComponent(this.name)}`;
  }
}
```

- [ ] **Step 4: Implement `src/client.ts`**

```ts
import { Transport } from "./transport.js";
import { MemoryAuthStore, type AuthStore } from "./auth-store.js";
import { CollectionService } from "./collection.js";

export interface ClientOptions {
  authStore?: AuthStore;
  autoRefresh?: boolean;
  fetch?: typeof fetch;
  WebSocket?: typeof WebSocket;
  lang?: string;
  maxRetries?: number;
}

export interface Client {
  readonly baseUrl: string;
  readonly authStore: AuthStore;
  collection(name: string): CollectionService;
  send<T>(method: string, path: string, opts?: { query?: Record<string, string | number | boolean | undefined>; body?: unknown; headers?: Record<string, string>; signal?: AbortSignal }): Promise<T>;
}

export function createClient(baseUrl: string, opts: ClientOptions = {}): Client {
  const authStore = opts.authStore ?? new MemoryAuthStore();
  const normalizedBase = baseUrl.replace(/\/+$/, "");
  const fetchImpl = opts.fetch ?? globalThis.fetch;
  if (!fetchImpl) throw new Error("No fetch implementation available; pass options.fetch");

  const transport = new Transport({
    baseUrl: normalizedBase,
    authStore,
    fetch: fetchImpl,
    autoRefresh: opts.autoRefresh ?? false,
    maxRetries: opts.maxRetries ?? 3,
    lang: opts.lang,
  });

  return {
    baseUrl: normalizedBase,
    authStore,
    collection(name: string) {
      return new CollectionService(transport, authStore, name);
    },
    send<T>(method, path, sendOpts) {
      return transport.send<T>(path, { method, ...sendOpts });
    },
  };
}
```

- [ ] **Step 5: Update `src/index.ts`**

```ts
export const VERSION = "0.0.0";

export { createClient } from "./client.js";
export type { Client, ClientOptions } from "./client.js";
export { CollectionService } from "./collection.js";
export {
  BaseAuthStore,
  MemoryAuthStore,
  LocalAuthStore,
  CookieAuthStore,
} from "./auth-store.js";
export type { AuthStore, AuthRecord, AuthChangeListener } from "./auth-store.js";
export { ZigbaseError, isZigbaseError } from "./errors.js";
export type { FieldError } from "./errors.js";
export { decodeJwtPayload, isTokenExpired } from "./jwt.js";
export { createPkceChallenge, randomState } from "./pkce.js";
```

Note: the smoke test from Task 1 still imports `VERSION`; keep it exported.

- [ ] **Step 6: Run test to verify it passes**

Run: `npm test -- client`
Expected: PASS (2 tests). (`authWithPassword` is added in Task 11; if running before Task 11, temporarily assert `posts.name === "posts"` instead — but execute tasks in order so it passes after Task 11. To keep this task green now, the second test asserts the method exists, so implement the auth stub in Task 11 immediately after. If you need this task green in isolation, change the assertion to `expect(posts.name).toBe("posts")`.)

- [ ] **Step 7: Commit**

```bash
git add clients/typescript/src/collection.ts clients/typescript/src/client.ts clients/typescript/src/index.ts clients/typescript/test/client.test.ts
git commit -m "feat(ts-sdk): client core + CollectionService skeleton + send()"
```

---

## Task 11: Auth service methods

**Files:**
- Modify: `clients/typescript/src/collection.ts`
- Test: `clients/typescript/test/auth.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
import { describe, it, expect, vi } from "vitest";
import { createClient } from "../src/index.js";

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function makeJwt(payload: Record<string, unknown>): string {
  const b64url = (o: unknown) => Buffer.from(JSON.stringify(o)).toString("base64url");
  return `${b64url({ alg: "HS256" })}.${b64url(payload)}.sig`;
}

describe("auth service", () => {
  it("authWithPassword posts identity+password and stores token+record", async () => {
    const token = makeJwt({ id: "u1", exp: Math.floor(Date.now() / 1000) + 3600 });
    const fetchMock = vi.fn(async (url: string, init: RequestInit) => {
      expect(url).toBe("http://api.test/api/collections/users/auth-with-password");
      expect(init.method).toBe("POST");
      expect(JSON.parse(init.body as string)).toEqual({ identity: "a@b.c", password: "pw" });
      return jsonResponse({ token, record: { id: "u1", email: "a@b.c" } });
    }) as unknown as typeof fetch;

    const zb = createClient("http://api.test", { fetch: fetchMock });
    const out = await zb.collection("users").authWithPassword("a@b.c", "pw");
    expect(out.token).toBe(token);
    expect(zb.authStore.token).toBe(token);
    expect(zb.authStore.record?.id).toBe("u1");
    expect(zb.authStore.isValid).toBe(true);
  });

  it("logout clears the auth store", async () => {
    const fetchMock = vi.fn(async () => new Response(null, { status: 204 })) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    zb.authStore.save("x.y.z", { id: "u1" });
    await zb.collection("users").logout();
    expect(zb.authStore.token).toBeNull();
  });

  it("listAuthProviders fetches provider metadata", async () => {
    const fetchMock = vi.fn(async (url: string) => {
      expect(url).toBe("http://api.test/api/collections/users/oauth2-providers");
      return jsonResponse({ providers: [{ name: "google", authURL: "https://g", clientId: "cid" }] });
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    const out = await zb.collection("users").listAuthProviders();
    expect(out.providers[0]?.name).toBe("google");
  });

  it("requestPasswordReset posts email and returns void", async () => {
    const fetchMock = vi.fn(async (url: string, init: RequestInit) => {
      expect(url).toBe("http://api.test/api/collections/users/request-password-reset");
      expect(JSON.parse(init.body as string)).toEqual({ email: "a@b.c" });
      return new Response(null, { status: 204 });
    }) as unknown as typeof fetch;
    const zb = createClient("http://api.test", { fetch: fetchMock });
    await expect(zb.collection("users").requestPasswordReset("a@b.c")).resolves.toBeUndefined();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test -- auth.test`
Expected: FAIL — `authWithPassword` is not a function.

- [ ] **Step 3: Add auth methods to `src/collection.ts`**

Replace the file with:

```ts
import type { Transport } from "./transport.js";
import type { AuthStore, AuthRecord } from "./auth-store.js";

export interface AuthResponse {
  token: string;
  record: AuthRecord;
  meta?: Record<string, unknown>;
}

export interface OAuth2Provider {
  name: string;
  authURL?: string;
  clientId?: string;
  scopes?: string[];
}

export interface OAuth2Args {
  provider: string;
  code: string;
  codeVerifier: string;
  redirectUrl: string;
  state?: string;
}

export class CollectionService {
  constructor(
    protected readonly transport: Transport,
    protected readonly authStore: AuthStore,
    readonly name: string,
  ) {}

  protected base(): string {
    return `/api/collections/${encodeURIComponent(this.name)}`;
  }

  private async authRequest(path: string, body: unknown): Promise<AuthResponse> {
    const res = await this.transport.send<AuthResponse>(`${this.base()}${path}`, {
      method: "POST",
      body,
      skipAuth: path === "/auth-with-password" || path === "/auth-with-oauth2",
    });
    this.authStore.save(res.token, res.record);
    return res;
  }

  authWithPassword(identity: string, password: string): Promise<AuthResponse> {
    return this.authRequest("/auth-with-password", { identity, password });
  }

  authRefresh(): Promise<AuthResponse> {
    return this.authRequest("/auth-refresh", {});
  }

  authWithOAuth2(args: OAuth2Args): Promise<AuthResponse> {
    return this.authRequest("/auth-with-oauth2", args);
  }

  async logout(): Promise<void> {
    try {
      await this.transport.send<void>(`${this.base()}/auth-logout`, { method: "POST" });
    } finally {
      this.authStore.clear();
    }
  }

  listAuthProviders(): Promise<{ providers: OAuth2Provider[] }> {
    return this.transport.send(`${this.base()}/oauth2-providers`, { method: "GET" });
  }

  oauth2Init(provider: string): Promise<{ state: string }> {
    return this.transport.send(`${this.base()}/oauth2-init`, {
      method: "POST",
      body: { provider },
    });
  }

  requestVerification(email: string): Promise<void> {
    return this.transport.send(`${this.base()}/request-verification`, {
      method: "POST",
      body: { email },
    });
  }

  confirmVerification(token: string): Promise<{ verified: boolean }> {
    return this.transport.send(`${this.base()}/confirm-verification`, {
      method: "POST",
      body: { token },
      skipAuth: true,
    });
  }

  requestPasswordReset(email: string): Promise<void> {
    return this.transport.send(`${this.base()}/request-password-reset`, {
      method: "POST",
      body: { email },
    });
  }

  confirmPasswordReset(token: string, password: string): Promise<{ success: boolean }> {
    return this.transport.send(`${this.base()}/confirm-password-reset`, {
      method: "POST",
      body: { token, password },
      skipAuth: true,
    });
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npm test -- auth.test`
Expected: PASS (4 tests). Also re-run `npm test -- client` — Task 10's `authWithPassword` assertion now passes.

- [ ] **Step 5: Wire `autoRefresh` to the auth refresh path**

In `src/client.ts`, after constructing `transport`, set the refresh hook so a default auth collection can refresh. Since the refresh collection is app-specific, expose it via options. Add to `ClientOptions`:

```ts
  /** Collection used for automatic token refresh on 401 (e.g. "users"). */
  authCollection?: string;
```

And in `createClient`, replace the `Transport` construction with a mutable config that wires `refresh`:

```ts
  const transport = new Transport({
    baseUrl: normalizedBase,
    authStore,
    fetch: fetchImpl,
    autoRefresh: opts.autoRefresh ?? false,
    maxRetries: opts.maxRetries ?? 3,
    lang: opts.lang,
    refresh: opts.authCollection
      ? async () => {
          await new CollectionService(transport, authStore, opts.authCollection!).authRefresh();
        }
      : undefined,
  });
```

Note: `transport` is referenced inside its own initializer via the closure; declare it with `let` and assign, or construct the `CollectionService` lazily. Use this shape:

```ts
  let transport!: Transport;
  transport = new Transport({
    baseUrl: normalizedBase,
    authStore,
    fetch: fetchImpl,
    autoRefresh: opts.autoRefresh ?? false,
    maxRetries: opts.maxRetries ?? 3,
    lang: opts.lang,
    refresh: opts.authCollection
      ? async () => {
          await new CollectionService(transport, authStore, opts.authCollection!).authRefresh();
        }
      : undefined,
  });
```

- [ ] **Step 6: Run the full unit suite**

Run: `npm test`
Expected: all unit tests PASS.

- [ ] **Step 7: Commit**

```bash
git add clients/typescript/src/collection.ts clients/typescript/src/client.ts clients/typescript/test/auth.test.ts
git commit -m "feat(ts-sdk): auth service (password/refresh/oauth2/verify/reset/logout)"
```

---

## Task 12: Integration harness + live-backend auth test

**Files:**
- Create: `clients/typescript/test/integration/harness.ts`
- Create: `clients/typescript/vitest.integration.config.ts`
- Create: `clients/typescript/test/integration/auth.integration.test.ts`

- [ ] **Step 1: Create `vitest.integration.config.ts`**

```ts
import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["test/integration/**/*.integration.test.ts"],
    environment: "node",
    testTimeout: 60_000,
    hookTimeout: 120_000,
    pool: "forks",
    fileParallelism: false,
  },
});
```

- [ ] **Step 2: Create the harness `test/integration/harness.ts`**

```ts
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const REPO_ROOT = resolve(__dirname, "../../../..");
const BIN = join(REPO_ROOT, "zig-out", "bin", "zigbase");

export interface TestServer {
  url: string;
  superuser: { email: string; password: string };
  stop(): void;
}

let built = false;
function ensureBuilt(): void {
  if (built) return;
  const r = spawnSync("zig", ["build"], { cwd: REPO_ROOT, stdio: "inherit" });
  if (r.status !== 0) throw new Error("zig build failed");
  built = true;
}

async function waitForHealth(url: string, timeoutMs = 20_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    try {
      const res = await fetch(`${url}/api/health`);
      if (res.ok) return;
    } catch {
      // not up yet
    }
    if (Date.now() > deadline) throw new Error("server did not become healthy");
    await new Promise((r) => setTimeout(r, 200));
  }
}

export async function startServer(): Promise<TestServer> {
  ensureBuilt();
  const dataDir = mkdtempSync(join(tmpdir(), "zb-it-"));
  const port = 20000 + Math.floor(Math.random() * 20000);
  const email = "admin@test.local";
  const password = "test-password-123";

  const su = spawnSync(
    BIN,
    ["superuser", "create", "--email", email, "--password", password, "--data-dir", dataDir],
    { stdio: "inherit" },
  );
  if (su.status !== 0) throw new Error("superuser create failed");

  const proc: ChildProcess = spawn(
    BIN,
    ["serve", "--http-port", String(port), "--data-dir", dataDir, "--insecure-cookies"],
    { stdio: "inherit" },
  );

  const url = `http://127.0.0.1:${port}`;
  await waitForHealth(url);

  return {
    url,
    superuser: { email, password },
    stop() {
      proc.kill("SIGTERM");
      try { rmSync(dataDir, { recursive: true, force: true }); } catch { /* ignore */ }
    },
  };
}

/** Authenticate as the superuser and return the bearer token. */
export async function superuserToken(server: TestServer): Promise<string> {
  const res = await fetch(`${server.url}/api/collections/_superusers/auth-with-password`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ identity: server.superuser.email, password: server.superuser.password }),
  });
  if (!res.ok) throw new Error(`superuser auth failed: ${res.status}`);
  return ((await res.json()) as { token: string }).token;
}

/** Create a collection via the superuser collections API. */
export async function createCollection(
  server: TestServer,
  token: string,
  definition: Record<string, unknown>,
): Promise<void> {
  const res = await fetch(`${server.url}/api/collections`, {
    method: "POST",
    headers: { "content-type": "application/json", Authorization: `Bearer ${token}` },
    body: JSON.stringify(definition),
  });
  if (!res.ok) throw new Error(`create collection failed: ${res.status} ${await res.text()}`);
}
```

Note on `__dirname`: with `verbatimModuleSyntax` + ESM, vitest provides `__dirname` in the Node/forks pool via its CJS interop. If it is undefined in your environment, replace the first two lines with:

```ts
import { fileURLToPath } from "node:url";
const REPO_ROOT = resolve(fileURLToPath(new URL(".", import.meta.url)), "../../../..");
```

- [ ] **Step 3: Write the integration test `test/integration/auth.integration.test.ts`**

```ts
import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { startServer, superuserToken, createCollection, type TestServer } from "./harness.js";
import { createClient } from "../../src/index.js";

let server: TestServer;

beforeAll(async () => {
  server = await startServer();
  const token = await superuserToken(server);
  await createCollection(server, token, {
    name: "members",
    type: "auth",
    fields: [{ name: "name", type: "text" }],
    createRule: "",        // allow public signup for the test
    listRule: "",
    viewRule: "",
  });
});

afterAll(() => server?.stop());

describe("auth (live backend)", () => {
  it("registers, logs in, and refreshes a real session", async () => {
    const su = await superuserToken(server);
    // Create a member record (as superuser) with a password.
    await createCollection; // no-op import guard
    const createRes = await fetch(`${server.url}/api/collections/members/records`, {
      method: "POST",
      headers: { "content-type": "application/json", Authorization: `Bearer ${su}` },
      body: JSON.stringify({ email: "m@test.local", password: "member-pass-1", passwordConfirm: "member-pass-1", name: "Mem" }),
    });
    expect(createRes.ok).toBe(true);

    const zb = createClient(server.url);
    const auth = await zb.collection("members").authWithPassword("m@test.local", "member-pass-1");
    expect(auth.token.length).toBeGreaterThan(0);
    expect(zb.authStore.isValid).toBe(true);

    const refreshed = await zb.collection("members").authRefresh();
    expect(refreshed.token.length).toBeGreaterThan(0);

    await zb.collection("members").logout();
    expect(zb.authStore.token).toBeNull();
  });

  it("surfaces a ZigbaseError on bad credentials", async () => {
    const zb = createClient(server.url);
    await expect(
      zb.collection("members").authWithPassword("m@test.local", "wrong"),
    ).rejects.toMatchObject({ status: expect.any(Number) });
  });
});
```

Note: confirm the exact auth-collection record-creation field names (`password`/`passwordConfirm`) against `src/api/records.zig` / `src/api/auth.zig` during execution; adjust the create body if the server expects different keys. The test's contract (login → refresh → logout, and error on bad creds) stays the same.

- [ ] **Step 4: Run the integration test**

Run: `cd clients/typescript && npm run test:integration`
Expected: PASS (2 tests) against a freshly built+launched `zigbase`.

- [ ] **Step 5: Commit**

```bash
git add clients/typescript/test/integration clients/typescript/vitest.integration.config.ts
git commit -m "test(ts-sdk): integration harness + live-backend auth flow"
```

---

## Task 13: CI job + package README

**Files:**
- Modify: `.github/workflows/ci.yml`
- Create: `clients/typescript/README.md`

- [ ] **Step 1: Inspect the existing CI file**

Run: `sed -n '1,80p' .github/workflows/ci.yml`
Expected: see existing job names + how the Zig toolchain is set up (reuse that setup for the SDK job).

- [ ] **Step 2: Add a `ts-sdk` job to `.github/workflows/ci.yml`**

Append a job mirroring the repo's existing Zig setup (adapt the Zig install step to match what the other jobs use):

```yaml
  ts-sdk:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: mlugg/setup-zig@v1
        with:
          version: 0.15.2
      - uses: actions/setup-node@v4
        with:
          node-version: 20
      - name: Build zigbase binary
        run: zig build
      - name: Install SDK deps
        working-directory: clients/typescript
        run: npm ci || npm install
      - name: Typecheck
        working-directory: clients/typescript
        run: npm run typecheck
      - name: Unit tests
        working-directory: clients/typescript
        run: npm test
      - name: Integration tests
        working-directory: clients/typescript
        run: npm run test:integration
```

Match the Zig install action/version to whatever the existing jobs in `ci.yml` use; do not introduce a different toolchain step.

- [ ] **Step 3: Create `clients/typescript/README.md`**

```markdown
# @zigbase/client

Official TypeScript client for [ZigBase](../../README.md). Zero dependencies; runs in
browsers, Node 18+, Bun, Deno, and edge runtimes.

## Install

```bash
npm install @zigbase/client
```

## Quick start

```ts
import { createClient } from "@zigbase/client";

const zb = createClient("http://127.0.0.1:8090");

// Authenticate
await zb.collection("users").authWithPassword("you@example.com", "secret");

// Call any endpoint
const health = await zb.send("GET", "/api/health");
```

## Auth stores

- `MemoryAuthStore` (default, SSR-safe)
- `LocalAuthStore` (browser `localStorage`)
- `CookieAuthStore` (SSR token handoff)

```ts
import { createClient, LocalAuthStore } from "@zigbase/client";
const zb = createClient(url, { authStore: new LocalAuthStore() });
```

Records, pagination, file uploads, and realtime arrive in subsequent releases
(see the SDK plans under `docs/superpowers/plans/`).
```

- [ ] **Step 4: Verify the build and typecheck**

Run: `cd clients/typescript && npm run typecheck && npm run build`
Expected: typecheck clean; `dist/` produced with `.js`, `.cjs`, `.d.ts`.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/ci.yml clients/typescript/README.md
git commit -m "ci(ts-sdk): add build+test job; docs: package README"
```

---

## Self-Review notes (already applied)

- **Spec coverage:** transport/Bearer/errors/429/auto-refresh (Tasks 8–9), AuthStore trio + JWT exp (Tasks 3–6), client surface + `send()` (Task 10), full auth method set incl. OAuth2/PKCE primitives (Tasks 7, 11), zero-dep + ESM/CJS + tree-shakeable scaffold (Task 1), two-tier testing incl. real-binary integration (Task 12), CI job + README sync (Task 13). Records, cursors, files, realtime, and the live store are explicitly Plan 2 / Plan 3 and out of scope here.
- **Type consistency:** `AuthResponse`, `CollectionService`, `Transport`, `AuthStore`, `ClientOptions` names are used identically across tasks. `authWithPassword/authRefresh/authWithOAuth2/logout/listAuthProviders/oauth2Init/requestVerification/confirmVerification/requestPasswordReset/confirmPasswordReset` are the stable method names.
- **Open execution-time confirmations (flagged inline, contract unchanged):** exact auth record-creation field names for the integration seed (Task 12 Step 3); the Zig install action/version already used by `ci.yml` (Task 13 Step 2).
```
