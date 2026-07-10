# Kotlin Client SDK — Design

**Date:** 2026-07-10
**Status:** Approved (brainstorm with owner; platform and coordinates decided by owner)
**Context:** Fourth client SDK, following TypeScript, Dart, and Python (all three tiers of each shipped). The roadmap decision "Python, then Kotlin" was made 2026-07-09; this spec resolves the questions deferred from that session.

## Owner decisions

- **Platform: plain Kotlin/JVM** — one Maven artifact covering native Android apps and JVM backends. KMP explicitly rejected for now (Flutter already covers cross-platform mobile; KMP's build/publishing tax outweighs its marginal audience). Code stays KMP-friendly (no JVM-only APIs in core logic; ktor is multiplatform-ready) so a later expansion is cheap.
- **Maven coordinates: `io.github.valthon:zigbase-client`** (GitHub-verified Sonatype namespace, zero setup friction; a branded group can come later).

## Stack

- Kotlin (latest stable), JDK 17 floor, Android-compatible bytecode (no JDK-18+ APIs).
- **ktor-client** for HTTP and WebSocket (engine pluggable; CIO engine default on JVM, MockEngine in unit tests).
- **kotlinx.serialization** for JSON.
- **Coroutines throughout**: suspend functions for requests; `Flow` for realtime streaming.
- Gradle (Kotlin DSL), version catalog; ktlint or ktfmt as the format gate (pick one in the plan; it also serves as the typed-tier golden formatter, per the Dart/Python delegate-to-the-formatter pattern).

## Program shape — three tiers, one PR-stream each, in `clients/kotlin/`

1. **KSP1 — base client**: auth (password, refresh, OAuth2/PKCE, sessions, verification/reset, change-password re-auth semantics), records CRUD (PATCH updates, 204 semantics, abilities), offset + cursor pagination (opaque tokens, non-advancing-cursor protection, iterate/getFullList), injection-safe filter builder (named placeholders + `filterValue` chokepoint), multipart auto-detection files, files/accounts/analytics/senders services, auth stores (memory + file with 0600 atomic writes), 401 single-flight refresh + 429 backoff (all methods) transport state machines.
2. **KSP2 — realtime**: WebSocket frame protocol (auth/subscribe/unsubscribe uplink; connect/auth/ack/error/event/signal/message downlink), ack-gated subscriptions with the r:/t: key scheme, auth lifecycle (reused auth-ack detached-before-settle, re-auth on store change, empty-token de-auth), reconnect with 250ms→10s backoff gated on live subscriptions, `Flow`-based streaming with clean cancellation semantics, custom broadcast topics.
3. **KSP3 — typed**: `zigbase typegen --lang kotlin` — a fourth emitter trio in the Zig pipeline (mirroring gen_dart/gen_python), generating kotlinx-serializable data classes with fromRecord coercion, Create/Update payloads with toMap wire encoding, fields builders over a hand-written typed runtime (`zigbase.typed` equivalent: meta, Dart-parity coercers incl. int-raises-on-fractional and ROUND_HALF_UP fixed rendering, Expr/FieldExpr DSL, TypedCollection, Flow-based typed realtime), golden-gated in CI (formatter-delegated, regeneration-idempotent), dating-fixture e2e. RPC emission out of scope (TS-only, matching Dart/Python).

## Parity contract (same as Dart/Python)

TS SDK is normative on wire behavior; accumulated hardenings carried: loud rejection of non-encodable/non-finite operands, byte-parity number/date rendering, every filter operand through one escaping chokepoint, malformed-error-data skipping, explicit close/ownership contract, clear errors on non-object 2xx bodies and missing mandatory token fields, fire-and-forget guards on realtime sends, reconnect gated on live subscriptions, discriminating e2e assertions with negative controls. Documented divergences only where Kotlin demands (e.g. structured concurrency scope ownership for the realtime service — the plan decides whether the consumer supplies a CoroutineScope or the client owns one; whichever is chosen must make close/cancel semantics explicit).

## Packaging & release

- `clients/kotlin/` with own CHANGELOG.md (`[Unreleased]` client convention), RELEASING.md, LICENSE (Apache-2.0 copy).
- Independent versioning from 0.1.0; release tag prefix **`kotlin-client-v*`**.
- First Maven Central publish DEFERRED (like pub.dev/PyPI): RELEASING.md documents Sonatype central-portal namespace verification for io.github.valthon and the publish workflow; no tag until the owner initiates.
- CI: `kotlin-sdk` job mirroring the sibling SDK jobs (needs: build, prebuilt `zigbase-binaries` artifact, Gradle cache, format+lint gate, unit tests, live integration; dating binary + golden gate arrive with KSP3). Toolchain via mise where possible (java/gradle) — the plan verifies mise support and falls back to setup-java if needed.

## Testing discipline (established house rules)

- Unit tests against ktor MockEngine; byte-parity fixture tests for filter/date/number rendering; transport state-machine tests with injectable delays (no wall-clock sleeps); concurrency tests deterministic (no timing margins where avoidable).
- Live integration against the server binary launched per-suite (free port, temp dir), run twice for flakes; typed e2e vs dating-server in KSP3 with sabotage-checked discriminating assertions and negative controls.
- Golden regeneration idempotency enforced locally and in CI.

## Out of scope

- KMP targets (future expansion; keep code KMP-friendly).
- RPC / typed custom-auth emission (TS-only across all SDKs today).
- SSE transport; request-key dedup (matches Python's documented divergence — decide in the plan whether Kotlin ports TS's requestKey or documents the same divergence; lean divergence for consistency with the newest SDKs).
- First Maven publish timing.
