# Python Client SDK SP2 (Realtime Tier) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the realtime (WebSocket) tier of the Python SDK: `AsyncZigBase.realtime` — subscribe/stream over the server's frame protocol with ack-gated subscribes, auth lifecycle, reconnect/backoff, and custom broadcast topics — async-only, as an optional `zigbase[realtime]` extra.

**Architecture:** One `RealtimeService` (asyncio) in `clients/python/src/zigbase/realtime.py`, structurally ported from Dart's `realtime.dart` (injectable async connector, lazy client getter, `on_error` hook, `stream()`) with the TS `realtime.ts` protocol subtleties preserved exactly (reused auth-ack detached-before-settle, `r:`/`t:` prefix subscription keys, `reconnect_pending` gating, error-frame drops pending entries). The receive loop is an `asyncio.Task`; Promises/Completers become `asyncio.Future`s.

**Tech Stack:** Python ≥3.10, `websockets>=13` (optional extra `realtime` only), pytest-asyncio (already configured), fake in-memory connector for unit tests, live server binary for integration tests.

**Normative references:** `clients/typescript/src/realtime.ts` is authoritative for wire behavior and state-machine edge cases; `clients/dart/lib/src/realtime.dart` is the structural template for an async runtime (both agree byte-for-byte on frames). The server protocol is `src/realtime/protocol.zig` (grammar), `ws.zig`, `hub.zig`, `connection.zig`; docs `docs/api.md` §realtime. The design spec is `docs/superpowers/specs/2026-07-09-python-sdk-design.md` (SP2 section).

## Global Constraints

- Path `clients/python/`; all commands `mise exec python@3.13 -- python -m <cmd>` from `clients/python/`; Python floor 3.10.
- Base install stays httpx-only. `websockets>=13` ships ONLY as the optional extra **`zigbase[realtime]`**; importing `zigbase.realtime` without it raises a clear ImportError telling the user to `pip install 'zigbase[realtime]'`.
- Realtime is **async-only**: it lives on `AsyncZigBase.realtime`. Accessing `ZigBase.realtime` raises `RuntimeError` with a pointer to `AsyncZigBase` (documented divergence per the spec).
- Wire frames (byte parity with TS/Dart):
  - uplink `{"action":"auth","token":"<jwt-or-empty>"}` / `{"action":"subscribe","topic":t,"filter":f}` (filter key OMITTED when None) / `{"action":"unsubscribe","topic":t}`
  - downlink dispatched on `type`: `connect`(clientId), `auth`(status ok|error), `ack`(action,topic), `error`(message), `event`(topic,action create|update|delete,record — delete record is `{"id":...}` only), `signal`(topic), `message`(topic,data).
  - Malformed JSON / non-object / unknown `type` / missing topic on event-signal-message → silently dropped.
- URL mapping: `base_url` http→ws, https→wss, strip trailing slashes, append `/api/realtime`. Send NO Origin header, NO cookies, NO token in the URL — auth is a post-connect frame only.
- Backoff: `delay = min(10.0, 0.25 * 2**attempts)` seconds, NO jitter, attempts reset on successful open, guard the shift for attempts ≥ 30. Injectable `_asleep` module-level (pattern from `_transport.py`).
- Subscription keys: record subs `f"r:{topic}"` or `f"r:{topic} {filter}"`, custom-topic subs `f"t:{topic}"` — the disjoint-prefix scheme from TS realtime.ts (regression-tested there against topic/filter collision).
- Auth-ack future is REUSED across back-to-back auth sends and detached before settling so a superseded late response no-ops; auth failures never reject caller work — they surface via `on_error` only.
- `AuthStore.on_change` callbacks in this SDK take **two args** `(token, record)` — use `token` verbatim from the event (do not re-read the store).
- **Known-limitation parity (do NOT fix divergently):** a still-pending (unacked) subscribe whose entry is removed during a reconnect-backoff window never settles its future — same documented behavior as TS realtime.ts:154 / Dart realtime.dart:253; document it in the module docstring.
- Gates at every commit from `clients/python/`: `ruff format --check .`, `ruff check .`, `mypy src` (strict), `pytest -m "not integration" -q`. TDD (RED before GREEN) for every task.
- Commits `feat(python-sdk): ...`/`test(python-sdk): ...` ending with the Claude co-author trailer. Module docstrings name the TS/Dart counterparts.
- Follow-up NOT in scope: SSE transport, sync thread-backed bridge, client-side publish (server has none), replay/resume (server has none).

---

### Task 1: Frame codec, event types, fake connector, packaging

**Files:**
- Create: `src/zigbase/realtime.py` (types + codec portion), `tests/support/__init__.py`, `tests/support/fake_connector.py`, `tests/test_realtime_frames.py`
- Modify: `pyproject.toml` (add `realtime = ["websockets>=13"]` to `[project.optional-dependencies]`)

**Interfaces (Produces):**
```python
# realtime.py — port of clients/typescript/src/realtime.ts + clients/dart/lib/src/realtime.dart
@dataclass(frozen=True)
class RealtimeEvent:
    topic: str
    action: str                 # "create" | "update" | "delete"
    record: dict[str, Any]      # delete → {"id": ...} only

@dataclass(frozen=True)
class TopicMessage:
    topic: str
    kind: str                   # "signal" | "message"
    data: Any | None            # None for signal

def encode_auth(token: str) -> str: ...
def encode_subscribe(topic: str, filter: str | None) -> str: ...   # filter key omitted when None
def encode_unsubscribe(topic: str) -> str: ...
def decode_frame(raw: str | bytes) -> dict[str, Any] | None: ...   # None = drop (malformed/non-object)
def realtime_url(base_url: str) -> str: ...                        # http(s) → ws(s) + /api/realtime

# Connector contract (Dart WebSocketConnector shape, asyncio-flavored):
# Callable[[str], Awaitable[RealtimeConnection]] where
class RealtimeConnection(Protocol):
    async def send(self, data: str) -> None: ...
    def recv(self) -> AsyncIterator[str | bytes]: ...   # or: __aiter__ over incoming messages
    async def close(self) -> None: ...
```
```python
# tests/support/fake_connector.py — port of clients/dart/test/support/fake_socket.dart
class FakeConnection:   # implements RealtimeConnection
    sent: list[dict[str, Any]]            # JSON-decoded uplink frames
    subscribe_frames: list[dict[str, Any]]
    unsubscribe_frames: list[dict[str, Any]]
    async def push(self, frame: dict[str, Any]) -> None: ...   # server→client
    async def server_close(self) -> None: ...                  # simulate drop
class FakeConnectorFactory:
    connections: list[FakeConnection]
    pending_failures: int                  # next N connects raise ConnectionError
    gate: asyncio.Event | None             # when set, connect parks until gated open
    async def connect(self, url: str) -> FakeConnection: ...
    @property
    def last(self) -> FakeConnection: ...
```

Frame-codec rules are in Global Constraints. `decode_frame` returns the parsed dict for ANY object (dispatch/validation happens in the service) and `None` for non-JSON/non-object.

- [ ] **Step 1: Write failing tests** — encode_auth/subscribe (with and without filter — assert the `filter` key is absent, not null)/unsubscribe exact JSON; decode_frame drops malformed JSON, arrays, numbers; realtime_url for http/https/trailing-slash bases; FakeConnector round-trip (push → recv yields; send → sent captures decoded).
- [ ] **Step 2: Run `pytest tests/test_realtime_frames.py -q`, verify FAIL.**
- [ ] **Step 3: Implement codec portion of realtime.py + fake connector + pyproject extra.** Guard the `websockets` import: only the default connector needs it — put `import websockets` inside the default-connector factory function so unit tests (fake connector) run without the extra installed; raise the clear ImportError there.
- [ ] **Step 4: Run all gates, verify PASS.**
- [ ] **Step 5: Commit** (`feat(python-sdk): realtime frame codec and test connector`)

---

### Task 2: RealtimeService core — connect, subscribe/unsubscribe, ack gating

**Files:**
- Modify: `src/zigbase/realtime.py` (service class), Create: `tests/test_realtime_subscribe.py`

**Interfaces (Produces):**
```python
RecordCallback = Callable[[RealtimeEvent], Any]        # sync fn or coroutine fn — awaited if coroutine
TopicCallback = Callable[[TopicMessage], Any]
Unsubscribe = Callable[[], Awaitable[None]]

class RealtimeService:
    def __init__(self, base_url: str, auth_store: AuthStore, *,
                 connector: Callable[[str], Awaitable[RealtimeConnection]] | None = None,
                 on_error: Callable[[str], None] | None = None) -> None: ...
    async def subscribe(self, topic: str, callback: RecordCallback, *, filter: str | None = None) -> Unsubscribe: ...
    async def unsubscribe(self, topic: str, callback: RecordCallback | None = None,
                          filter: str | None = None) -> None: ...
    async def subscribe_topic(self, topic: str, callback: TopicCallback) -> Unsubscribe: ...
    async def unsubscribe_topic(self, topic: str, callback: TopicCallback | None = None) -> None: ...
    async def close(self) -> None: ...
    @property
    def client_id(self) -> str | None: ...
```

State machine (port TS `ensureConnected`/`onOpen`/`onMessage` exactly):
- Lazy connect on first subscribe; `ensure_connected` no-ops when `connection or connecting or reconnect_pending`.
- Receive loop = one `asyncio.Task` per connection iterating `recv()`, dispatching decoded frames.
- `subscribe`: register sub in the keyed map (+ pending `asyncio.Future`), `ensure_connected()`, send frame only `if opened and not inflight` (inflight dedups concurrent subscribers of one key onto one frame; all join `pending` and settle on the single `ack`). Await ack before returning; return an `Unsubscribe` closure.
- `ack` frames are keyed by topic string: mark every sub of that topic acked, settle pending futures.
- `unsubscribe(topic, callback=None, filter=None)`: filter=None removes the callback from every filter-variant; the `unsubscribe` frame is sent once, only when the topic's LAST variant is removed. Idempotent.
- `event` frames dispatch to record callbacks of that exact topic (both `collection` and `collection/id` subs are separate topics — no client-side fanout); callbacks that are coroutine functions are awaited; a raising callback must not kill the receive loop (suppress + `on_error`).
- `signal`/`message` dispatch to topic callbacks as `TopicMessage(topic, kind=type, data)`.
- `close()`: sets closed_by_user, cancels the receive task, closes the connection, settles nothing (pending subscribes raise `ZigbaseError(status=0, "realtime client closed")`), detaches the auth-store listener (Task 3). Post-close `subscribe`/`subscribe_topic` raises `ZigbaseError(status=0, ...)` — raises, never hangs.

- [ ] **Step 1: Write failing tests** (fake connector; every test asserts on `sent`/decoded frames or callback invocations, not internals): lazy connect on first subscribe; ack-gated subscribe resolves; concurrent subscribe of same topic+filter sends ONE frame, both callbacks fire on one event; distinct filters are distinct variants (two frames); event dispatch topic-exact; delete event carries id-only record; unsubscribe of one variant keeps others (no frame) / last variant sends frame; unsubscribe with callback=None+filter=None clears all variants; subscribe_topic/`t:`-prefix isolation from a record sub crafted as `subscribe("", filter="topic:x")` (the TS regression test); raising callback doesn't kill the loop and hits on_error; post-close subscribe raises; close cancels cleanly.
- [ ] **Step 2: Run, verify FAIL.**
- [ ] **Step 3: Implement the service core.**
- [ ] **Step 4: Run all gates, verify PASS.**
- [ ] **Step 5: Commit** (`feat(python-sdk): realtime service core with ack-gated subscriptions`)

---

### Task 3: Auth lifecycle

**Files:**
- Modify: `src/zigbase/realtime.py`, Create: `tests/test_realtime_auth.py`

Behavior (port TS `sendAuth`/auth-ack handling exactly):
- On open: if `auth_store.token` present, send auth frame FIRST and gate `resubscribe_all` on `{"type":"auth","status":"ok"}`; anonymous → resubscribe immediately. Auth `"error"` on open: surface via `on_error`, still resubscribe (matches TS — public subs must work).
- Auth-store listener registered at service construction: `on_change` fires with `(token, record)`; while opened, send `encode_auth(token or "")` — logout (token None) sends the EMPTY-token de-auth frame. Use the event's token verbatim.
- The auth-ack `asyncio.Future` is REUSED across back-to-back sends; on an `auth` frame, detach it before settling so a superseded late reply no-ops. Rapid login/logout must not strand a waiter (test it).
- Auth failures never reject subscribe/caller futures — `on_error` only.
- `close()` unregisters the on_change listener (use the unsubscribe fn `on_change` returns).
- Default `on_error` when the consumer passes None: `logging.getLogger("zigbase.realtime").warning(...)` (Dart's default-logger pattern — errors are never silently dropped).

- [ ] **Step 1: Write failing tests** — auth frame precedes subscribe frames on open when token present; anonymous open sends no auth frame; resubscribe gated on auth ok (subscribe frame NOT sent until the auth ack is pushed); token change while open sends new auth frame with the event token; logout sends empty-token frame; rapid re-auth (two changes before any reply) settles cleanly when replies arrive; auth error frame → on_error called, subscribes still proceed; close detaches listener (auth_store.save after close sends nothing).
- [ ] **Step 2: Run, verify FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run all gates, verify PASS.**
- [ ] **Step 5: Commit** (`feat(python-sdk): realtime auth lifecycle`)

---

### Task 4: Reconnect, backoff, error frames

**Files:**
- Modify: `src/zigbase/realtime.py`, Create: `tests/test_realtime_reconnect.py`

Behavior (port TS `reconnect`/`onErrorFrame` exactly):
- Unexpected close (recv loop ends or raises, not closed_by_user) → schedule reconnect: `reconnect_pending=True`, `await _asleep(min(10.0, 0.25 * 2**attempts))`, attempts+=1 per attempt, reset to 0 on successful open; wrap the sleep+connect in try/finally so a throwing sleep/connect never wedges `reconnect_pending` (surface via on_error, schedule next attempt).
- On reconnect open: auth-first (Task 3), then `resubscribe_all` — every sub marked unacked, its subscribe frame re-sent.
- Subscribe during backoff: registers + waits, does NOT open a second socket (`reconnect_pending` gate) — the pending sub is sent by resubscribe_all.
- Server `error` frame (no topic): reject EVERY unacked pending subscribe future with `ZigbaseError(status=0, message=<frame message or "realtime error">)`, DELETE those sub entries (a later reconnect must not silently resubscribe them), call `on_error`.
- `close()` during backoff cancels the pending reconnect task; `closed_by_user` stops all reconnection.
- Module-level `_asleep = asyncio.sleep` (monkeypatch in tests — no wall-clock waits).

- [ ] **Step 1: Write failing tests** — unexpected close reconnects (fake sleep captures 0.25) and re-sends auth+subscribe frames on the new connection; backoff doubles across consecutive failures (0.25, 0.5, 1.0 captured) and caps at 10.0; attempts reset after successful open; subscribe during backoff creates no second connection (factory.connections length stays 1 until the gated reconnect proceeds); error frame rejects pending subscribe with ZigbaseError status 0 AND a subsequent reconnect does not re-send that topic; throwing injected sleep hits on_error and does not wedge (next close still reconnects); close during backoff stops everything (no further connects).
- [ ] **Step 2: Run, verify FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run all gates, verify PASS (plus run the reconnect test file 5x for flakes: `pytest tests/test_realtime_reconnect.py -q --count 5` is unavailable — just loop it in shell 5x).**
- [ ] **Step 5: Commit** (`feat(python-sdk): realtime reconnect and error handling`)

---

### Task 5: stream() async iterator

**Files:**
- Modify: `src/zigbase/realtime.py`, Create: `tests/test_realtime_stream.py`

**Interfaces (Produces):**
```python
def stream(self, topic: str, *, filter: str | None = None) -> AsyncIterator[RealtimeEvent]: ...
```
Port of Dart's `stream()` semantics on asyncio: an async generator that subscribes on first iteration (`asyncio.Queue` fed by an internal callback), yields `RealtimeEvent`s, and unsubscribes when the consumer stops iterating — including `aclose()` on the generator and cancellation mid-ack (Dart: cancel-before-ack tears down without unhandled errors). A rejected subscribe (error frame) raises the `ZigbaseError` out of the iterator. `close()` on the service ends all live streams (StopAsyncIteration, not an exception — Dart's close-completes-controllers behavior).

- [ ] **Step 1: Write failing tests** — `async for` receives pushed events; generator aclose() sends unsubscribe (when last variant); cancel-before-ack tears down cleanly (no pending-task warnings — assert via asyncio debug/unraisable hooks or by draining tasks); rejected subscribe raises ZigbaseError from the iterator; service close() ends iteration without exception.
- [ ] **Step 2: Run, verify FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run all gates, verify PASS.**
- [ ] **Step 5: Commit** (`feat(python-sdk): realtime stream iterator`)

---

### Task 6: Client wiring + default websockets connector

**Files:**
- Modify: `src/zigbase/client.py`, `src/zigbase/realtime.py` (default connector), `src/zigbase/__init__.py` (export `RealtimeEvent`, `TopicMessage`)
- Create: `tests/test_realtime_wiring.py`

Behavior:
- `AsyncZigBase.realtime` — lazy property constructing ONE `RealtimeService(base_url, auth_store, connector=self._realtime_connector, on_error=self._on_realtime_error)`; new constructor kwargs on AsyncZigBase: `realtime_connector=None` (test injection), `on_realtime_error=None`. `aclose()` also closes the realtime service if it was created; `with_account` siblings get their OWN lazy realtime service (subscriptions are per-connection identity).
- `ZigBase.realtime` — property that raises `RuntimeError("Realtime is async-only; use AsyncZigBase")` (exact message can vary, must name AsyncZigBase).
- Default connector (module-level factory in realtime.py): imports `websockets` lazily; missing dep → `ImportError` naming `pip install 'zigbase[realtime]'`. Wraps `websockets.connect(url)` into the `RealtimeConnection` protocol (its client objects already provide `send`/`recv` iteration/`close` — adapt shapes). Send no extra headers.
- Docstrings updated; `RealtimeEvent`/`TopicMessage` exported from `zigbase.__init__` (they're type-annotation surface; the service comes via the client property).

- [ ] **Step 1: Write failing tests** — AsyncZigBase.realtime returns the same instance twice; injected fake connector is used (subscribe round-trip through the facade); aclose() closes realtime (fake connection sees close); sync ZigBase.realtime raises RuntimeError naming AsyncZigBase; ImportError message test via monkeypatching the websockets import to fail (simulate missing extra); with_account sibling has a distinct realtime service.
- [ ] **Step 2: Run, verify FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run all gates, verify PASS.**
- [ ] **Step 5: Commit** (`feat(python-sdk): wire realtime into AsyncZigBase`)

---

### Task 7: Live-server integration tests

**Files:**
- Create: `tests/integration/test_realtime_live.py`
- Modify: `tests/integration/conftest.py` ONLY if a fixture needs generalizing (do not disturb existing tests)

Consumes the existing SP1 integration harness (`ZIGBASE_TEST_BINARY`, session server, bootstrapped `feed` @public collection and `members` auth collection — read `tests/integration/conftest.py` first). Mirror `clients/dart/test/integration/integration_test.dart` realtime coverage (~L235-300) and the TS `realtime.integration.test.ts`:
- subscribe to `feed` → REST-create a record → event `create` arrives with the record (10s timeout via `asyncio.wait_for`).
- subscribe to `feed/<id>` → update → `update` event on the record topic; delete → `delete` event with id-only record (dedupe note: collection + record topics get separate frames — assert both when subscribed to both).
- auth-gated: subscribe to `members` anonymously → rejected (`ZigbaseError`, "authentication required to subscribe"); after `auth_with_password`, subscribe succeeds and an own-record update arrives (viewRule `@request.auth.id = id`).
- filter: subscribe to `feed` with a `zb_filter` expression; matching create delivers, non-matching doesn't (assert via a second matching event arriving AFTER the non-matching one — ordering-free negative check).
- stream(): `async for` one event then break; assert unsubscribe frame behavior indirectly (no further events → cannot assert directly on live; just assert the break tears down without warnings).
- Build the binary first if absent: `mise exec zig@0.16.0 -- zig build` from the worktree root. Run the suite twice for flakes. Websockets dep: integration env installs `.[dev,realtime]`.

- [ ] **Step 1: Write the live tests (harness-first smoke: connect + subscribe ack).**
- [ ] **Step 2: Run twice (`ZIGBASE_TEST_BINARY=$PWD/zig-out/bin/zigbase mise exec python@3.13 -- python -m pytest clients/python/tests/integration -q -m integration` from the worktree root); fix SDK bugs surfaced (own commits + unit tests each).**
- [ ] **Step 3: Verify unit suite untouched and green.**
- [ ] **Step 4: Commit** (`test(python-sdk): realtime live-server integration tests`)

---

### Task 8: CI, docs, changelog, packaging polish

**Files:**
- Modify: `.github/workflows/ci.yml` (python-sdk job: install `-e 'clients/python[dev,realtime]'`), `.github/workflows/release-python-sdk.yml` (verify job install likewise), `clients/python/README.md` (realtime section), `clients/python/CHANGELOG.md` ([Unreleased] realtime entry), `docs/python-sdk.md` (+ site mirror `site/src/content/docs/python-sdk.md`) — replace the "realtime coming in SP2" divergence note with a full Realtime section modeled on `docs/dart-sdk.md` §Realtime (subscribe/unsubscribe, stream, custom topics signal/message, auth lifecycle incl. silent-token-expiry caveat and the re-auth-on-store-change behavior, reconnect semantics + re-fetch guidance, backpressure disconnect note, `[realtime]` extra install).
- Create: `changelog.d/python-sdk-realtime.md`:
```markdown
### Features

- Python SDK realtime tier (`zigbase[realtime]`): `AsyncZigBase.realtime` with ack-gated `subscribe`/`unsubscribe`, `stream()` async iteration, custom broadcast topics (`signal`/`message`), automatic re-auth on auth-store changes, and exponential-backoff reconnection with full resubscribe.
```

- [ ] **Step 1: Write all doc/CI changes.** Site mirror keeps the frontmatter+link-rewrite-only divergence (diff against the dart mirror pair to confirm the pattern). Verify the site builds (`cd site && mise exec node@24 -- npm run build`) and the realtime section renders.
- [ ] **Step 2: Validate workflow YAML (python -c yaml.safe_load both files); run the four gates + full unit suite.**
- [ ] **Step 3: Snippet audit — every realtime code sample in README/docs uses the real API names from Tasks 2-6 (subscribe/subscribe_topic/stream/close, RealtimeEvent fields).**
- [ ] **Step 4: Commit** (`docs(python-sdk): realtime docs, CI extra, changelog fragment`)

---

## Self-review notes (applied)

- Spec coverage: SP2 section of the design spec = "WebSocket subscribe tier, async-only, websockets lib, Dart live-tier semantics (subscribe by collection/record, auto-reconnect, auth re-send)" — Tasks 1-6; "sync facade documents realtime as async-only" — Task 6 (RuntimeError) + Task 8 (docs); dogfood/CI — Tasks 7-8. Custom topics (signal/message) shipped server-side post-spec and are part of TS/Dart parity — included (Tasks 2, 5, 8).
- Type consistency: `RealtimeConnection`/connector (T1) consumed by T2/T6; `RealtimeEvent`/`TopicMessage` (T1) consumed by T2/T5/T6/T8; `Unsubscribe` (T2) used by T5's teardown; `_asleep` naming matches the `_transport.py` precedent.
- Placeholders: none; every step names exact frames, delays, prefixes, and messages or points at the precise normative file section.
