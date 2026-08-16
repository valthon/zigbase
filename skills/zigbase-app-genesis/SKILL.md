---
name: zigbase-app-genesis
description: Turn a product idea into a secure, tested, deployable ZigBase application. Use when designing a new ZigBase backend, choosing box versus framework mode, modeling collections and relations, writing access rules, implementing the first vertical slice, reviewing an app before launch, or preparing a ZigBase deployment.
---

# ZigBase App Genesis

Move from product intent to a working vertical slice without losing the authorization model between design, implementation, tests, and deployment.

## Load the right references

Read `references/app-genesis.md` and `references/agents.md` before designing or changing an app. They define the judgment workflow and the stable ZigBase contract.

Read only the additional references the task needs:

- `references/testing.md` before creating or changing tests.
- `references/openapi.md` when generating, reviewing, or handing off the HTTP contract.
- `references/serve.md` before running, diagnosing, or configuring a server.
- `references/deployment.md` and `references/docker.md` before producing deployment files or
  launch advice. Custom non-root images must create a writable `/data` mountpoint before `USER`.

The copied references are authoritative for this skill. If the repository also contains canonical `docs/` versions, do not silently combine versions that differ; report the mismatch.

## 1. Discover the product boundary

Inspect the existing repository, its instructions, and its current schema before proposing changes. Convert the request into a compact set of journeys: subject, action, resource, and the fact that authorizes the action. Identify values the client must never authoritatively supply, including ownership, tenancy, approval state, and derived prices.

Ask only for a missing choice that materially changes the trust boundary or product behavior. Otherwise state a reversible assumption and proceed with the smallest useful vertical slice.

## 2. Design before scaffolding

Choose box mode when schema, rules, validation, files, auth, realtime, and SDK composition are enough. Choose framework mode only for trusted server behavior such as session-derived fields, cross-record transitions, atomic side-writes, typed commands, jobs, or custom HTTP semantics.

Write down before implementation:

- collections, field ownership, relations, delete behavior, and indexes;
- list, view, create, update, and delete rules for every collection;
- the intended cursor sort and expansion paths;
- hooks, routes, jobs, or cron work and why schema/rules cannot express them;
- allow and deny cases at every authorization boundary; and
- whether realtime improves an already-open user journey.

Default every operation to locked. Use exact `@public` only for intentional anonymous access, and record every such rule in `security/public-rules.json` with its rationale. Treat that inventory as review evidence, never as authorization.

## 3. Implement one complete slice

Prefer the repository's existing toolchain and generated structure. Build authentication plus one owned resource or one business transition before broadening the model. Keep ordinary CRUD on the collection API; use a custom route only for a genuine command or non-CRUD HTTP behavior.

Place each invariant in the narrowest trusted seam:

- field shape in schema validation;
- visibility and authorization in rules;
- record stamping or bounded write mutation in `before*` hooks;
- committed reactions in `after*` hooks;
- explicit state transitions in typed routes;
- slow or retryable work in durable jobs.

Use cursor pagination for changing user-facing lists. Prefer relations plus `expand`; denormalize only with an explicit consistency policy.

## 4. Prove the boundaries

Add tests as part of the slice, not after it. Use `zigbase.testing` for schema, rules, auth, hooks, routes, migrations, and deterministic behavior. For each protected operation include at least one allowed actor and one denied actor. Use a spawned server or browser only when the behavior depends on the HTTP transport or browser state.

When the user asks for an application rather than only a backend or API, include the thinnest client-facing journey that proves the product boundary and give it a project-declared integration or browser test command. Keep browser transport tests distinct from in-process authorization tests; neither substitutes for the other.

Run focused tests first, then the repository's broader relevant checks. Do not claim a check passed unless it ran in the current workspace. Reconcile every production-doctor public-rule finding with `security/public-rules.json`; an unreviewed public rule blocks launch.

## 5. Make deployment reproducible

When launch is in scope, pin the ZigBase version, persist the data directory and JWT secret, keep one SQLite process, terminate TLS in front of ZigBase, configure real email, and run `zigbase doctor --production`. Use PostgreSQL before application replicas. Provide backup, restore-rehearsal, upgrade, rollback, health, and continuous-monitoring steps appropriate to the target platform.

If a production-shaped deployment must also run locally, do not weaken its cookie or public-origin settings for loopback HTTP. Use a separate test-only server profile for insecure local cookies and keep the Compose artifact behind its documented HTTPS termination boundary.

Do not deploy or mutate external infrastructure unless the user authorized it. A local Docker deployment may satisfy a reproducible-deployment requirement when no external target was requested.

## Handoff

Report the implemented journeys, authorization decisions, artifacts changed, and checks actually run. Call out remaining assumptions, deliberate public access, warnings accepted by policy, and any manual deployment or browser verification still required.
