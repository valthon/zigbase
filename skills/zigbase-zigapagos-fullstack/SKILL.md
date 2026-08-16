---
name: zigbase-zigapagos-fullstack
description: Build, test, or deploy a full-stack application that pairs a ZigBase framework backend with a Zigapagos frontend. Use for new same-origin ZigBase and Zigapagos apps, adding a Zigapagos UI to an existing ZigBase service, wiring the TypeScript client, choosing runtime versus embedded static assets, creating full-stack tests, or reviewing the security and deployment boundary between the two projects.
---

# ZigBase + Zigapagos Full Stack

Read `references/zigapagos-pairing.md` before designing or changing the pairing. It is the
canonical command, topology, test, and deployment contract.

## 1. Inspect both halves

Read the repository instructions, ZigBase schema/rules/hooks/routes, Zigapagos config and content,
client wiring, build scripts, and existing tests. Write down the user journey and the server fact
that authorizes every protected action.

Keep backend and frontend independently replaceable. ZigBase owns data, auth, validation, policy,
and trusted behavior. Zigapagos owns pages, layouts, islands, and static release integrity. Treat
frontend visibility checks as presentation only.

## 2. Choose the serving shape

Prefer one origin. Build `frontend/dist` and serve it from the application's ZigBase binary so
relative `/api/...` calls, cookies, CSRF, and realtime share an origin.

Use runtime `--serve-static frontend/dist` while iterating. Use comptime directory mode only for a
fixed runtime layout. Use embedded assets for a true single binary and ensure every frontend change
rebuilds the Zig executable.

Never use Zigapagos's stock ZigBase binary when the app depends on comptime collections, hooks,
routes, jobs, or configuration. Pass the built consumer binary to Zigapagos dev and E2E commands.

## 3. Implement one vertical slice

Build one complete journey at a time:

1. Define collections, rules, and trusted mutations.
2. Add an in-process allowed and denied backend test.
3. Build the smallest page/island flow through `@zigbase/client`.
4. Add a transport test for the real binary and SDK.
5. Add a browser test when cookies, navigation, rendering, or realtime matters.

Default access to locked. Use exact `@public` only for intentional anonymous access. Public signup
is valid: anonymous auth-record creation is a production-doctor warning, not an error. Record its
exact rule and rationale in `security/public-rules.json`; do not suppress unrelated findings.

## 4. Keep the dev loop ownable

Build the consumer binary before launching Zigapagos. In a foreground-owned harness, set both
`ZIGAPAGOS_DEV_BACKGROUND=0` and `ZIGBASE_SERVE_BACKGROUND=0` so teardown controls the real child.
Use `--insecure-cookies` only for local plain HTTP.

Generate typed clients and OpenAPI from a live, provisioned logical schema. Do not publish generated
output before checking for hidden fields or sensitive metadata.

## 5. Verify and ship

Run each independent layer: Zig in-process tests, Zigapagos validate/release/doctor, TypeScript
typecheck, HTTP E2E, and the browser journey. An explained static-doctor warning for a runtime-owned
route such as `/_/` does not justify ignoring other dangling links.

Before launch, run the application binary's `doctor --production --json`, reconcile every public
rule with the durable inventory, and verify the exact frontend/backend artifacts that will ship.
Keep secure cookies, persistent JWT material, HTTPS, email, backups, and the one-process SQLite
constraint; move to PostgreSQL before replicas.

## Handoff

Report the implemented journey, server authorization boundary, serving/deployment shape, generated
contract artifacts, deliberate public access, checks actually run, and any remaining manual release
or infrastructure action. Do not publish packages or deploy without explicit authorization.
