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
admin UI — all in one statically-linked executable backed by SQLite, written in **Zig
0.16**.

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
- **Access rules** — per-collection list / view / create / update / delete rules.
  → [API](./api#access-rules)
- **Auth** — argon2id password auth, JWT tokens, verification and password-reset flows.
  → [API](./api#auth)
- **OAuth2** — Authorization-Code + PKCE provider login and account linking.
  → [API](./api#oauth2)
- **Realtime** — subscribe to record changes over WebSocket. → [API](./api#realtime-websocket)
- **Files** — local file storage with serving and short-lived file-access tokens.
  → [API](./api#files)
- **Admin UI** — embedded single-page app served at `/_/`.
- **Framework** — comptime record hooks, custom routes, scheduled jobs, a comptime schema
  (with additive auto-migration), and pluggable storage/mailer backends. → [Framework](./framework)
- **Email** — pluggable SMTP mailer (STARTTLS / implicit TLS / plaintext) delivering
  verification and password-reset email; logs the tokens in dev when SMTP is unset.

## When to use ZigBase

ZigBase fits when you want a backend that ships as **one file**, runs on **SQLite**, and
either (a) gives you a REST/realtime/auth surface with zero glue, or (b) lets you grow
custom server logic **in Zig** without standing up a separate service. The architecture
favors a small footprint: a warm reader-connection pool, a blocking-mutex writer, and
comptime "footprint levers" you can tune.

It is an **early release** (Apache-2.0). Read the
[known limitations](./known-limitations) before deploying — notably that SMTP must be
configured for email delivery in production, rate limiting ignores proxy-supplied client
IPs unless `--trust-proxy` is set, comptime auto-migration is additive-only, and the
scheduler is single-process.

## Where to go next

- **[Quick start](./quick-start)** — install, create a superuser, serve, hit the API.
- **[Tutorial](./tutorial)** — build a backend end to end (provision → rules → signup →
  records + file upload → custom route → cron).
- **[Framework](./framework)** — the full hook / route / job / schema / plugin surface.
- **[API](./api)** — the REST + WebSocket reference.
