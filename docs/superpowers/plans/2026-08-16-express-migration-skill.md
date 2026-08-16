# Node.js/Express migration skill — implementation plan

**Design:** [2026-08-16-express-migration-skill-design.md](../specs/2026-08-16-express-migration-skill-design.md)
**Program:** [2026-08-08-ai-agents-program-design.md](../specs/2026-08-08-ai-agents-program-design.md)
**Baseline:** `11fc6227`

## Task 1 — Publish the source-specific guide

- Define the supported evidence boundary and a discovery inventory for routers, middleware, data,
  auth, jobs, files, integrations, and wire behavior.
- Define durable schema/endpoint decisions, deterministic extraction, parity, cutover, and rollback.
- Name unsupported password/session behavior and dynamic-discovery blockers.

## Task 2 — Package the official skill

- Initialize `zigbase-migrate-express` with standard UI metadata.
- Encode the discovery-first migration skeleton and load source-specific/canonical references.
- Keep deterministic operations on existing ZigBase CLI/replay tools and judgment in the skill.

## Task 3 — Add fail-closed distribution

- Add exact reference-sync, structure, metadata, and mutation tests.
- Publish the guide through README, agent routing, site registry/navigation, and changelog.
- Commit design separately, then skill and discovery as coherent local checkpoints.

## Task 4 — Verify

- Run the standard skill validator, strict repository skill tests, Ruff, site build/doctor/static/
  generated/browser suite, and the broader relevant regression matrix.
- Re-audit Laravel and Go as the next source instantiations; keep Rails externally gated.
