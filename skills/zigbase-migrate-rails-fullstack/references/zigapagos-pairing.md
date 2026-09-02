# Zigapagos + ZigBase full-stack pairing

ZigBase and Zigapagos pair at a narrow, explicit seam: Zigapagos builds a static frontend, and the
application's ZigBase binary serves that release after its API, admin, and custom routes. The
result is one deployable origin with server-enforced policy and no production CORS requirement.

The [Blog example](../examples/blog/) is the executable reference. It combines a framework-mode
ZigBase backend, Zigapagos pages and islands, the TypeScript client, in-process authorization
tests, HTTP integration tests, and a browser journey.

## Ownership boundaries

Keep each invariant in the system that can enforce it:

| Concern | Owner |
| --- | --- |
| Collections, validation, access rules, auth | ZigBase |
| Trusted derived fields and state transitions | ZigBase hooks and typed routes |
| Pages, layouts, islands, frontend assets | Zigapagos |
| API transport and auth state | `@zigbase/client` |
| Public-rule rationale | `security/public-rules.json` |
| Static-tree links, metadata, and asset integrity | `zigapagos doctor` |

An island may hide a button, but that is presentation, not authorization. Every protected action
still needs a server rule or route authorization check and both an allowed and denied backend test.

Intentional public signup is supported. An auth collection's anonymous create rule is reported as
a production-doctor warning, not an error. Record its exact collection, operation, rule, and reason
in `security/public-rules.json`; the durable acknowledgment makes the warning reviewable without
weakening enforcement or hiding newly public operations.

## Project shape

A common framework-mode layout is:

```text
app/
├── build.zig
├── build.zig.zon
├── src/main.zig
├── security/public-rules.json
├── frontend/
│   ├── zigapagos.ziggy
│   ├── content/
│   ├── layouts/
│   ├── assets/
│   └── dist/                 # generated, ignored
└── test/
```

Create the backend and frontend independently so either tool remains replaceable:

```sh
npx zigbase init --framework --dir app --name app
cd app
zig fetch --save git+https://github.com/valthon/zigbase
mkdir frontend
cd frontend
npx --yes --package zigapagos@0.4.0 -- zigapagos init
```

Pin Zigapagos in the repository's launcher or package scripts. Pin ZigBase through
`build.zig.zon`; do not leave a copied `.path = "../.."` dependency in a real consumer project.

## Build the seam

Build the frontend release into `frontend/dist`, then build the application binary:

```sh
cd frontend
npx --yes --package zigapagos@0.4.0 -- zigapagos release --output=dist --force
cd ..
mise exec zig@0.16.0 -- zig build
```

For the most flexible development/deployment shape, leave the framework's static-files mode at
its default and pass the release directory at runtime:

```sh
ZIGBASE_PUBLIC_URL=http://127.0.0.1:8090 \
  ./zig-out/bin/app serve --insecure-cookies \
  --data-dir ./zb_data --serve-static frontend/dist
```

For a fixed runtime layout, configure `.static_files = .{ .dir = "frontend/dist" }`. For a true
single-file artifact, use `zigbase.embedStaticDir` in `build.zig` and
`.static_files = .{ .embedded = &static_assets.files }`. Embedded assets must be rebuilt whenever
the frontend changes. See `docs/recipes.md` for the exact build-helper wiring.

API and admin routes are dispatched before static fallback. Use relative client URLs such as
`/api/collections/posts/records`; same-origin cookies, CSRF, and realtime then work without a CORS
exception. Plain HTTP local development needs `--insecure-cookies`. Production must not.

## Development loop

Zigapagos can run the built consumer binary rather than its stock backend:

```sh
mise exec zig@0.16.0 -- zig build
cd frontend
ZIGAPAGOS_DEV_BACKGROUND=0 ZIGBASE_SERVE_BACKGROUND=0 \
  npx --yes --package zigapagos@0.4.0 -- zigapagos dev \
  --site=dist --data-dir=../zb_data --zigbase=../zig-out/bin/app \
  --watch-dir=content --watch-dir=layouts --watch-dir=assets
```

The explicit custom binary matters: Zigapagos's stock ZigBase binary cannot contain your comptime
collections, hooks, routes, jobs, or feature configuration. In an AI-agent environment both dev
servers may auto-background; foreground-owned harnesses set both background variables to `0` so
teardown owns the real child. Interactive agent work may intentionally use background mode and
the corresponding `status`, `logs`, and `stop` commands.

## Frontend client contract

Use the base `@zigbase/client` when the schema is still moving, or generate a typed client from the
application binary when the boundary is stable. The framework build must opt in with
`.enable_typegen = true`; the scaffold does not enable type generation by default. Treat that flag
as a deliberate generated-client boundary and keep its output under review. The binary must also
retain the default `-Ddev-tools=true` build setting:

```sh
./zig-out/bin/app typegen --data-dir ./zb_data --out frontend/src/zbase.gen.ts
./zig-out/bin/app openapi --data-dir ./zb_data --out frontend/openapi.json \
  --title "App API" --server https://app.example.com
```

Do not generate from an empty or stale data directory. Framework collections are provisioned on
server boot; OpenAPI/type generation inspects the live logical collection model and does not boot
or provision the application for you.

Never expose passwords, token keys, path secrets, superuser credentials, or server-only hidden
fields through frontend configuration. OpenAPI redacts credential material, but generated output
still deserves review before publication.

## Test the layers separately

The reference matrix is deliberately redundant:

```sh
# Server policy, hooks, routes, and deterministic behavior without a socket
mise exec zig@0.16.0 -- zig build test --summary all

# Frontend static analysis and release integrity
cd frontend
npx --yes --package zigapagos@0.4.0 -- zigapagos validate --format=json
npx --yes --package zigapagos@0.4.0 -- zigapagos release --output=dist --force
npx --yes --package zigapagos@0.4.0 -- zigapagos doctor dist --format=json
cd ..

# SDK type safety and real HTTP transport
npm run typecheck
ZIGBASE_SERVE_BACKGROUND=0 npm run test:e2e

# Real page, cookies, navigation, and user journey
ZIGBASE_SERVE_BACKGROUND=0 npm run test:browser
```

`zigbase.testing` is the fast authority for allow/deny cases. Transport tests prove the socket and
SDK wire. Browser tests prove cookie behavior and the rendered journey. `zigapagos doctor` sees
only the static tree, so a link such as `/_/` may be an explained warning when the runtime ZigBase
binary owns that route; do not broadly suppress other dangling links.

For a generic command runner, Zigapagos can own the temporary server lifecycle:

```sh
cd frontend
ZIGBASE_SERVE_BACKGROUND=0 \
  npx --yes --package zigapagos@0.4.0 -- zigapagos e2e \
  --site=dist --zigbase=../zig-out/bin/app -- node ../test/smoke.mjs
```

The command receives `ZIGAPAGOS_ORIGIN`. Keep application data temporary unless the test is
explicitly about upgrades or persisted state.

## Ship gate

Before deployment:

1. Build the exact frontend and backend artifacts that will ship.
2. Run every layer above and generate the OpenAPI handoff artifact.
3. Run `./zig-out/bin/app doctor --production --json --data-dir ./zb_data`.
4. Reconcile every public-rule warning with `security/public-rules.json`; an unacknowledged public
   operation blocks launch.
5. Keep secure cookies, persistent JWT material, HTTPS termination, real email, backups, restore
   rehearsal, and one SQLite process. Use PostgreSQL before adding application replicas.

The frontend and backend may deploy separately, but same-origin reverse proxying remains the
simplest secure topology. If they use different origins, configure CORS, trusted proxy behavior,
cookie policy, and realtime origins explicitly and add a browser test for that deployment shape.
