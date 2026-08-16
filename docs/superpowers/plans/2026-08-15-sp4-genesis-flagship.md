# SP-4 App Genesis flagship — implementation plan

> **For agentic workers:** implement tasks in order with tests first where behavior is executable.
> Each task is one reviewable commit unless its verification exposes a defect that belongs in the
> same change.

**Date:** 2026-08-15
**Design:** [SP-4 App Genesis flagship](../specs/2026-08-15-sp4-genesis-flagship-design.md)
**Baseline:** main @ e4812849 (v0.13.0)

## Goal

Deliver the canonical Genesis/deployment docs, a drift-guarded `zigbase-app-genesis` skill, a
provider-neutral real-agent eval harness, and a deterministically graded Genesis scenario. The
implementation ends with three clean unattended runs on one commit.

## Global constraints

- Zig is exactly 0.16.0 through mise. Python is 3.13 and the eval harness uses only the standard
  library.
- Use `apply_patch` for source edits. Format Zig with `zig fmt`; Python with the repository's Ruff
  version where applicable.
- Never edit generated site mirrors or `CHANGELOG.md`.
- Every canonical doc addition gets one registry entry and links in `site/layouts/docs.shtml` plus
  `site/layouts/docs-index.shtml`. The current generator consumes the registry for generated pages,
  `llms.txt`, `docs-index.json`, and the sitemap; `tests/admin/test_docs_parity.py` guards the
  registry/navigation agreement.
- The skill is initialized with the skill-creator `init_skill.py`, contains no placeholder files,
  and is validated with `quick_validate.py` before its commit.
- The skill is not added to `skills/` until its description and core procedure are usable; an
  incomplete discoverable skill is worse than no skill.
- All subprocess calls use argv arrays and `shell=False`.
- No cleanup accepts an unresolved user directory, `/`, a home directory, or the repository root.
- Blocking CI never spends model tokens or requires model credentials.
- New shell scripts use `set -euo pipefail`, quote paths, and have direct negative tests.
- New Python modules carry type hints and bounded file/subprocess I/O.
- Run `./scripts/check-gating.sh` and allocator checks after any Zig-facing change; this project is
  expected to add no gated Zig surface.

## Task 1: Canonical `docs/app-genesis.md`

**Files:**

- Create `docs/app-genesis.md`.
- Modify `site/scripts/docs-registry.json`, `site/layouts/docs.shtml`, and
  `site/layouts/docs-index.shtml`.
- Modify `README.md` and `docs/agents.md` to link it.
- Modify `tests/admin/test_docs_parity.py` only if the existing generic guard cannot express the
  new published doc without an allowlist.
- Add `changelog.d/app-genesis-guide.md`.

Write the canonical judgment guide in this order:

1. start from user journeys and trust boundaries;
2. choose box vs framework mode;
3. model collections, auth collections, relations, and indexes;
4. decide relation/expand vs denormalization;
5. write access rules before seed data or UI;
6. inventory every public rule;
7. choose validation, hook, typed route, job, or computed read path;
8. adopt cursor pagination and justify realtime;
9. place in-process, ephemeral/server, and browser tests;
10. run schema dry-run, tests, doctor, and deployment gates.

Include at least two worked design decisions and one rejected insecure shortcut. Keep API syntax in
canonical API/framework docs and link it rather than duplicating it.

**Verification:** docs parity pytest, site build, link check, and a grep proving every new slug is
registered once.

## Task 2: Canonical `docs/deployment.md`

**Files:**

- Create `docs/deployment.md`.
- Complete its site registration.
- Update `README.md`, `docs/docker.md`, `docs/serve.md`, and `docs/agents.md` links.
- Add `changelog.d/deployment-guide.md`.

Cover:

- common production invariants and `doctor --production` exit handling;
- data-dir ownership, durable storage, backups, restore rehearsal, migrations, upgrades, rollback;
- systemd unit with foreground `serve`, restart policy, environment file, hardening, and journald;
- Docker Compose with healthcheck, restart policy, durable volume, graceful stop, and backup notes;
- reverse-proxy TLS examples and the exact trust-proxy/cookie boundary;
- Fly and Railway deployment shapes without claiming features their current platforms do not have;
- mail, JWT persistence, host binding, observability, and post-deploy verification.

Commands must be copyable and secure by default. Do not teach `serve --background` under systemd or
containers.

**Verification:** docs parity pytest, site build, shell syntax checks for extracted shell blocks where
practical, and a manual read against every current doctor check id.

## Task 3: Initialize and write the Genesis skill

**Files:**

- Create `skills/zigbase-app-genesis/SKILL.md` using skill-creator's `init_skill.py`.
- Create `skills/zigbase-app-genesis/agents/openai.yaml` through the generator.
- Create the five explicit files under `references/` as byte-copies of canonical docs.

The trigger description covers requests to create, scaffold, prototype, or ship a new ZigBase
application from an idea in either box or framework mode. The body stays procedural and routes to
references at the point each is needed. Required phases:

1. inventory journeys/trust boundaries;
2. select mode;
3. design schema and rules;
4. scaffold;
5. build one tested vertical slice at a time;
6. exercise server/client boundaries;
7. inventory public rules;
8. run doctor and Docker deployment;
9. report exact verification and remaining limitations.

Generate UI metadata from the finished skill. Remove all initializer placeholders and unused
directories.

**Verification:** `quick_validate.py`, frontmatter/name assertions, line budget, every linked
reference exists, and a scan for TODO/placeholder text.

## Task 4: Blocking skill sync/shape guard

**Files:**

- Create `tests/skills/sync.sh`.
- Create `tests/skills/test-sync.sh` for negative controls.
- Modify `.github/workflows/ci.yml` to run both in the build job.

The production guard explicitly maps each canonical doc to its reference copy and validates
`SKILL.md`, frontmatter, description, line budget, referenced local paths, and required
`agents/openai.yaml` keys. It must reject unexpected markdown files under the skill so a second,
unguarded documentation copy cannot appear.

The self-test copies the subject into a temporary directory and proves failures for every case in
design §6, then proves the clean control passes. It restores nothing in the working tree because it
never mutates the working tree.

**Verification:** run both scripts from the repository root and from another current directory;
run ShellCheck if available; run the CI YAML parser/test already used by the repo.

## Task 5: Eval result and scenario contracts

**Files:**

- Create `evals/agents/result.py`.
- Create `evals/agents/scenario.py`.
- Create `evals/agents/scenarios/genesis/scenario.json` and `prompt.md`.
- Create `tests/agent_evals/test_contracts.py`.

Define typed dataclasses for the stable result and scenario manifest. Serialize result fields in
design D8 order. Validate versions, scenario names, timeouts, relative fixture paths, command-size
caps, and output locations. Reject unknown keys so a misspelling cannot silently disable a grade.

The prompt contains the reference idea and instructs the agent to use the installed Genesis skill,
but does not expose grader implementation. The scenario manifest declares required graders and
resource bounds.

**Verification:** positive round-trip plus unknown/missing field, future version, path escape,
negative timeout, and stable field-order tests.

## Task 6: Provider-neutral runner

**Files:**

- Create `evals/agents/run.py`.
- Create `evals/agents/process.py` and `redact.py` only if separation keeps each module focused.
- Extend `tests/agent_evals/` with fake-agent fixtures and runner tests.

Implement:

- JSON argv parsing from `ZIGBASE_AGENT_COMMAND_JSON`;
- exact `{workspace}`/`{prompt}` substitution;
- isolated workspace creation and fixture copy;
- bounded environment allowlist;
- new process group, timeout, TERM then KILL cleanup;
- bounded stdout/stderr capture to local files;
- grader dispatch after a successful agent exit;
- exactly one result object on stdout;
- exit 0/1/2 from design D8;
- safe cleanup limited to runner-owned paths.

Do not add an SDK for any model provider. Do not interpret the transcript to decide success.

**Verification:** fake agent success/nonzero/timeout/grandchild/oversized-output/path-with-spaces
tests, plus a test showing metacharacters in argv never invoke a shell.

## Task 7: Deterministic Genesis grader

**Files:**

- Create `evals/agents/graders/genesis.py` and small shared helpers as needed.
- Create positive and one-failure-per-grade fixtures under `tests/agent_evals/fixtures/`.
- Add grader unit and Docker integration tests.

Implement independent grades for completion, rules lock/accounting, tests, and deployment. Parse
doctor NDJSON defensively: skip non-JSON log lines, require exactly one summary, reject duplicate or
unknown public-rule identities, and retain stable failure codes separate from prose.

Run project-declared commands only from the scenario manifest or the grader's fixed contract; do
not execute an arbitrary command invented in a result file. Docker uses an exact generated Compose
project name and tears it down in `finally` on every path.

**Verification:** every boolean has a positive and negative test; Docker health timeout and teardown
are tested; a stale and an extra public-rule inventory entry both fail.

## Task 8: CI, docs, and operator surface

**Files:**

- Modify `.github/workflows/ci.yml` for deterministic eval tests.
- Create a manual/scheduled workflow only if it can run without storing provider secrets in logs;
  otherwise document the exact local command and defer scheduling.
- Update `docs/agents.md`, `README.md`, and contributing documentation.
- Add `changelog.d/agent-eval-foundation.md`.

Blocking CI runs sync guards and all fake-agent/grader tests. Real-agent runs remain opt-in. Document
how to select an agent command, where local logs live, what the result fields mean, and how to run
without committing transcripts.

**Verification:** clean CI-equivalent Python tests, docs parity, site build, and workflow syntax.

## Task 9: Forward-test and close the flagship

Run the scenario with a fresh agent context that receives only the installed skill, scenario prompt,
and ordinary repository-visible tools. Do not pass this plan, grader expectations, or earlier failure
analysis into the agent context.

For each failure:

1. preserve the sanitized result and raw local artifacts;
2. classify it as tool defect, doc/skill defect, grader defect, or model nondeterminism;
3. add a deterministic regression test where possible;
4. fix the owning surface rather than coaching one run; and
5. restart the consecutive-pass count.

Completion requires three consecutive score-4, zero-intervention runs on one commit. Store only
sanitized summaries as release evidence and update public claims in a final consumer-visible commit.

## Full verification before merge

- `mise exec zig@0.16.0 -- zig build test --summary all`
- `mise exec python@3.13 -- python -m pytest tests/agent_evals -q`
- `bash tests/skills/test-sync.sh`
- `bash tests/skills/sync.sh`
- `mise exec python@3.13 -- python -m pytest tests/admin/test_docs_parity.py -q`
- existing `tests/cli`, because the skill depends on serve/doctor contracts
- `./scripts/check-gating.sh`
- `./scripts/check-allocator-contracts.sh`
- all three examples build; blog and GolfSim in-process tests pass
- `cd site && bash build.sh`
- working tree contains no transcripts, scenario data directories, containers, or secrets

## Follow-up handoff

Once Task 9 passes, write the PocketBase skill/scenario design against these exact interfaces. The
SP-5 follow-up may add graders and fixtures, but must not fork the runner, result schema, isolation,
or transcript policy.
