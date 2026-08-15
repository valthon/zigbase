# SP-4 App Genesis flagship — design

**Date:** 2026-08-15
**Status:** Approved for implementation
**Program:** [ZigBase AI-Agents Program](2026-08-08-ai-agents-program-design.md), SP-4
**Baseline:** main @ e4812849 (v0.13.0)

## 1. Goal

Ship the first complete ZigBase agent workflow: given a one-line product idea, an agent can
produce a tested, rules-locked application and prove it is ready to run through Docker without
human intervention.

SP-4 delivers four things together because none is independently honest:

1. the `zigbase-app-genesis` Agent Skill;
2. canonical app-design and deployment guidance, copied into the skill behind a blocking drift
   guard;
3. a provider-neutral real-agent evaluation harness with deterministic graders; and
4. the `genesis` scenario, whose result is the flagship's release gate.

The skill is a thin workflow. ZigBase remains the source of deterministic behavior through
`init`, `schema apply`, `serve --ephemeral`, `doctor`, and Docker. The skill supplies judgment:
schema shape, relation vs denormalization, rules-first security, hook placement, test boundaries,
and the order in which the tools are used.

## 2. Scope

### In scope

- `docs/app-genesis.md`: canonical design doctrine for a new ZigBase app.
- `docs/deployment.md`: systemd, Docker, reverse-proxy TLS, Fly, Railway, persistence, backups,
  upgrades, rollback, and the production checklist.
- `skills/zigbase-app-genesis/`: a discoverable Agent Skill with progressive-disclosure
  references and Codex UI metadata.
- `tests/skills/sync.sh`: a non-vacuous blocking guard over skill shape and canonical reference
  copies.
- `evals/agents/`: a manual/scheduled real-agent runner, stable result schema, deterministic
  graders, fixtures, and unit tests.
- Genesis scenario 1 from the program design.
- Documentation and CI wiring for all of the above.

### Out of scope

- The PocketBase skill and scenario 2 (SP-5 follow-up; they consume this infrastructure).
- OpenAPI export (its own contract-lane project).
- Calling a model from ZigBase itself.
- Blocking CI runs of a real model. Blocking CI runs only deterministic skill-sync and grader
  tests.
- A hosted deployment or mandatory paid cloud account. A healthy local Docker deployment is the
  reproducible definition of `deployed` for the eval; the deployment guide covers hosted targets.
- Publishing SDKs or the zigapagos pairing deliverable (SP-6).

## 3. Settled decisions

### D1. Skill layout follows the established zigapagos contract

```text
skills/zigbase-app-genesis/
├── SKILL.md
├── agents/openai.yaml
└── references/
    ├── agents.md
    ├── app-genesis.md
    ├── deployment.md
    ├── serve.md
    └── testing.md
```

Every reference is a byte-copy of the same-named canonical file under `docs/`. The sync guard
names every pair explicitly, so an empty `references/` directory cannot pass. `SKILL.md` stays
under 500 lines and contains procedure and routing only; detailed doctrine remains in references.

The skill frontmatter contains only `name` and `description`. The name equals the directory.
`agents/openai.yaml` supplies UI metadata, not trigger semantics.

### D2. Canonical docs win every disagreement

The skill never restates a long contract already present in a reference. It tells the agent when
to read each reference and which command proves completion. Drift is fixed by copying canonical
docs into the skill, never by editing the reference copy directly.

`docs/app-genesis.md` is the new home for the judgment that does not belong in API reference:

- collection vs computed hook;
- relation + `expand` vs denormalization;
- realtime's cost/benefit threshold;
- cursor pagination from the first list endpoint;
- rules-first schema design;
- validation vs record hook vs typed route;
- test placement and the boundary between `zigbase.testing`, an ephemeral server, and a browser;
- an explicit inventory for every public rule.

### D3. The eval runner is provider-neutral and never invokes a shell

The runner accepts an agent command as a JSON argv array through
`ZIGBASE_AGENT_COMMAND_JSON`. Two substitutions are supported in individual argv entries:
`{workspace}` and `{prompt}`. Example:

```sh
export ZIGBASE_AGENT_COMMAND_JSON='["codex","exec","--full-auto","-C","{workspace}","-"]'
python evals/agents/run.py genesis
```

When an argv entry is exactly `-`, the prompt is sent on stdin; `{prompt}` is the absolute prompt
file path for agents that accept a path. The runner uses `subprocess.Popen` with an argv list,
never `shell=True`. The child receives an isolated workspace and a bounded environment. A timeout
terminates the whole child process group.

The harness does not embed API clients, model names, provider credentials, or a second agent
protocol. It runs a user-supplied command and grades filesystem/process results.

### D4. Graders inspect reality, never the transcript or agent self-report

Scenario grading runs after the agent exits and checks only artifacts and executable behavior.
The Genesis grader verifies:

1. the expected scaffold and security inventory exist;
2. the generated app builds;
3. its unit tests pass;
4. its browser/client test command passes when the scenario requests a frontend;
5. Docker Compose reaches `/api/health` and `/api/meta`;
6. `zigbase doctor --production --json` reports no errors;
7. every public-rule finding is represented exactly once in
   `security/public-rules.json`, with a non-empty rationale; and
8. teardown removes containers and scenario-owned temporary data.

The grader never trusts a README checkbox, final chat message, or claimed test result.

### D5. Public access is accounted for, not mechanically forbidden

Some real applications need public reads, sign-up, or webhooks. The exit criterion is therefore
zero **unaccounted** public rules, not zero public rules. The skill requires:

```json
{
  "zigbasePublicRules": 1,
  "rules": [
    {"collection": "posts", "operation": "list", "rule": "@public", "rationale": "Published posts are public product content."}
  ]
}
```

The grader compares this file with doctor's public-rule findings. Missing, extra, duplicate,
stale, or empty-rationale entries fail. The file contains no credentials.

### D6. A local Docker deployment satisfies the eval's deployment criterion

The scenario runs the produced application with Docker Compose, using a scenario-owned data
directory and random host port. It waits for health, checks metadata, and then tears down. Fly and
Railway are documented and may receive separate smoke checks, but credentials and external
availability cannot be part of the repeatable flagship grade.

### D7. Real-agent runs are non-blocking; graders and drift guards are blocking

Blocking CI runs:

- skill structure/reference sync;
- the sync guard's own negative controls;
- result-schema/parser tests;
- runner timeout/process-cleanup tests with a fake agent;
- Genesis grader positive and negative fixtures.

Manual or scheduled runs execute a real agent. A run writes a sanitized JSON summary; raw
stdout/stderr remain local or a short-lived CI artifact because transcripts can contain secrets.
No raw transcript is committed.

### D8. Stable result contract and exit codes

Each run emits exactly one JSON summary on stdout and optionally writes the same object to
`--out`. Field order is stable:

```json
{
  "zigbaseAgentEval": 1,
  "scenario": "genesis",
  "commit": "...",
  "agent": "user-supplied",
  "started_at": "...",
  "duration_ms": 123,
  "agent_exit": 0,
  "timed_out": false,
  "interventions": 0,
  "completion": true,
  "rules_locked": true,
  "tests_green": true,
  "deployed": true,
  "score": 4,
  "failures": []
}
```

Exit `0` means every grade passed, `1` means the harness/agent failed or timed out, and `2` means
the agent completed but deterministic grading found a product condition needing judgment. This
matches the program-wide CLI meaning even though the eval runner is a development tool.

`interventions` is zero for the standard non-interactive run. A manual experiment may pass
`--interventions N`; any value above zero prevents the unattended exit criterion from passing.

### D9. Three clean runs close the flagship

One nondeterministic success is insufficient. SP-4 is complete when the same commit produces
three consecutive Genesis results with:

- `completion`, `rules_locked`, `tests_green`, and `deployed` all true;
- `interventions == 0`;
- `score == 4`; and
- no grader failures.

Store the three sanitized summaries with the release evidence. Do not average away a failure.

## 4. Scenario contract

The initial prompt is intentionally short: a one-line product idea plus the instruction to use
the installed `zigbase-app-genesis` skill. The fixture provides ZigBase itself through a known
binary/npm version and otherwise begins in an empty writable directory.

The reference idea is stable and exercises the doctrine without requiring third-party services:

> Build a community gear-lending app where members list equipment, request a date range, and
> owners approve or reject requests.

Required behaviors:

- authenticated ownership and mutation rules;
- at least one intentionally public read that must be inventoried;
- a relation used by list expansion;
- cursor pagination;
- one piece of business logic placed outside raw client validation;
- in-process backend tests and one client/browser boundary test;
- persistent Docker data and a production preflight.

The grader owns the exact black-box assertions. The prompt does not leak their implementation or
expected file contents.

## 5. Security and isolation

- Run scenarios only in a freshly created directory whose resolved path is recorded before any
  cleanup.
- Never recursively delete a user-supplied directory. Cleanup is limited to the runner-created
  directory and Docker Compose project name.
- Strip unrelated secrets from the child environment. Pass only an explicit allowlist plus the
  credentials the user deliberately places in the agent command's environment.
- Use a unique Compose project and random host port; teardown by exact project name.
- Reject symlinked scenario roots and any result/output path outside the caller-selected output
  location.
- Cap captured logs and JSON sizes. A malicious or confused agent must not exhaust disk or memory.
- Redact environment-shaped values from displayed failure context; do not claim comprehensive
  secret scanning.

## 6. Test strategy

The sync guard has positive and negative self-tests: missing skill, missing reference, changed
reference, wrong name, missing description, oversized `SKILL.md`, missing UI metadata, and a clean
tree. The normal CI invocation cannot be vacuously green.

The eval runner uses fake agents to cover success, nonzero exit, timeout, process-group cleanup,
oversized output, invalid command JSON, and paths containing spaces. Grader fixtures independently
cover every boolean and each public-rule inventory mismatch. Docker-backed grader integration runs
in the existing Linux CI environment; real-agent execution does not.

The final forward test uses a real agent with only the installed skill, scenario prompt, and normal
repository-visible tools. It must not inherit this design document as hidden context.

## 7. Documentation and release boundary

Consumer-visible work adds changelog fragments; it never edits `CHANGELOG.md` directly. Both new
canonical docs are registered in `site/scripts/docs-registry.json` and linked from the two
hand-authored navigation layouts; `site/scripts/gen-content.ts` then generates the page, discovery
index, `llms.txt`, and sitemap. README and
`docs/agents.md` link the Genesis skill and explain that real-agent evals are manual/scheduled.

The feature may merge before three real-agent passes as an explicitly experimental internal
surface, but it must not be marketed as an unattended flagship until D9 is satisfied. Release
evidence records the ZigBase commit, skill bytes, agent/model identifier supplied by the runner,
and the three summaries.

## 8. Follow-on contract for PocketBase

SP-5 scenario 2 reuses the runner, result schema, isolation, timeout, transcript policy, and grader
interfaces unchanged. It adds a source fixture and migration-specific grader; it does not fork the
harness or create a second result shape.
