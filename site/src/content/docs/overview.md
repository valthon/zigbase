---
title: Overview
description: What ZigBase is — a single-binary backend and an embeddable Zig framework — and when to reach for it.
order: 1
group: getting-started
---

# Overview

**ZigBase is a single-binary, open-source backend** — collections and schema, a typed
records query API, per-collection access rules, authentication (argon2id password plus
OAuth2 with PKCE), realtime updates over WebSocket, local file storage, and an embedded
admin UI — all in one statically-linked executable — embedded SQLite by default,
PostgreSQL opt-in — written in **Zig 0.16**.

It is PocketBase-*inspired* but **not** API-compatible.

> ZigBase is two things at once. Out of the box it is a backend you run as a binary. But
> it is also an **embeddable Zig framework**: import it as a library and extend the server
> with comptime record hooks, custom HTTP routes, scheduled jobs, a comptime schema, and
> pluggable storage/mailer backends. The framework angle is the differentiator.

## Backend-first, framework-second

There are two ways to use ZigBase:

1. **Run the binary.** Download a release (or build from source), create a superuser,
   point clients at the REST + WebSocket API, and manage data in the admin UI. No Zig
   required. → [Quick start](./quick-start)
2. **Build an app on it.** `zig fetch --save` ZigBase, `@import("zigbase")`, and configure
   `zigbase.App(.{...})` with your hooks, routes, and jobs. Your binary *is* the ZigBase
   server, plus your extensions. → [Framework](./framework)

## Features

- **Collections & schema** — define collections with typed fields; schema migrations run
  on startup.
- **Records & query API** — typed CRUD with `filter`, `sort`, and `expand` on relations.
  → [API](./api)
- **Access rules** — per-collection list / view / create / update / delete rules;
  blank = locked, `"@public"` = open.
  → [API](./api#access-rules)
- **Auth** — argon2id password, magic-link, OTP, and WebAuthn passkey auth. JWT tokens,
  verification, and password-reset flows. → [API](./api#auth)
- **OAuth2** — Authorization-Code + PKCE provider login and account linking.
  → [API](./api#oauth2)
- **Session management** — token-epoch revocation (`revokeAllSessions`), optional
  per-device session table (`listActiveSessions` / `revoke`), and auth lifecycle hooks
  (`beforeAuthSuccess`, `beforeRegister`). → [Framework](./framework)
- **Rate limiting** — global rate limiter plus per-auth-method limits; set each method's
  `.rate_limit` option at comptime, or call `ac.rateLimit()` from a custom auth method at
  runtime.
- **Field encryption** — mark any text/JSON field `encrypted` for AES-256-GCM at rest;
  rotate keys live with `zigbase rewrap`. → [Framework](./framework)
- **TTL / expiry** — declare `.ttl_field` on a collection and the framework GC's expired
  rows automatically every 5 minutes. → [Framework](./framework)
- **KV store & feature flags** — built-in key-value store (`ctx.kv` / `ctx.flag`)
  accessible from hooks and routes; managed in the admin Settings UI.
  → [Framework](./framework)
- **Ctx capability layer** — a single `*Ctx` passed to every hook, route, and job wraps
  records, auth, KV, flags, outbound HTTP, and atomic transactions; connection pooling
  is handled for you. → [Framework](./framework)
- **Realtime** — subscribe to record changes over WebSocket, broadcast on custom channels
  from routes and jobs; record-change delivery fans out across app instances on Postgres.
  → [Realtime broadcast](./realtime-broadcast)
- **PostgreSQL backend (opt-in)** — build with `-Dpostgres` and point `ZIGBASE_DB_URL` at a
  `postgres://` URL; `zigbase migrate-db` moves an existing SQLite instance across.
  → [PostgreSQL](./postgres)
- **Multi-tenancy** — account-scoped collections with built-in accounts, memberships,
  invitations, and roles; fail-closed. → [Multi-tenancy](./tenancy)
- **Relationship abilities** — authorize by the caller's relationship to the row,
  comptime-validated and fail-closed. → [Abilities](./abilities)
- **Full-text & vector search** — ranked `?search=` queries on `.searchable` fields;
  opt-in `-Dvector` KNN. → [Search](./search)
- **Product analytics** — immutable `ctx.track` events, declarative rollups, and a
  tenant-scoped read API. → [Analytics](./analytics)
- **Background jobs & queues** — durable or in-memory queues with priorities and retries;
  `ctx.enqueue` from anywhere. → [Jobs & webhooks](./jobs-and-webhooks)
- **Outbound webhooks** — signed, idempotent deliveries with retries and capped backoff.
  → [Jobs & webhooks](./jobs-and-webhooks)
- **CAPTCHA** — `ctx.verifyCaptcha` for reCAPTCHA, hCaptcha, and Turnstile.
  → [Recipes](./recipes#recipe-gate-a-public-form-with-captcha)
- **Files** — local (pluggable) file storage with serving and short-lived file-access
  tokens. → [API](./api#files)
- **Admin UI** — embedded single-page app served at `/_/`, including a Settings screen
  for managing KV/feature flags.
- **Framework** — comptime record hooks, custom routes, scheduled jobs, a comptime schema
  (with additive auto-migration), and pluggable storage/mailer backends. → [Framework](./framework)
- **Email** — transactional mail with multipart HTML+text templates, SES / Postmark / SMTP
  providers, verified per-account senders, and bounce suppression. → [Email](./email)
- **Deterministic testing** — freeze time (`ZIGBASE_FAKE_NOW`), fix randomness
  (`ZIGBASE_FAKE_SEED`), and capture outbound mail in test suites — all gated off in
  production builds.

## When to use ZigBase

ZigBase fits when you want a backend that ships as **one file** — embedded SQLite to
start, the same code on **PostgreSQL** when you outgrow one box — and either (a) gives
you a REST/realtime/auth surface with zero glue, or (b) lets you grow custom server logic
**in Zig** without standing up a separate service. The architecture favors a small
footprint: a warm reader-connection pool, a blocking-mutex writer, and comptime
"footprint levers" you can tune.

It is an **early release** (Apache-2.0). Read the
[known limitations](./known-limitations) before deploying — notably that SMTP must be
configured for email delivery in production, rate limiting ignores proxy-supplied client
IPs unless `--trust-proxy` is set, comptime auto-migration is additive-only, and the
scheduler is single-process, and the PostgreSQL backend is new in 0.9.0 (TLS is encrypted
but not yet certificate-verified).

## Where to go next

- **[Quick start](./quick-start)** — install, create a superuser, serve, hit the API.
- **[Tutorial](./tutorial)** — build a backend end to end (provision → rules → signup →
  records + file upload → custom route → cron).
- **[PostgreSQL](./postgres)** — take the same app to Postgres when you outgrow one box.
- **[Framework](./framework)** — the full hook / route / job / schema / plugin surface.
- **[API](./api)** — the REST + WebSocket reference.
