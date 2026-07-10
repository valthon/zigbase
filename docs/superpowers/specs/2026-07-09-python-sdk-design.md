# Python Client SDK — Design

**Date:** 2026-07-09
**Status:** Approved (brainstorm with owner)
**Decision:** Next two SDK programs are **Python, then Kotlin** (sequenced, not parallel). This spec covers the Python program; Kotlin gets its own brainstorm/spec after Python SP3 ships (open question deferred there: Kotlin Multiplatform vs plain JVM).

## Why Python

- Largest developer audience not covered by the existing TS (web/Node/RN/Electron) and Dart (Flutter) SDKs.
- The AI-agent/scripting/data-tooling ecosystem reaches for Python first; generated Pydantic models export JSON Schema, which plugs directly into LLM tool-calling frameworks.
- Dogfood synergy: the repo's own `tests/admin/` pytest harness can progressively adopt the SDK for API setup calls, exercising it continuously.

## Program shape

Mirror the proven three-tier ladder from the TS and Dart SDKs, one PR stream per tier, all under `clients/python/`:

1. **SP1 — base client**: auth (JWT password + OAuth2/PKCE helpers), records CRUD, query vocabulary (filter/sort/expand), cursor pagination, file upload/download, error mapping.
2. **SP2 — realtime**: WebSocket subscribe tier.
3. **SP3 — typed tier**: Python emitter for the existing server typegen pipeline; generated Pydantic v2 models + typed collection accessors.

## Packaging & versioning

- Location: `clients/python/`, published to PyPI as **`zigbase`**.
- Publishing via PyPI OIDC trusted publisher (as with npm/pub.dev); the actual first publish may be deferred, as was done for the Dart SDK's pub.dev release.
- Independently versioned: own `CHANGELOG.md` + `RELEASING.md`, released on a **`python-client-v*`** tag.
- Python floor: **≥3.10** (broad reach for the scripting audience); developed/tested under the mise-pinned Python 3.13.
- Dependency policy: the base SDK depends on **httpx only**. `websockets` arrives with SP2. Pydantic is required only by the typed tier: it ships as the optional extra **`zigbase[typed]`**, and generated code imports it — running generated output without the extra installed fails with a clear ImportError.

## Architecture — async-core, dual surface

- One shared request-building core: URL/query/filter construction, auth token state, error mapping. No I/O in the core.
- Two thin transports over httpx (the openai/anthropic SDK pattern):
  - `ZigBase` — sync, over `httpx.Client`.
  - `AsyncZigBase` — async, over `httpx.AsyncClient`.
- Base tier returns plain dicts (parity with the TS base client's loose objects).
- Wire semantics follow the house API conventions: `{items}` list envelopes, cursor pagination (`cursor`/`limit` → `nextCursor`/`hasNext`), 204 for side-effect success, and the same filter/sort/expand query vocabulary as the TS/Dart clients.

## Realtime (SP2)

- **Async-only initially**, via the `websockets` library.
- Semantics mirror the Dart live tier: subscribe by collection/record, auto-reconnect with backoff, auth re-send on reconnect.
- The sync facade documents realtime as async-only. A thread-backed sync convenience wrapper is out of scope until demand appears (YAGNI).

## Typed tier (SP3)

- New **Python emitter** in the server's existing typegen pipeline (the one that generates the TS and Dart typed clients).
- Emits Pydantic v2 models per collection plus typed collection accessors wrapping the base client (both sync and async surfaces).
- Generated models provide runtime validation of server responses, clean serialization, and JSON Schema export (the LLM tool-calling hook).
- Same golden-file / format-stability gating as the Dart typed tier.

## Testing

- Unit tests against a mocked httpx transport (no network).
- An e2e CI job modeled on the existing `ts-sdk` job: build the server binary, launch it, run the SDK suite against it.
- Follow-up (not gating SP1): migrate `tests/admin/` API setup helpers onto the SDK for continuous dogfooding.

## Docs & sync obligations (every PR)

- `docs/python-sdk.md` + hand-synced site mirror under `site/src/content/docs/`.
- Root README and cross-SDK parity notes.
- `changelog.d/` fragment per PR (SDK-visible changes go in the SDK's own changelog; repo fragments for anything consumer-facing on the server side).

## Out of scope

- Kotlin SDK (next program; own spec).
- SSE transport (tracked separately server-side).
- Sync realtime wrapper.
- pub-style first publish timing — decided at release time.
