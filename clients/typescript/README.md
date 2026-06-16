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
