# Changelog

All notable changes to `zigbase` (the Python client) are documented here. The format is
based on [Keep a Changelog](https://keepachangelog.com/), and this package adheres to
[Semantic Versioning](https://semver.org/).

Unlike the ZigBase server's `CHANGELOG.md` (which never carries an `## [Unreleased]`
section between releases), this client changelog keeps one — SDK releases are cut
independently and less frequently, so accumulating entries here between tags is more
useful than a fragment-file pipeline.

## [Unreleased]

Initial development of the official Python client for ZigBase — a behavioral port of
`@zigbase/client` (the TypeScript SDK) to Python, cross-checked against `zigbase_client`
(the Dart SDK), targeting Python 3.10+ with both a synchronous (`ZigBase`, over
`httpx.Client`) and an `asyncio` (`AsyncZigBase`, over `httpx.AsyncClient`) facade.

### Added

- **Records.** `CollectionService`/`AsyncCollectionService` CRUD (`get_list`, `get_one`,
  `get_first_list_item`, `create`, `update`, `delete`) with offset pagination, and native
  server-side cursor (keyset) pagination (`get_page`, `iterate`, `get_full_list` — which
  abort with a clear `ZigbaseError` rather than looping forever on a non-advancing server
  cursor).
- **Safe filters.** `zb_filter`/`filter_value` — injection-safe interpolation of `{:name}`
  placeholders into filter expressions, byte-matching the TypeScript/Dart SDKs' escaping
  and number/date formatting.
- **Search & vector.** `search` on every list read; `vector_spec` nearest-neighbor search
  (`-Dvector` server builds).
- **Auth.** Password auth, OAuth2 Authorization-Code + PKCE (`pkce.generate_code_verifier`,
  `pkce.code_challenge_s256`), email verification, password reset, self-service
  `change_password`, and per-device session management (`list_sessions`/`revoke_session`/
  `revoke_all_sessions`).
- **Auth stores.** `MemoryAuthStore` (default, in-memory) and `FileAuthStore` (JSON-file
  persistence for CLI/script use across process runs).
- **`auto_refresh`.** Opt-in single-flight 401 auto-refresh on both facades.
- **Multi-tenancy.** `account_id`/`with_account(id)` request scoping and
  `AccountsService.activate(id)`.
- **Abilities.** `get_abilities(id)` for per-record view/update/delete permission checks.
- **Analytics.** `AnalyticsService.events`/`.rollup` reads over the tenant-scoped activity
  feed.
- **Senders.** `SendersService.list`/`create`/`verify` for verified From-address
  management.
- **Files.** `FilesService.get_url`/`get_url_for`/`get_token`; `create`/`update` bodies
  auto-switch to `multipart/form-data` when they contain a file value (a file-like object,
  or a `(filename, bytes)`/`(filename, bytes, content_type)` tuple).
- **Escape hatch.** `send()` (parsed JSON, auth/retry/error-mapping applied) and
  `raw_request()` (the raw `httpx.Response`, no parsing or error mapping) for any endpoint
  the typed surface doesn't cover.
- **Packaging.** PEP 561 `py.typed` marker — the package ships inline type hints
  (`mypy --strict`-checked) for downstream type checkers.
- **Realtime (`zigbase[realtime]`).** `AsyncZigBase.realtime` with ack-gated
  `subscribe`/`unsubscribe`, `stream()` async iteration, custom broadcast topics
  (`subscribe_topic`/`unsubscribe_topic`, `signal`/`message`), automatic re-auth on
  `auth_store` changes, and exponential-backoff reconnection with full resubscribe.
  `asyncio`-only — `ZigBase.realtime` raises `RuntimeError` naming `AsyncZigBase`.

### Known limitations

- **No live-store tier yet.** The Dart/TypeScript SDKs'
  `realtime.collection()`/`LiveRecord`/`LiveList` observables have no Python equivalent yet;
  only the base subscribe/stream/topic API ships in this release.
- **No request-key de-duplication.** The TypeScript/Dart SDKs' opt-in `requestKey`
  last-write-wins cancellation has no Python equivalent yet; use `httpx`'s own
  cancellation (e.g. `asyncio.wait_for`/task cancellation for `AsyncZigBase`) at the call
  site instead.

[Unreleased]: https://github.com/valthon/zigbase/tree/main/clients/python
