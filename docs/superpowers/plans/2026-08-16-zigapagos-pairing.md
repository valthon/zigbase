# Zigapagos + ZigBase pairing — implementation plan

**Design:** [2026-08-16-zigapagos-pairing-design.md](../specs/2026-08-16-zigapagos-pairing-design.md)
**Program:** [2026-08-08-ai-agents-program-design.md](../specs/2026-08-08-ai-agents-program-design.md)
**Baseline:** `43b46010`

## Task 1 — Publish the canonical pairing guide

- Document ownership boundaries, the one-origin topology, custom-binary requirement, and the
  runtime-directory versus embedded-asset deployment choice.
- Give pinned setup, build, foreground dev, E2E, OpenAPI, and production-doctor commands.
- Define the layered verification matrix and public-signup acknowledgment contract.
- Commit: `docs: design Zigapagos pairing workflow` (design and plan checkpoint), then
  `docs: publish Zigapagos pairing guide` with the implementation.

## Task 2 — Package the official skill

- Initialize `zigbase-zigapagos-fullstack` with standard skill metadata.
- Keep its main workflow concise and route detailed facts to copied canonical references.
- Copy the pairing, agents, testing, deployment, and OpenAPI guides byte-for-byte.
- Add UI metadata with an explicit `$zigbase-zigapagos-fullstack` default prompt.
- Commit: `feat: add Zigapagos full-stack skill`.

## Task 3 — Make distribution fail closed

- Extend the official skill test module with structure, metadata, exact-reference, unexpected-file,
  and mutation coverage.
- Link the guide and skill from repository and public-site discovery surfaces.
- Add the guide to the generated docs registry and navigation.
- Add a changelog fragment.
- Commit: `docs: publish Zigapagos pairing workflow`.

## Task 4 — Verify the executable reference

- Run the skill creator's validator and the repository's strict skill tests.
- Run Blog `zigbase.testing`, TypeScript typecheck/E2E, and browser journey.
- Run public-site build, strict doctor, static/generated checks, and browser smoke.
- Run full Zig and Python regression suites, formatting, gating, allocator contracts, and
  `git diff --check`.
- Record any defect as a focused checkpoint commit before rerunning its affected boundary.

## Task 5 — Re-audit remaining program boundaries

- Confirm the pairing deliverable closes SP-6's implementable repository work.
- Leave SDK registry publication untouched without explicit release credentials/authorization.
- Keep Rails marked externally gated; sequence the Express migration skill next only after a
  separate design/plan cycle rather than folding a new migration source into this deliverable.
