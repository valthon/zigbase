# ZigBase AI-Agents Program — design

**Date:** 2026-08-08
**Status:** Approved (program-level design; each sub-project gets its own spec → plan cycle)
**Baseline:** main @ 087ca67 (v0.12.0)

## 1. Context

zigapagos shipped its agent-enablement work post-v0.3.0 (PRs #138, #140): NDJSON
`--format=json` across the build/fix loop with a frozen error-code ledger, `init`-generated
`AGENTS.md`/`CLAUDE.md` organized around agent traps, the Astro migration packaged as a
drift-tested in-repo Agent Skill, and an agent-shaped background dev server (flock liveness,
readiness handshake, build-aware status endpoint, agent-environment auto-detection). Its
`docs/dev-server.md` closes with a "Conventions for ZigBase" section pre-specifying how a
future `zigbase serve --background` should behave.

A survey of ZigBase main found **no agent story at all** (no AGENTS.md, no llms.txt, nothing
in `docs/ideas.md`) but strong raw materials: 413 comptime `@compileError` sites with
valid-key listings and migration hints, fail-fast startup errors naming the exact fix,
always-on provisioning lints, runtime schema DDL over REST, a four-language codegen
pipeline, and the first-class in-process `zigbase.testing` harness. The gaps are discovery,
machine-readability, and runtime observability — ranked in §6 below as they feed the lanes.

ZigBase is a different product shape from zigapagos: agents may **embed it as a Zig
framework** or treat a running instance as a **backend-in-a-box** (schema over REST, SDK
clients, never touching Zig). This program serves both, box-first.

## 2. Decisions (settled during brainstorming — do not re-litigate)

1. **Persona priority:** both personas; backend-in-a-box first, Zig-embedding hardened second.
2. **MCP: never.** Committed permanently after research: CLI + REST + docs + skills are the
   agent interface. Not "later", not "as a sidecar" — never. Design the REST/CLI surface to
   be self-describing so no protocol layer is ever missed.
3. **Golden path: full lifecycle.** Idea → deployed (Docker/VPS/PaaS) → evolving live
   (schema changes, migrations, monitoring), all agent-navigable.
4. **zigapagos pairing:** every improvement stands alone for any frontend; the pairing is
   one explicit deliverable (full-stack template/skill), not a coupling.
5. **Program shape:** parallel contracts + story lanes, gated by recurring agent-evals.
6. **Flagships:** both swings below are flagships; **genesis leads**, migration follows on
   the machinery genesis hardens.
7. **Migration source order:** PocketBase → Rails → NodeJS/Express → Laravel → Go
   webservice (more may be added). Rails is gated on advanced zigapagos integration
   (Rails apps bring frontends; the frontend half of that migration needs the pairing
   story). PocketBase goes first because it is near-isomorphic and has no frontend
   component — it validates the machinery cheaply.
8. Where zigapagos already wrote conventions for ZigBase (background-server lockfile
   fields, flock liveness, readiness handshake, verb shapes, two-env-var rule, agent
   auto-detection), **adopt them verbatim** rather than inventing a second pattern.

## 3. Vision

ZigBase becomes the backend AI agents reach for, with two headline claims:

- **"Vibe-code a real product, not a demo — secure by default."** Locked-by-default access
  rules turn vibe coding's most infamous failure mode (shipped-open backends) into
  ZigBase's differentiator.
- **"Auto-migrate your legacy backend."** An official skill family that re-platforms
  existing apps onto ZigBase unattended, with recorded-replay parity verification making
  the claim honest.

## 4. Flagship 1 — App Genesis skill (leads)

An official in-repo Agent Skill: input is a one-line idea ("dating app for climbers"),
output is a **deployed, tested, rules-locked** app.

- **Form:** thin workflow (à la zigapagos's migration skill) over drift-tested reference
  docs. References are byte-copies of canonical `docs/` content; a CI script diffs them
  (red build on drift), same discipline as `tests/skills/sync.sh` in zigapagos.
- **Doctrine encoded** (this is the value over raw docs): schema-design judgment
  (collection vs computed hook; relations + `expand` vs denormalization; when realtime
  earns its place; cursor pagination from day one), rules-first security design, hooks
  vs validation placement, test-alongside-each-feature using `zigbase.testing` /
  `serve --ephemeral`, ending at `zigbase doctor --production` + Docker deploy.
- **Exit criteria:** the agent-eval scenario "genesis an app unattended" passes: app
  deployed, tests green, zero `@public` rules unaccounted for, no human intervention.

## 5. Flagship 2 — Migration skill family

One skeleton, instantiated per source framework:

```
inventory source → schema transplant → data pump → auth/user migration
→ endpoint parity map → replay verification → cutover checklist
```

- **Parity replay is the keystone:** record the old app's HTTP behaviors, replay against
  the ZigBase replacement, diff. Without it, "unattended migration" is a demo; with it,
  it is a claim.
- **Deterministic parts are tools, judgment parts are skill:** source-DB schema
  introspection, data pump (NDJSON import), and hash-compatible user import are CLI/tool
  work; endpoint re-architecture and business-logic porting are skill workflow.
- **Sources, in order:** PocketBase (first; validates machinery; no frontend), Rails
  (next priority; blocked on advanced zigapagos integration), NodeJS/Express
  (discovery-driven re-platforming — "migrate your slop" narrative), Laravel, Go
  webservice. Express has no conventions, so its instantiation leads with a discovery
  phase (crawl routes, infer schema from queries) and is framed as re-platforming with
  judgment, not mechanical translation.

## 6. Contracts lane

Machine-readable/runtime plumbing. Every item is a named dependency of a flagship, not
free-floating DX polish:

| Item | Pulled by |
|---|---|
| Structured logging: request logs, log levels, `--log-format=json`; **fix the silent-500 hole** (built-in handler errors currently swallowed with no log line, `src/server.zig:247`) | genesis dev loop |
| Env-var fail-fast: parse errors name the variable; unknown `ZIGBASE_*` warns (`src/config.zig` currently dies bare or ignores silently) | genesis, deploy |
| Frozen error-code ledger: consolidate the 27 `validation_*` codes, unify the two error-envelope shapes (typed routes vs canonical — pre-1.0 breaking change), `zigbase explain-code`, "match on code never message" contract | genesis fix loop, parity replay |
| `--json` on CLI commands (`migrate status`, `version`, `doctor`, …), NDJSON where streaming | all agent loops |
| `/api/meta` (or extend `/api/health`): expose `.collections_frozen`, capabilities, flags — today frozen mode is discoverable only by string-matching a 403 | live evolution |
| `serve --background` / `stop` / `status --json` / `logs [--follow]` per the zigapagos conventions (flock liveness, readiness handshake, two env vars, agent auto-detection) | genesis dev loop |
| `serve --ephemeral`: tempdir + random free port, prints `{url, port, dataDir}` JSON when ready — the no-Zig test-backend story | genesis testing, SDK/frontend tests |
| `zigbase doctor [--production] --json`: preflight checks with frozen check ids (JWT secret persistence, `@public` rules enumerated, insecure-cookies off, host binding, trust-proxy, mailer, migrations applied) | genesis ship gate, migration cutover |
| Declarative schema: `zigbase schema dump --json` / `schema apply file.json [--dry-run]` over the existing runtime DDL | migration transplant, live evolution |
| Scaled NDJSON import + **legacy-password-hash import**: store source hash with algorithm tag, verify on login, rehash to argon2id — without this no real user base can migrate | migration data/auth pump |
| OpenAPI export (`zigbase openapi`): reverses the 2026-06 descoping; comptime tier already introspects custom routes (it powers `rpc.*` codegen), so coverage = collections + consumer routes | parity replay, ecosystem tooling |

## 7. Story lane

Discovery, scaffolding, docs, distribution:

- **`npx zigbase init`** (the bare `zigbase` npm alias makes this zero-install), two modes:
  *box mode* (docker-compose or binary + schema file + SDK wiring + AGENTS.md — no Zig)
  and *framework mode* (build.zig, build.zig.zon with the real git dependency — killing
  the `.path = "../.."` copy-paste trap — main.zig, wired `zig build test` step, AGENTS.md
  + one-line CLAUDE.md). A `zigbase.addTo(b, exe)`-style build helper makes the silent
  `link_libc = true` footgun impossible to hit.
- **Generated AGENTS.md is trap-oriented, not a feature tour** (the zigapagos lesson):
  rules default Locked and `""` ≠ public; `--insecure-cookies` for local HTTP; green
  `zig build test` ≠ green browser suite; `changelog.d/` not CHANGELOG; the two error
  envelopes; `public`-equivalent don't-edit paths. Also emittable standalone via
  `zigbase agents-md` for existing projects.
- **`llms.txt`** on the docs site + a machine-readable docs index (promote
  `site/scripts/docs-registry.json` from build input to discovery artifact) + a ~2k-token
  agent entry doc so agents selectively load the ~200k-token corpus.
- **Testing visibility:** `docs/testing.md`; convert all three examples from
  out-of-process vitest harnesses to `zigbase.testing` (today they teach agents the
  opposite of the intended pattern); copyable `b.addTest` target in docs and scaffold.
- **`docs/deployment.md`:** systemd, Fly/Railway, reverse-proxy TLS, the production
  checklist currently scattered across README/KNOWN_LIMITATIONS/help text.
- **Publish the three finished SDKs** (Python/PyPI, Dart/pub.dev, Kotlin/Maven) — complete
  work with ready workflows, no tag ever cut; agents reach for pip first.
- **Pairing deliverable:** one official zigapagos+ZigBase full-stack template/skill.

## 8. Agent-eval gate

Scripted scenarios executed by a real agent, scored: completion, intervention count,
rules-locked-at-end, tests green. Initial scenarios: (1) "genesis an app unattended",
(2) "migrate the reference PocketBase app unattended". Runs are manual or scheduled —
token cost keeps them out of blocking CI. Every stumble files an issue; every release can
answer "did we get easier for agents?". Skill reference drift tests (byte-compare against
canonical docs) DO run in normal blocking CI.

## 9. Sequencing

- **SP-1 contracts-core:** logging + silent-500 fix, env-var fail-fast, error-code
  ledger + envelope unification, CLI `--json`, `/api/meta`.
- **SP-2 arrival:** `npx zigbase init` (both modes) + build helper, AGENTS.md generation,
  `llms.txt` + entry doc + docs index, testing visibility.
- **SP-3 dev-loop:** `serve --background`/`--ephemeral` + control verbs, `doctor`.
- **SP-4 genesis flagship:** the skill + `docs/deployment.md` + eval harness v1 +
  eval scenario 1.
- **SP-5 migration machinery + PocketBase skill:** `schema dump/apply`, scaled import,
  legacy-hash import, parity replay, the PocketBase migration skill, eval scenario 2.
- **SP-6 distribution:** SDK publishing, pairing deliverable.
- **Then:** Rails migration skill when advanced zigapagos integration lands; NodeJS,
  Laravel, Go on the same skeleton.

Sub-projects overlap where independent (SP-2 does not depend on SP-1 completing). The
standing sharpening lane continues alongside per the usual rhythm. Each SP gets its own
spec → plan → implementation cycle; this document is the program frame.

## 10. Risks & open questions

- **Legacy-hash import** touches the auth core; needs its own security review (algorithm
  allowlist, no downgrade path, rehash-on-login only).
- **Envelope unification is a wire-breaking change** — fine pre-1.0, needs a Breaking
  changelog entry and SDK updates in the same stream.
- **OpenAPI fidelity:** comptime route introspection covers structure; response-shape
  fidelity for hand-written handlers may need annotations — scope carefully in the SP-5
  spec, don't over-promise.
- **Eval-harness cost/flakiness:** agent runs are nondeterministic; score trends, not
  single runs.
- **Rails timing** is externally gated (zigapagos advanced integration) — sequence NodeJS
  ahead of Rails if the gate is slow, since it has no frontend dependency of the same kind.

## 11. Out of scope

- MCP, in any form, ever (decision #2).
- Hosted/cloud ZigBase offering.
- Windows support (settled separately: Docker is the Windows answer).
- Model-calling features inside ZigBase (embeddings, LLM proxying) — vector search stays
  bring-your-own-embedding.
