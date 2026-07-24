### Fixes

- Made several framework helpers self-freeing under any allocator (allocator ownership contracts 1
  & 2), removing latent scratch/result leaks that were reclaimed only when the caller passed a
  request/job arena — as every in-tree call site does, so deployed servers were unaffected, but the
  leaks were real for a general-purpose-allocator caller:
  - `sms/twilio.zig` `TwilioSender.send` now routes its URL/auth/body build **and** the `HttpClient`
    response scratch (a fixed `max_response_bytes` buffer that has no `deinit`) through a
    function-local arena.
  - `analytics/analytics.zig` `runRollup` builds its summary-table/watermark/aggregation-SQL scratch
    on a function-local arena.
  - `api/senders.zig` `listBody` builds its intermediate JSON envelope on a function-local arena
    (only the stringified body escapes).
  - `queue/durable.zig` `claimBatch` self-frees its dynamic `IN (…)` SQL scratch and returns an
    owned `[]Claimed` freed via the new `freeClaimed` (contract-2), with per-row error-path cleanup.
  - `authz/abilities.zig` `abilityPredicate` drops a leaked `allocPrint` intermediate and adds
    error-path frees for its predicate buffers.
  - `auth/challenge_store.zig` `takeByIdentity` frees its intermediate challenge id (previously
    leaked on every call), and `put` frees the generated id on a mid-insert error.
  - `route_types.zig` typed-route dispatch thunk (`makeThunk`) now frees its params view and — the
    real fix — keeps and deinits the JSON `Parsed` handle it previously discarded (`parseFromSlice(…).value`),
    which leaked that parse arena; only the serialized response body escapes.

### Internal

- Restored leak detection across the SMS, analytics, sender-identity, durable-queue, row-ability,
  auth-challenge, and typed-route subsystems: converted their arena-masked unit tests to the raw
  `std.testing.allocator` (typed-route thunk tests via `RequestArena.forTest`), removing nine files
  from `scripts/allocator-allowlist.txt`.
- Un-masked auth credential prep + OAuth-link tests: the 11 `applyCreate`/`applyProvision`/`applyUpdate`
  tests in `auth.zig` now free their result via the existing `freeProvisioned` under the raw
  allocator (`auth.zig` 17→6, the remainder being the deferred `verifyToken`/`authenticate` family);
  `api/oauth.zig`'s external-auth-link test is un-masked after making its `seedOAuthCollection`
  helper self-free its encrypted-secret blob + created collection (6→5); and two non-handler
  outliers in `api/auth.zig` (a dead unused arena + a transient-session-id backlog test) drop their
  masks (42→40). The remaining `api/auth.zig`/`api/oauth.zig` entries are genuine
  RequestArena/Response handler tests; `server.zig`'s multipart tests are reclassified as genuine
  contract-4 (the `Extracted` graph borrows from the request body with no tracked owned/borrowed
  split).
