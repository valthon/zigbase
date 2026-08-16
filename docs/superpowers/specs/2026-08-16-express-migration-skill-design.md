# Node.js/Express migration skill — design

**Date:** 2026-08-16
**Status:** Approved by the AI-agents program for implementation
**Program:** [ZigBase AI-Agents Program](2026-08-08-ai-agents-program-design.md), migration family
**Baseline:** `codex/sp4-foundation` @ `11fc6227`

## 1. Goal

Ship the second official migration-family skill: discovery-driven re-platforming of a Node.js
Express service onto ZigBase. Unlike PocketBase, Express has no canonical schema, routing,
middleware, auth, persistence, or file convention. The skill must make that ambiguity explicit,
produce durable inventory and endpoint-parity artifacts, and reuse ZigBase's existing schema,
import, legacy-bcrypt, OpenAPI, and replay machinery.

## 2. Support boundary

The workflow supports an inspectable Express source repository, its locked dependencies, a
recoverable database snapshot/export, and representative HTTP behavior. It does not claim an
automatic source-to-source translation or accept route listings as proof that middleware and
business behavior were preserved.

Discovery covers nested routers, mount prefixes, middleware order, validation, ORM/query access,
raw SQL, sessions/JWT/passport strategies, jobs, uploads, outbound integrations, error handling,
proxy/CORS/cookie assumptions, and client-consumed response shapes. Dynamic route construction or
runtime registration becomes a blocker or a durable manual inventory item, never a silent omission.

## 3. Workflow

The skill freezes source inputs, creates versioned inventory and decision artifacts, maps source
tables to ZigBase collections, extracts deterministic NDJSON using source-aware code, ports trusted
behavior into rules/hooks/routes/jobs, records source requests, and replays them against the target.

Only bcrypt credentials use ZigBase's legacy-hash import. Other password formats require a reviewed
reset or separately implemented security boundary. Source sessions and tokens never migrate.

## 4. Verification

The skill is a concise workflow over byte-synced canonical Express, migration-tools, OpenAPI,
serve, deployment, Docker, and agent references. Strict tests reject drift, malformed packaging,
or unexpected Markdown. A public guide documents the honest discovery boundary and cutover report.

This subproject does not modify a user's source service, deploy infrastructure, or invent a generic
Express parser. It packages the judgment-heavy workflow that the program design explicitly assigns
to the migration skill.
