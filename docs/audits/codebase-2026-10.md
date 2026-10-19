# Codebase audit: October 2026

Audit base: `751a15d453a4` (main). The review used separate core/runtime,
HTTP/authentication, and SDK/tooling reviewers, followed by adversarial review
and implementation agents. Existing local audit notes from the same revision
were treated as leads and checked against source before implementation.

## Coverage and limits

The review followed authentication and CSRF enforcement, OAuth identity linking,
passkey registration and challenge consumption, record querying and relation
authorization, expansion ownership, cursor codecs, SQLite preparation, durable
upload state transitions, reader-pool transaction cleanup, SDK transports and
live-filter evaluation, and the CI workflow. It did not read every source line
in the repository or audit vendored dependencies. Source inspection, focused
regressions, full local gates, and hosted CI are distinct evidence; none implies
that every possible defect has been found.

## Accepted findings and implementation scope

| Priority | Concern | Resolution and regression requirement |
| --- | --- | --- |
| High | OAuth identity resolution used a linked record ID without retaining its auth collection. Collections with matching imported IDs could resolve another collection's account. | Compare the stored link collection with the loaded canonical collection before returning the ID. Preserve global provider identity uniqueness and collection ID aliases. Cover anonymous and authenticated cross-collection attempts. |
| High | Passkey registration retained the authenticated ID but discarded its collection, permitting enrollment against a different collection with the same imported ID. | Require the authenticated collection to match the canonical target collection before ceremony access. Cover both begin and finish, and retain same-collection registration. |
| High hardening | Client relation filter/sort joins could inspect fields in targets whose view policy would prevent expansion. | Conservatively reject client traversal through restricted targets; preserve trusted access-rule joins. Cover cached prefixes, conditional policies, tenant/ability restrictions, TTL, public targets and superusers. Fully policy-scoped joins remain a separate design task. |
| High hardening | Realtime client filters were compiled together with trusted view rules, allowing hidden-field predicates to act as a boolean oracle over fields absent from client records. | Validate client filters independently at subscription time and retain delivery-time checks. Reject hidden fields and restricted relation hops while preserving operator-authored view-rule traversal. |
| Medium | Expansion placed borrowed keys into owned JSON graphs and leaked metadata/partial results under ordinary allocators. | Separate temporary metadata lifetime from owned output, handle partial construction, and exercise normal destructors with the raw testing allocator and allocation failure injection. |
| Medium | Expansion paths sharing a head overwrote each other's descendants. | Combine descendant requests before fetching a head. Cover ordering, duplicates, direct plus nested requests and multi-relations. |
| Medium | Stateless and signed cursor encoders could emit tokens larger than their decoder accepts. | Check final wire length and return a clear client error; preserve stateful mode and avoid truncating sort values. Cover size boundaries and HTTP mapping. |
| Medium | Python retries re-read already-consumed file streams, producing empty uploads. | Buffer a logical request body once while rebuilding authentication headers per attempt. Cover non-seekable streams, sync/async, overload retries and auth refresh. |
| Medium | TypeScript and Dart live filters decoded newline/tab/carriage-return escapes incorrectly. | Match the server's supported escapes and reject malformed strings. Cover serializer/parser/evaluator round trips. |
| Medium | TypeScript and Dart treated field-to-field predicates as locally evaluable despite evaluating their RHS incorrectly; valid server grammar outside their local parser could also throw during live-list construction. | Refetch field-to-field and unsupported local predicates while retaining the original server query and its errors. Cover offset/cursor event refetch, malformed barewords and carriage-return whitespace. |
| Medium reliability | Delayed 401 responses could start another refresh after a concurrent request had already refreshed credentials. | Compare the token actually sent with shared credentials under refresh coordination. Cover delayed responses and genuine subsequent expiry. Token equality does not promise single refresh when the server returns an identical token. |
| Low hardening | Registration challenge consumption did not bind the ceremony to the authenticated collection and account. | Add atomic scoped consumption that leaves mismatches unconsumed. Cover wrong owner, collection, method, expiry and replay. This alone is not an unauthenticated takeover. |
| Low | Interpolating the configured passkey RP display name could produce invalid JSON. | Serialize typed options; cover quotes, backslashes and control characters without changing the protocol shape. |
| Low | SQLite can successfully prepare empty/comment-only SQL with a null statement. | Return a preparation error instead of force-unwrapping. Cover empty, whitespace and comment-only SQL. |

The identity findings require overlapping IDs across auth collections; default
random IDs reduce likelihood, while import deliberately supports preserved IDs.
Existing verification, MFA and lifecycle hooks still apply. The relation-query
change is deliberately conservative and changes accepted client query behavior;
see the API reference for its compatibility implications.

## Adversarial dispositions

- Reader transaction leakage was downgraded: current production callers clean up
  their explicit reader transactions, including closing a reader on rollback
  failure. A pool invariant check is defensive hardening, not a demonstrated bug.
- Durable-upload poisoning after a persistence error is an intentional recovery
  policy. It was not relabeled as corruption or a newly discovered vulnerability.
- The raw committing-session pointer is an internal ownership hazard; no HTTP
  exploit or existing misuse was established.
- Built-in route access metadata is not uniformly the dispatch enforcement point,
  but inspected sensitive handlers enforce authentication. No bypass was found.
- Default GET bodies and malformed auth-refresh responses have compatibility
  implications. They were not changed solely because a stricter API was possible.
- A large numeric Retry-After is a server-directed delay, while the existing cap
  describes fallback backoff. A bounded policy needs an explicit SDK contract;
  it was not silently introduced as a security fix.
- The stale-401 finding demonstrates redundant refresh work. Logout or account
  takeover was not established and is not claimed.
- Request context does not identify a query as client input. Hooks, jobs, queues
  and webhooks also pass identity context; client-query mode must be explicit so
  server-authored relation traversal retains its trusted behavior.
- Expansion descendant coalescing re-scans a bounded request specification.
  Changing it without a measured cost would add complexity; resource-budget
  measurement remains on the deferred list.

## Deferred todo list

- [ ] **High: development dependency security migration.** `npm audit --json`
  in `clients/typescript` reports eight affected packages, including critical
  Vitest/Tinypool advisories. These are development dependencies; no deployed
  ZigBase server exploit was established. Upgrade the test/build stack in a
  dedicated migration that validates the bounded runner, SDK builds and all
  example suites together, rather than forcing incompatible transitive versions.
  The [Vitest advisory](https://github.com/advisories/GHSA-5xrq-8626-4rwp)
  concerns exposed UI/API servers and Windows UI/browser use; the
  [Tinypool advisory](https://github.com/advisories/GHSA-85c8-ppgw-ccpr)
  concerns prototype-polluted run options. Check reachability and refresh the
  audit results during that migration. This PR does not claim these are fixed.
- [ ] **High: policy-scoped relation joins.** Design alias-safe, parameter-bound
  target policy predicates in JOIN ON, including tenants, abilities, TTL and
  multi-hop traversal. Do not place them in the base WHERE or weaken trusted
  access rules. Current conservative rejection is the bounded mitigation.
- [ ] **Medium: cross-SDK conformance cases.** Share language-neutral examples
  for retry headers, cancellation, malformed refresh bodies, multipart retries,
  filter grammar and refresh races. Keep each SDK's idiomatic implementation;
  cross-language source-code abstraction would add more coupling than it removes.
- [ ] **Medium: local LIKE parity.** Establish server and SDK behavior for case,
  wildcard escaping and null values before expanding local filter evaluation.
- [ ] **Medium: Python upload resource policy.** File bodies are buffered once per
  logical request without a separate SDK byte limit, including for async calls.
  Design bounded streaming/replay support for seekable and non-seekable sources
  together, and move blocking async file reads off the event loop. Rewinding only
  seekable files would leave non-seekable retries without a safe replay strategy.
- [ ] **Medium: expansion resource budgets.** Measure broad/deep expansion costs
  before adding fetch caching or larger request trees. Mutable returned graphs
  must remain independently owned per record.
- [ ] **Medium: route policy inventory.** Add a reviewed inventory connecting
  built-in access declarations, handler enforcement and tenant guards before
  migrating enforcement into common dispatch. Avoid double authentication.
- [ ] **Low: reader-pool transaction contract.** Consider rejecting or closing
  returned readers with active transactions, with explicit failure semantics.
- [ ] **Low: upload lease API.** Replace raw committing-session pointers with a
  scoped lease only alongside lifecycle/concurrency tests and caller migration.
- [ ] **Low: durable-upload recovery coverage.** Assert all operations fail after
  poisoning and document restart/recovery expectations; recovery must not weaken
  the persist-before-acknowledgement invariant.
- [ ] **Low: retry policy.** Decide whether SDKs should expose a maximum total
  wait or maximum Retry-After independently of exponential backoff.
- [ ] **Low: transport modularization.** Extract Python transport body handling
  only if future changes justify the boundary; buffering fixes do not require
  splitting the entire transport. Remove duplicate helpers with contract tests.

These follow-ups are recommendations, not hidden requirements for this PR.
No unresolved product choice was needed for the scoped fixes. Container-backed
lanes require hosted CI because this environment has no Docker daemon.
