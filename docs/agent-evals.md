# Agent evaluations

ZigBase includes a provider-neutral harness for testing whether a coding agent can turn a product
idea into a secure, tested, deployed application. The harness runs a user-supplied command in an
isolated workspace and grades artifacts and executable behavior. It does not inspect the agent's
transcript or trust the agent's self-report.

The Genesis scenario is currently an experimental development surface. Deterministic harness tests
block CI; real-agent runs are opt-in and do not become a release claim until one commit produces
three consecutive score-4 runs with zero interventions.

## Install the skill

The agent under test must be able to load `skills/zigbase-app-genesis/` as an installed skill. Use
that agent product's normal local-skill installation mechanism and preserve the directory name
`zigbase-app-genesis`. The harness deliberately does not know how any provider installs skills or
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
export ZIGBASE_AGENT_COMMAND_JSON='["codex","exec","--ephemeral","--sandbox","workspace-write","--approve-for-me","--skip-git-repo-check","-C","{workspace}","-"]'
python3 -m evals.agents.run genesis --agent codex
```

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

The four booleans are independently graded:

- `completion`: expected app shape, trusted server logic, cursor/expand usage, and a successful
  build;
- `rules_locked`: production doctor output exactly matches the reviewed public-rule inventory;
- `tests_green`: in-process Zig tests and the declared client/browser boundary test pass; and
- `deployed`: pinned Compose config has durable `/data`, health and metadata respond, production
  doctor is clean, and exact teardown succeeds.

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

Real-agent execution is not part of ordinary CI. Run the blocking contracts, fake-agent cases,
negative grader fixtures, and live Docker boundary with:

```sh
python3 -m pytest tests/agent_evals tests/admin/test_skill_sync.py -q
ZIGBASE_DOCKER_EVAL_TEST=1 \
  python3 -m pytest tests/agent_evals/test_genesis_docker.py -q
```

The Docker test uses the pinned `ghcr.io/valthon/zigbase:0.13.0` image, a unique Compose project,
a random loopback port, and `down -v --remove-orphans` in every path. It requires access to a local
Docker daemon.

## Three-run release evidence

Run Genesis from a fresh agent context with only the installed skill, scenario prompt, and ordinary
repository-visible tools. Do not provide the grader source, this implementation plan, or coaching
from an earlier failure. A failure resets the consecutive count. Fix the owning tool, docs/skill,
or grader and add a deterministic regression test before restarting.

The flagship criterion is three consecutive results from the same commit where all four booleans
are true, `score` is 4, `interventions` is 0, and `failures` is empty. Preserve those sanitized
summaries and record the agent/model identifier supplied to `--agent`.
