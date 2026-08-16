# Laravel and Go migration skills — design

**Date:** 2026-08-16
**Status:** Approved by the AI-agents program for implementation
**Program:** [ZigBase AI-Agents Program](2026-08-08-ai-agents-program-design.md), migration family
**Baseline:** `codex/sp4-foundation` @ `237b2fce`

## Goal

Complete the currently ungated migration-family instantiations with official Laravel and Go
web-service skills. Both reuse the proven inventory → schema → data/auth → endpoint map → replay →
cutover skeleton and ZigBase's existing machinery, while adding source-specific discovery traps.

Laravel discovery centers on effective routes, middleware groups, Form Requests, Eloquent/schema
migrations, policies/gates, guards/providers, Sanctum/Passport, queues/events, filesystem disks,
mail/notifications, casts/accessors, and exception rendering. Go discovery centers on router and
middleware composition across net/http and common routers, generated and handwritten database
access, transaction boundaries, goroutine/worker lifecycles, auth/token/password code, embedded or
external files, and error/JSON conventions.

Neither skill claims automatic translation. Each ships a canonical public guide, concise skill,
byte-synced references, strict mutation-tested packaging, discovery links, and changelog entry.
Only verified bcrypt hashes use legacy import; sessions and tokens never migrate. Rails remains
outside this subproject because the program explicitly gates it on advanced Zigapagos integration.
