# Rails API migration skill — implementation plan

**Design:** [2026-08-21-rails-api-migration-design.md](../specs/2026-08-21-rails-api-migration-design.md)
**Program:** [2026-08-08-ai-agents-program-design.md](../specs/2026-08-08-ai-agents-program-design.md)
**Issue:** [#374](https://github.com/valthon/zigbase/issues/374)

Ships as two stacked pull requests. The first delivers the guide, skill, converter, fixture, and
deterministic tests; the second adds the graded agent-eval scenario on top.

## Contracts fixed before implementation

**Source bundle** — the frozen, read-only boundary the converter consumes:

```
source/
  freeze.json             revision, ruby/rails versions, lockfile digest, database digest, mode
  inventory/              routes, models, schema, storage, jobs, counts, versions
  db/                     the frozen SQLite database
  storage/                Active Storage local-disk blobs
  http/cases.json         recorded representative exchanges for parity replay
```

Every record under `inventory/` carries `"source": "observed"` or `"source": "inferred"`. The
extractor `tools/rails/export_source.rb` emits only `observed`; the documented static fallback emits
only `inferred`. The converter never promotes one to the other.

**Converter** — `tools/rails/rails2zb.py`, offline and dependency-free:

- `inventory --source SRC --out findings.json` — enumerate findings with stable ids; exit `2` when
  judgment is required.
- `extract --source SRC --decisions decisions.json --out BUNDLE` — emit the schema document,
  NDJSON, manifests, file manifest, report, and hashes; byte-identical across reruns.
- `install-files --bundle BUNDLE --data-dir DATA` — place Active Storage blobs.

## Pull request 1 — guide, skill, converter, fixture, tests

1. Publish `docs/migrate-rails-api.md`: the API-only scope gate, observed-versus-inferred
   discovery, schema/authorization mapping, deterministic extraction, HTTP parity including
   validation-failure, unauthenticated, and unauthorized cases, and rehearsed cutover and rollback.
2. Initialize `skills/zigbase-migrate-rails-api/` over byte-synced canonical references, with a
   completion contract that cannot imply Rails views or frontend behavior were migrated.
3. Add `tools/rails/export_source.rb` and `tools/rails/rails2zb.py`.
4. Commit the synthetic Rails 8 API fixture generated once from a real application, plus
   `tools/rails/regenerate_fixture.py` recording how it was produced. CI never installs Ruby.
5. Add `tests/rails/` covering inventory findings, decision enforcement, deterministic extraction,
   preserved ids/timestamps/relations, files, bcrypt credentials, and the fidelity boundaries.
6. Extend the official-skill guard, docs registry, site navigation, agent index, README, and
   changelog; regenerate every skill's references.
7. Wire `tools/rails` and `tests/rails` into the `agent-evals` CI job's lint and pytest steps.

## Pull request 2 — graded scenario

8. Add `evals/agents/scenarios/rails-api/` with its manifest, prompt, and fixture, and register the
   skill and grader.
9. Add `evals/agents/graders/rails_api.py` reusing the shared Genesis grader helpers, grading
   completion, rules_locked, tests_green, and deployed.
10. Add positive and one-failure-per-grade fixtures with grader tests, plus a prompt-to-grader
    coupling guard.
11. Document the scenario in `docs/agent-evals.md` and record the release-evidence procedure.

## Verification

Deterministic converter and grader tests, skill drift check, docs parity, site build and static
checks, ruff, and the full browser suite before either pull request is published.
