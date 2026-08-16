# OpenAPI export — implementation plan

**Design:** [2026-08-15-openapi-export-design.md](../specs/2026-08-15-openapi-export-design.md)
**Program:** [2026-08-08-ai-agents-program-design.md](../specs/2026-08-08-ai-agents-program-design.md)
**Baseline:** `5b6d9f3f`

## Task 1 — Freeze the CLI and redacted route metadata

- Add `OpenApiArgs`, `Command.openapi`, and `HelpTopic.openapi`.
- Parse all value flags, reject missing/repeated/unknown values, and add focused parser tests.
- Add redacted path-secret and collection-auth metadata to `events.RouteMeta`; never carry secret
  values or backing-store keys.
- Thread `App.routes` into `runCliImpl` as a comptime argument.
- Add help and generated-command allowlist coverage.
- Commit: `feat: define OpenAPI export contract`.

## Task 2 — Generate collection schemas and CRUD paths

- Add `src/openapi.zig` with a deterministic JSON-value builder and serializer.
- Map every `schema.FieldOptions` variant and constraint.
- Generate record/create/update/list/error components.
- Generate five literal CRUD operations per non-system collection.
- Encode `public`/`locked`/`conditional` access without overclaiming authentication.
- Add exhaustive unit tests, including auth create, hidden fields, multi-value fields, fixed
  numbers, rule expressions, sorting, and deterministic bytes.
- Commit: `feat: export collection OpenAPI`.

## Task 3 — Add typed and untyped consumer routes

- Convert `:param` to `{param}` and declare every path parameter.
- Map the bounded Zig route type subset recursively to JSON Schema.
- Put GET/DELETE struct inputs in query parameters and mutation inputs in JSON request bodies.
- Emit accurate route security metadata, including redacted path-secret parameters and
  collection-scoped auth extensions.
- Retain untyped routes without inventing response shapes.
- Add compile-time and runtime tests for every auth kind, type kind, void behavior, and secret
  redaction.
- Commit: `feat: export consumer routes to OpenAPI`.

## Task 4 — Wire the live CLI safely

- Implement `openapiImpl`: open the selected database, load non-system collections, generate the
  complete document with the framework's route metadata, and write stdout or an atomically
  replaced file.
- Prove no server boot, provisioning, or data mutation occurs.
- Add CLI integration tests for stdout, `--out`, custom metadata, failure behavior, and help.
- Add a framework fixture command that proves a consumer binary includes typed routes while the
  shipped binary remains collection-only.
- Commit: `feat: add zigbase openapi command`.

## Task 5 — Document and distribute the contract

- Add `docs/openapi.md` with scope, examples, security interpretation, and coverage exclusions.
- Link it from `docs/agents.md`, the docs registry/sidebar/index, generated AGENTS.md, README, and
  relevant skills.
- Add canonical copies to Genesis and PocketBase skill references where the workflow benefits,
  then update the strict sync manifest/tests.
- Add a changelog fragment.
- Regenerate and verify the site.
- Commit: `docs: publish OpenAPI export workflow`.

## Task 6 — Full verification

- `zig fmt --check src build.zig`
- `zig build test --summary all`
- CLI/admin/agent-eval Python suites in their independent pytest roots.
- Skill validators and reference-sync tests.
- Gating and allocator contract scripts.
- Blog, GolfSim, and Plugins build/test boundaries.
- Full site build, strict doctor, generated/static tests, and browser smoke.
- `git diff --check` and a clean worktree.

Any defect found here receives a focused regression and its own local checkpoint commit before the
matrix is rerun.
