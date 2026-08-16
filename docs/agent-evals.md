# Agent evaluations

ZigBase includes a provider-neutral harness for testing whether a coding agent can turn a product
idea into a secure, tested, deployed application. The harness runs a user-supplied command in an
isolated workspace and grades artifacts and executable behavior. It does not inspect the agent's
transcript or trust the agent's self-report.

The Genesis flagship passed its release gate on 2026-08-15: commit `3f3224d5` produced three
consecutive score-4 runs with zero interventions using `codex-cli-0.147-default`. The sanitized
summaries are preserved under
[`evals/agents/evidence/genesis/2026-08-15-3f3224d5/`](../evals/agents/evidence/genesis/2026-08-15-3f3224d5/).
Deterministic harness tests block CI; real-agent runs remain opt-in so model tokens and credentials
are never required by ordinary builds.

## Install the scenario skill

The runner installs the scenario's declared skill into the isolated workspace:

- `genesis` uses `skills/zigbase-app-genesis/`;
- `pocketbase` uses `skills/zigbase-migrate-pocketbase/`.

When running an agent outside this harness, use that product's normal local-skill installation
mechanism and preserve the directory name. The harness deliberately does not know how any provider
stores credentials.

The skill embeds canonical ZigBase references. CI fails if those copies differ from the matching
files under `docs/`, if required metadata disappears, or if `SKILL.md` grows beyond its context
budget.

## Select an agent command

Set `ZIGBASE_AGENT_COMMAND_JSON` to a JSON array of argv entries. The runner never invokes a shell.
It substitutes an entry that is exactly `{workspace}` with the fresh writable workspace and an
entry exactly `{prompt}` with the absolute prompt-file path. If an entry is exactly `-`, the prompt
body is also sent on stdin.

For a Codex CLI configured to load the skill:

```sh
export ZIGBASE_AGENT_COMMAND_JSON='["codex","exec","--ephemeral","--approve-for-me","--skip-git-repo-check","-C","{workspace}","-"]'
python3 -m evals.agents.run genesis --agent codex
```

Use the same command with `pocketbase` to evaluate an unattended migration from the committed,
synthetic PocketBase 0.39.11 snapshot:

```sh
mise exec zig@0.16.0 -- zig build
ZIGBASE_EVAL_BINARY="$PWD/zig-out/bin/zigbase" \
  python3 -m evals.agents.run pocketbase --agent codex \
  --pass-env ZIGBASE_EVAL_BINARY
```

That scenario provides only the pinned snapshot, the supported converter, the migration skill,
its prompt, and the read-only ZigBase binary built from the scenario's repository revision. The
agent verifies and copies that binary into its local deployment image; it must not substitute an
older public image or clone a different source revision. The scenario requires a deterministic
bundle, exact durable decisions, autonomous public signup, owner/file authorization, bcrypt
rehash-on-login, historical timestamps, parity evidence, and a restartable named-volume Compose
deployment. It neither downloads nor runs PocketBase.

Metacharacters are literal argv data. Do not wrap the JSON command in `sh -c`. The scenario caps
command size, runtime, and captured output.

The child receives a small environment allowlist and isolated `HOME`/`TMPDIR`. If a command truly
needs an environment credential, opt into that one name explicitly:

```sh
python3 -m evals.agents.run genesis --agent example --pass-env EXAMPLE_API_KEY
```

`--pass-env` never accepts runner-control variables, missing names, duplicates, or unbounded
values. Prefer an agent's existing authenticated local configuration when it can operate without
copying a secret into the process environment.

## Results and artifacts

The runner prints exactly one compact JSON result on stdout. Field order is stable:

```json
{"zigbaseAgentEval":1,"scenario":"genesis","commit":"…","agent":"codex","started_at":"…","duration_ms":123,"agent_exit":0,"timed_out":false,"interventions":0,"completion":true,"rules_locked":true,"tests_green":true,"deployed":true,"score":4,"failures":[]}
```

The four booleans are independently graded. For `genesis` they mean:

- `completion`: expected app shape, trusted server logic, cursor/expand usage, and a successful
  build;
- `rules_locked`: production doctor output exactly matches the reviewed public-rule inventory;
- `tests_green`: in-process Zig tests and the declared client/browser boundary test pass; and
- `deployed`: pinned Compose config has durable `/data`, health and metadata respond, production
  doctor is clean, and exact teardown succeeds.

For `pocketbase` they mean:

- `completion`: the source and converter match their pinned hashes, the bundle verifies every
  output hash and expected row/file count, and the strict migration report is complete;
- `rules_locked`: syntax and full-depth rule lint plus production doctor reconcile exactly with
  durable decisions and `security/public-rules.json`, including `members.createRule` as a reviewed
  warning for open signup;
- `tests_green`: fixed schema/auth/data/file commands, the declared integration boundary,
  timestamps, relations, anonymous signup, owner denial/allowance, protected files, and
  bcrypt-to-argon2 login upgrade all pass; and
- `deployed`: production-shaped Compose serves health, metadata, migrated data, auth, and files
  before and after restart, uses named `/data`, passes doctor, and tears down exactly.

Exit `0` means all four grades passed. Exit `1` means the harness or agent command failed or timed
out. Exit `2` means the agent completed but deterministic grading found a product condition that
needs attention.

Raw bounded stdout/stderr and grader command logs default to
`/tmp/zigbase-agent-evals/<scenario>-<timestamp>-<id>/`. Choose another location with
`--artifacts-dir`. Write a sanitized result copy below that directory with:

```sh
python3 -m evals.agents.run genesis \
  --artifacts-dir /tmp/zigbase-genesis-runs \
  --out results/latest.json
```

`--out` cannot escape the selected artifact directory. Raw logs may contain source, prompts, or
credentials printed by the external command. Keep them local or in a short-lived restricted CI
artifact; never commit transcripts. Only sanitized result summaries belong in release evidence.

## Deterministic development checks

Real-agent execution is not part of ordinary CI. Run the blocking converter, contracts,
fake-agent cases, negative grader fixtures, and Genesis live Docker boundary with:

```sh
ZIGBASE_TEST_BINARY=./zig-out/bin/zigbase \
  python3 -m pytest tests/pocketbase tests/agent_evals tests/admin/test_skill_sync.py -q
python3 -m ruff check tools/pocketbase evals/agents tests/pocketbase tests/agent_evals
ZIGBASE_DOCKER_EVAL_TEST=1 \
  python3 -m pytest tests/agent_evals/test_genesis_docker.py -q
```

The live Docker test uses the pinned `ghcr.io/valthon/zigbase:0.13.0` image, a unique Compose
project, a random loopback port, and `down -v --remove-orphans` in every path. It requires access to
a local Docker daemon. PocketBase grader tests use deterministic positive and one-failure-per-grade
fixtures; a real PocketBase agent run supplies the migration-specific deployment for live grading.

Ordinary CI downloads the already-built ZigBase artifact, never a PocketBase release, and runs no
model command. The committed PocketBase database, local files, bcrypt credential, and parity data
are synthetic fixtures. Do not replace them with a production snapshot. Keep generated agent
workspaces and raw logs local; commit only source fixtures, deterministic grader fixtures, and
sanitized result summaries.

## Three-run release evidence

Run either flagship from a fresh agent context with only its installed skill, scenario prompt,
fixture, and ordinary repository-visible tools. Do not provide the grader source, an implementation
plan, or coaching from an earlier failure. A failure resets that scenario's consecutive count. Fix
the owning tool, docs/skill, or grader and add a deterministic regression test before restarting.

The flagship criterion is three consecutive results from the same commit where all four booleans
are true, `score` is 4, `interventions` is 0, and `failures` is empty. Preserve those sanitized
summaries and record the agent/model identifier supplied to `--agent`.

The first qualifying Genesis set is the 2026-08-15 `3f3224d5` evidence linked above. PocketBase
evidence is published only after its own three clean runs. Raw transcripts and scenario workspaces
stay out of the repository.
