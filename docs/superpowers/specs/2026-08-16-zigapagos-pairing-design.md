# Zigapagos + ZigBase pairing — design

**Date:** 2026-08-16
**Status:** Approved by the AI-agents program for implementation
**Program:** [ZigBase AI-Agents Program](2026-08-08-ai-agents-program-design.md), SP-6
**Baseline:** `codex/sp4-foundation` @ `43b46010`

## 1. Goal

Ship one official, distributable Agent Skill for building a ZigBase framework application with a
Zigapagos frontend. The pairing must preserve each product's standalone use: ZigBase owns API,
auth, policy, data, and server behavior; Zigapagos owns pages, islands, frontend assets, and static
site checks. Their deliberate seam is a same-origin release served by the application's ZigBase
binary.

The repository's Blog example remains the executable reference application. The new skill turns
its proven architecture into a reusable workflow instead of copying a second starter that would
drift.

## 2. Deliverables

- `docs/zigapagos-pairing.md`: canonical architecture, commands, test layers, deployment modes,
  and traps.
- `skills/zigbase-zigapagos-fullstack/`: concise workflow plus byte-synced canonical references.
- Strict structure, metadata, reference-drift, and mutation tests alongside the existing official
  skills.
- Discovery links from README, the agent entry guide, the public docs registry/sidebar/index, and
  a changelog fragment.

## 3. Architecture contract

The paired project has one origin and two build graphs:

```text
frontend/content + layouts + islands
        | zigapagos release
        v
frontend/dist --------------+
                             | static fallback
ZigBase collections/routes --+--> one application origin
```

API, admin, and custom routes win before static fallback. Frontend code uses relative `/api/...`
URLs, so production does not need CORS. Development builds the ZigBase application binary first,
then passes it to `zigapagos dev --zigbase=...`; release either serves `frontend/dist` from disk or
embeds it into the executable.

The skill must not imply that Zigapagos's stock ZigBase binary contains a consumer's comptime
collections, hooks, or routes. Any full-stack app with trusted Zig behavior uses its own built
binary for dev, E2E, doctor-adjacent checks, and deployment.

## 4. Workflow contract

The skill guides an agent through:

1. Define journeys and trust boundaries before choosing pages or schema.
2. Build one backend authorization slice with `zigbase.testing` allow/deny coverage.
3. Build one Zigapagos page/island journey against the same-origin API.
4. Run frontend validation, backend tests, SDK typecheck, transport E2E, and browser proof as
   distinct layers.
5. Generate OpenAPI for handoff and reconcile production doctor public-rule findings against
   `security/public-rules.json`.
6. Choose runtime-directory or embedded static assets deliberately and produce a reproducible
   deployment.

The skill delegates detailed ZigBase security, testing, and deployment facts to canonical copied
references. Pairing-specific commands and ownership rules live in the new canonical pairing doc.

## 5. Safety and failure rules

- Public signup is valid: intentional anonymous auth-record creation is a warning, not an
  inescapable doctor error, and is durably acknowledged in `security/public-rules.json`.
- Never move authorization into an island or page loader. The server rule/hook/route is the trust
  boundary; the frontend may only improve presentation.
- Never expose framework-only fields, secrets, or superuser credentials in generated frontend
  configuration.
- Do not treat `zigapagos validate`, `zig build test`, transport E2E, and browser tests as
  interchangeable.
- Agent-driven dev sessions auto-background. Foreground-owned test harnesses set
  `ZIGAPAGOS_DEV_BACKGROUND=0` and `ZIGBASE_SERVE_BACKGROUND=0` so teardown owns the real child.

## 6. Verification

The official skill validator rejects malformed frontmatter, stale UI metadata, unexpected
Markdown, missing references, and byte drift. Mutation tests prove each guard fails closed. The
Blog reference application proves the workflow through in-process Zig tests, TypeScript checks,
transport E2E, and a browser journey. The public site must publish and discover the new guide.

This deliverable does not publish packages, deploy infrastructure, or begin a Rails migration. SDK
registry publication remains an externally authorized release action; Rails remains gated by the
advanced migration integration named in the program design.
