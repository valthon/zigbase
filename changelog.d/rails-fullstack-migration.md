### Features

- Add the full Rails migration skill and guide, with a deterministic coordinator that reconciles Rails backend inventory, ZigBase OpenAPI and replay evidence, and Zigapagos presentation handoffs into one versioned route map, including explicit reviewed method-change rationale, producer-derived endpoint access, fail-closed released-schema validation, route-local blocker codes, and distinct input-failure and incomplete-proof exit codes.

### Breaking

- Enforce one literal route grammar across dispatch and OpenAPI: paths must be canonical absolute ASCII paths without trailing or repeated slashes, dot segments, percent escapes, or repeated/non-identifier capture names; methods must be concrete rather than `.UNKNOWN`; and `path_secret.param` must name an actual capture. Normalize affected paths, rename captures, select a concrete method, and align the secret parameter before upgrading.
- Reserve every enabled engine, admin, feature-state, WebSocket, and SSE route during application compilation. Move a colliding custom or feature route rather than shadowing an engine-owned endpoint.
- Require explicit consumer route names to be Zig identifiers and prevent explicit or derived names from colliding with another consumer or built-in operation. Derived names sanitize ordinary URI punctuation and leading digits (for example, `/robots.txt` becomes `robotsTxt` and `/api/2fa/verify` becomes `_2faVerify`); use `.name` only to resolve a genuine collision or an otherwise empty derived name.

### Changed

- Validate predeclared replay controls before `zb_replay record` sends any requests, and reject empty, non-string, or status-incompatible controls without leaving a partial capture.
- Mark exported OpenAPI collection operations with `x-zigbase-collection` and `x-zigbase-collection-type` so migration tooling can use the contract's collection identity and distinguish auth and base collections without parsing URLs.
- Write recorded replay captures and findings atomically with private `0600` permissions, preserving the previous complete artifact when validation or serialization fails.
- Atomically replace Rails converter JSON artifacts with deterministic permissions, preserve the previous complete artifact when serialization fails, and refuse an existing symlink destination instead of silently changing its target or replacement semantics.
- Export authoritative built-in route, explicit compile-time gate, gate-aware engine prefix, and auth-operation metadata in OpenAPI; keep consumer auth gates separate from path-bound resource collection markers; and reconcile custom routes without shadowing engine handlers or the enabled admin namespace.
- Make feature-state `HEAD` responses bodyless with GET-equivalent representation metadata, export a fixed OpenAPI contract-format version, reject consumer collisions with the feature-state route at compile time, and keep draft custom routes from shadowing enabled engine handlers.
- Treat capture segments as overlaps when reserving the enabled admin prefix, and reject custom endpoint methods that ZigBase cannot declare.
- Require each compound Rails verb expression to be split into independently reviewable routes before reconciliation can claim completion, and apply protected-mutation evidence rules to the selected replacement method as well as the source method.
- Forward only safe representation headers across replay redirects to another origin, and require the production doctor process itself to succeed before evaluation can accept its report.
- Keep the observed Rails exporter compatible with Ruby 2.7, omit Rails-generated HABTM implementation classes, and assign distinct stable decisions to distinct conditional validators without duplicating identical semantics.
- Generate the decided ZigBase schema independently of source-row access, and extract PostgreSQL Rails rows through one credential-safe, repeatable-read, read-only snapshot instead of sending PostgreSQL migrations to a manual NDJSON fallback.
- Keep Rails index names and unbounded multi-file attachments valid in the emitted ZigBase schema, and validate manifest dry runs as one cross-collection transaction so relation targets and deferred patches are exercised before the whole run rolls back.
- Treat presentation parser failures and implausible zero-route discovery as failures even when an adapter exits successfully, and compare handoff contracts by schema identity and validated wire shape rather than descriptive annotation bytes.
- Require clean presentation builds whose routing and HTML references resolve to emitted SPA,
  island, and runtime assets; generator exit status alone is not accepted as migration evidence.
- Inspect PostgreSQL triggers and views, recover OmniAuth provider names from configured
  middleware, classify jobs by application source, and carry one reviewed conventional identity
  mapping through auth NDJSON for `--external-auths` without selecting OAuth credentials.
- Require presentation auth journeys to match the observed Rails credential mechanism instead of
  treating a generated password form as a replacement for an OmniAuth-only application.
- Refuse to account a Zigapagos backend route away as blocked: backend implementation, OpenAPI,
  access rules, and replay are now a hard phase gate before presentation conversion.
- Treat missing live OAuth credentials as a launch-verification gap rather than a backend blocker;
  configure provider plumbing, external identities, UI, and mock-provider coverage while other
  backend routes continue independently.
- Require migrated auth collections to receive provider options through the applied schema or an
  explicit schema migration; additive consumer provisioning does not retrofit existing auth
  options, so the live provider endpoint must be checked.
- Refuse “conservative” omission of concrete Rails associations that carry ownership or
  authorization, surface timestamp-manifest relation cycles before backend completion, and
  distinguish WebAuthn passkey login from OAuth-followed-by-WebAuthn step-up.
- Add import-manifest v2 entry-local `preserveTimestamps` policy and emit one Rails data manifest,
  allowing the existing two-pass importer to restore relation cycles between timestamped and
  timestamp-less collections without flattening the graph or fabricating dates.
- Distinguish an accounted all-blocked handoff from a produced replacement and require zero-page
  generated targets to satisfy the same clean-build gate.

### Internal

- Lint the replay tool and its tests in CI.
