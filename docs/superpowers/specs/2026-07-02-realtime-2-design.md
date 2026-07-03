# SP3 Theme C — Realtime round 2: SSE transport (#188) + cross-instance custom topics

Baseline: `origin/main @ 1bd02c4`. Inputs: issue #188, the SSE plumbing spike
(`spike-sse.md`, verdict **feasible-thin-adapter, zero zap/facil.io changes**), and
`src/realtime/{ws,hub,connection,protocol,pg_bridge}.zig` at that commit.

## Goal

1. **SSE as a second realtime transport.** An `EventSource` (no SDK) can connect to
   `GET /api/realtime/sse`, authenticate and subscribe via `POST /api/realtime/sse/:clientId`,
   and receive record events, signals, and message broadcasts — with per-delivery
   `viewRule`/tenancy/delete-snapshot authorization running through the *same* code the WS
   path runs (`hub.shouldDeliver`, hub.zig:37). SSE is a pipe under the existing hub, not a
   protocol fork. The WS wire behavior is byte-for-byte untouched.
2. **Cross-instance custom topics on Postgres.** `ctx.realtime().signal(topic)` and
   `ctx.realtime().broadcast(topic, payload)` fan out to all app instances sharing one
   Postgres — closing the documented per-instance limitation (framework.md:910,
   realtime-broadcast.md tail) — without ever putting payload bytes in a `NOTIFY`.
3. Dual-transport e2e delivery matrix + a real two-process LISTEN/NOTIFY e2e in CI.

## Non-goals

- **`Last-Event-ID` replay / backfill: deferred** (rationale in §3 — this is a written
  decision, not a punt).
- **SDK `transport: 'auto'` fallback heuristics.** v1 ships explicit `'ws' | 'sse'`.
  Silent transport switching hides infra problems from operators and complicates support;
  revisit when a user asks for it.
- **Slow-consumer/backpressure guard.** `http_sse_write` is an unbounded enqueue — *exactly
  the WS status quo* (spike §4.3). File a follow-up issue covering `fio_pending()`-based
  high-water-mark closure for **both** transports; not in this theme.
- **Upstream zap `Sse.Handler` PR.** Goodwill follow-up, not on the critical path (spike §2).
- **HTTP/2.** facil.io is HTTP/1.1; browsers cap EventSource at ~6 streams/origin. Documented,
  same constraint PocketBase lives with.
- **Router-side `Accept` fallback.** facil.io dispatches to `on_upgrade("sse")` only on an
  *exact* `Accept: text/event-stream` (spike §1). EventSource always sends it; non-browser
  clients are documented to send it exactly. No `http_upgrade2sse` fallback in the router.

## Default-build impact

**facil.io's SSE machinery is already compiled into every binary today, unconditionally.**
Grounding: SSE support (`http_sse_write`, `http_upgrade2sse`, `http1_sse_ping`,
`http_sse_subscribe`/`unsubscribe`, `http_sse_set_timout`) is not a separable C file behind a
build flag — it's ~215 lines inlined into facil.io's `lib/facil/http/http.c` (the "EventSource
Support (SSE)" section), and `http.c` is added to every zap/zigbase build via a plain
`addCSourceFiles` call with no `#ifdef` around the SSE block. `src/root.zig`/`build.zig`/
`src/server.zig` do nothing to enable or disable it. In other words: the SSE bytes are in
`zig-out/bin/zigbase` **right now**, on `main`, whether or not this theme ships — the spike's
"zero zap/facil.io changes" verdict is a corollary of this. `http.c` as a whole is ~2700 lines/
~88KB; the SSE section is roughly 8% of that file, so on the order of low-single-digit KB of
compiled object code — already paid, already shipped, already in the stock binary.

**What's actually marginal is the ZigBase-side adapter.** The real, addable cost of turning SSE
"on" as a second transport is: the ~120-line typed `sse_fio.zig` wrapper over the externs
(§1.2), the `sse.zig` adapter + registry + per-connection concurrency structures (§1.3, one
struct + a handful of functions), the uplink route (`src/api/realtime.zig`, one handler + one
router entry), and the heartbeat knob plumbing. Call it roughly 400-600 LOC of new framework Zig
across `sse.zig`/`sse_fio.zig`/the uplink handler — no vendored C, no new dependency, no new
build option. The `frameForDelivery`/hub-verb extraction (§1.2) is a wash: it's code that moves
out of `ws.zig`, not code that's added.

**Decision: default-on, not `-Dsse`-gated.** With the marginal cost this small (a few hundred
LOC of pure-Zig adapter code, zero new C, zero new binary-size line item beyond what's already
shipped), gating it behind a comptime flag would cost real value for near-zero lean-build payoff:
the audience this spec is built for — `zigbase serve`, single static binary, zero-config,
`EventSource` with no SDK — is exactly the audience a `-Dsse` flag would inconvenience most
(they're the ones who'd have to discover and pass a build flag to get a *browser-native, no-JS-
library* realtime transport). Contrast with Postgres (a whole alternative storage engine + driver
behind `-Dpostgres`) or a hypothetical alternative HTTP library (a whole competing implementation
behind a flag): those are genuine alternative-choice capabilities where lean-build gating protects
real KB and real dependency surface. SSE here is not an alternative implementation of anything —
it's a thin adapter over machinery the binary already contains. Gating it would be lean-build
theater: the facil.io cost ships either way, so a flag would only add operator friction (another
build-time decision to discover and make) without shrinking the binary in any way a user would
notice. This is consistent with the standing bulk-mail default-build call elsewhere in SP3 (extend
an already-paid-for subsystem default-on rather than fragment it behind a flag).

**facil.io-first, by construction.** This design *uses* three facil.io capabilities rather than
replacing any: pub/sub (`http_sse_subscribe`/`unsubscribe`, the same subscription primitive WS
already rides), SSE writes (`http_sse_write`, a lock-free enqueue — no custom framing/buffering
built on top), and the heartbeat tick (`http1_sse_ping`'s built-in `: ping` comment on protocol
timeout, reused as-is rather than hand-rolling a keepalive timer). Nothing here reimplements or
routes around a facil.io feature; the entire v1 slow-consumer non-goal (§ above) exists precisely
*because* the design inherits facil.io's existing unbounded-enqueue behavior rather than building
a competing backpressure mechanism.

---

## 1. SSE transport design

### 1.1 Wire protocol

**Connect.** `GET /api/realtime/sse` with `Accept: text/event-stream` (exact). facil.io
routes this into the same `on_upgrade` callback the WS upgrade uses, with
`target == "sse"` (spike §1). `ws.handleUpgrade` (ws.zig:191) grows a dispatch:

- `target == "websocket"` + path `/api/realtime` → existing WS path, unchanged.
- `target == "sse"` + path `/api/realtime/sse` → SSE path (below).
- anything else → `404` + `markAsFinished(true)`. This *en passant* fixes the current
  sloppy early-`return` at ws.zig:194 that swallows `"sse"` targets without finishing.

The SSE path reuses, in order: `originAllowed` (ws.zig:143, F12 — same-origin always
allowed, empty allowlist denies cross-origin), the **shared** global connection slot
(`reserveConnectionSlot`, F9 — see §1.4), tenancy capture
(`requestedAccountFromUpgrade`/`cookieValue`, ws.zig:163-181, verbatim reuse), then
`fio.http_upgrade2sse` with `on_open`/`on_close`/`udata` wired to an `SseConn`.

**First frame.** `on_open` writes the standard connect frame
(`protocol.connectFrame`, protocol.zig:62): `{"type":"connect","clientId":"…"}` — as an SSE
`data:` line. The clientId is the uplink capability (§1.3).

**Downlink framing.** Every hub frame is written verbatim as one `data: <json>\n\n` event
via `fio.http_sse_write(.{ .data = frame })`. No `event:`, no `id:`, no `retry:` in v1
(default event name → `EventSource.onmessage`; no `id:` because Last-Event-ID is out).
Frames are `std.json.Stringify` output — newlines are escaped, so each frame is exactly one
`data:` line; no multi-line-splitting hazard. **One frame grammar** across both transports:
event/signal/message/connect/ack/auth/error frames are byte-identical to WS.

**Heartbeats.** Free: facil.io's SSE protocol writes the comment `: ping\n\n` on every
protocol timeout tick (`http1_sse_ping`, spike §1), invisible to EventSource. The interval
defaults to the listener's `ws_timeout` (zap default 40s; `src/server.zig:103` doesn't
override). New knob: `--sse-heartbeat-seconds` / `ZIGBASE_SSE_HEARTBEAT_SECONDS`
(default `0` = inherit the 40s listener timeout; validated at **startup** to `1..=300` when
nonzero, per the hardening-config-validation philosophy — a bad value fails boot, never
runtime). Applied per-connection via `fio.http_sse_set_timout` at open. This exists so the
e2e heartbeat test can run with a 2s tick instead of waiting 40s.

**Uplink.** `POST /api/realtime/sse/:clientId` through the normal router
(`router.zig` route table, handler in new `src/api/realtime.zig`). The body is the *same*
JSON verb grammar the WS socket speaks, parsed by the *same* `protocol.parseClient`
(protocol.zig:26): `auth` / `subscribe` / `unsubscribe`. One uplink protocol, two framings.
Response mapping (single rule, maximally shared with WS semantics):

| Condition | Response |
|---|---|
| unknown, expired, or just-closed clientId | `404`, standard error envelope — **non-oracle**: byte-identical body for never-existed vs. just-closed |
| body fails `parseClient` | `400`, body `{"type":"error","message":"bad message"}` (the frame WS would write) |
| verb processed | `200`, body = the exact protocol frame WS would have written: `{"type":"auth","status":"ok"\|"error"}`, `{"type":"ack",…}`, or `{"type":"error","message":"authentication required to subscribe"\|"unknown collection"\|"subscription limit reached"}` |

The frame body *is* the protocol; HTTP status is just framing. Error-frame outcomes return
`200` deliberately — WS keeps the connection open and replies a frame, and the SDK shares
one frame-handling path across transports.

**Auth, no tokens in URLs.** Identical to WS: the *only* identity path is the `auth` verb
(token in the POST body → `auth.verifyToken` → `conn.setAuth` + tenancy resolve). The auth
cookie is deliberately **not** consulted for identity on either transport (same
cross-site-hijack posture as WS, api.md "cookie is intentionally NOT used"); the signed
`zb_account` tenancy cookie / `X-Account-Id` header at the handshake is honored exactly as
WS does (verified at auth time, never grants scope alone). A bearer token never appears in
any URL. No-SDK flow: `new EventSource('/api/realtime/sse')` → read clientId → `fetch()`
POSTs for auth/subscribe.

**CSRF posture of the uplink.** The clientId is a 32-char crypto-random capability
delivered only on the stream; the stream is Origin-gated (F12) and no CORS headers are
emitted, so a cross-site page can neither read a clientId nor guess one. The auth token
rides the body, so a forged POST without a valid clientId is a 404 and without a token
mutates nothing sensitive.

### 1.2 Transport-neutral extraction — the authz chokepoint stays singular

**What is already transport-agnostic (no changes):** `hub.shouldDeliver` (hub.zig:37-95) —
viewRule + tenancy + subscription filter + delete-snapshot authz (`matchesSnapshot`,
hub.zig:120) — and all of `connection.zig`. Delete events keep authorizing against the
pre-delete at-rest snapshot (`ws.prepareDelete`, ws.zig:466; `hub.delete_snapshot_key`);
this behavior is preserved verbatim and now provably shared.

**New extraction (behavior-preserving refactor, its own PR):**

- `hub.frameForDelivery(alloc, app, conn: *connection.Conn, channel, message) !?[]const u8`
  — the body of `ws.onChannelMessage` (ws.zig:354-416): `__features` verbatim forward,
  custom-topic verbatim forward, collection resolve, frame parse, delete-snapshot
  extraction, `shouldDeliver`, snapshot **strip** + id-only re-serialize. Returns the frame
  to deliver or null. It is *pure* (no write side effect), so both transports reduce to
  `if (frameForDelivery(...)) |f| <transport write>(f)` — the per-transport delivery residue
  is one line and contains zero authz.
- Verb bodies move to hub.zig: `authVerb(app, conn, durable_alloc, token) !bool` (ws.zig:263-286
  body: verifyToken + tenancy resolve + setAuth/clearAuth) and
  `subscribeCheck(app, conn, alloc, topic) SubscribeOutcome` (ws.zig:293-316 body). The pure
  decision helpers `subscribeAuthorized`, `subscribeDecision`, `canSubscribeTopic`
  (ws.zig:71-105) move with them — none import zap. The per-transport residue is only the
  pub/sub primitive (`WS.subscribe`/`fio.websocket_unsubscribe` vs
  `fio.http_sse_subscribe`/`http_sse_unsubscribe` — both return a `usize` sub id, so
  `sub_ids` bookkeeping is identical) plus the reply write.
- `MAX_SUBS`, `MAX_CONNECTIONS`, `reserveConnectionSlot`/`releaseConnectionSlot`,
  `connectionCount` (ws.zig:33-64) hoist to `connection.zig` (already transport-agnostic and
  already in `root.zig`'s test block); `ws.zig` re-exports `MAX_CONNECTIONS` so consumers/tests
  don't move.

Acceptance for the refactor PR: every existing realtime unit test and
`tests/admin/test_realtime.py` passes unchanged; the WS wire is byte-identical.

New files `src/realtime/sse.zig` (adapter+registry) and `src/realtime/sse_fio.zig` (a
~120-line typed wrapper over the `zap.fio` SSE externs — spike §5 "plumbing" task — with an
ABI smoke test) are **added to `root.zig`'s test block** per CLAUDE.md.

### 1.3 clientId, registry, and the concurrency design (the risk item)

**clientId generation.** `crypto.genToken(io, alloc, 32)` (crypto.zig:80) — 32 chars from
the CSPRNG entropy seam, the same generator as the delete-snapshot NOTIFY tokens. Never
sequential, never time-derived. The WS path's 15-char cosmetic `client_id`
(`id.collectionId`) is *unchanged* — it is write-only today and WS needs no uplink
addressing (WS untouched).

**Why SSE needs what WS doesn't.** facil.io serializes all of a WS connection's callbacks
per-connection, so `LiveConn` needs no locks. The SSE uplink is a plain REST request on a
zap worker thread, *outside* facil.io's per-connection serialization, racing deliveries and
`on_close` on reactor threads. Hence: a registry + per-conn mutex + refcount.

**Structures** (all in `src/realtime/sse.zig`):

```zig
pub const SseConn = struct {
    conn: connection.Conn = .{},          // guarded by mu
    mu: std.Thread.Mutex = .{},
    refs: std.atomic.Value(usize),        // base ref (stream+registry) = 1; +1 per pinned uplink
    closed: bool = false,                 // guarded by mu
    sse: *fio.http_sse_s,                 // http_sse_dup'd at open; http_sse_free at last unref
    sub_ids: std.StringHashMapUnmanaged(usize) = .empty, // guarded by mu
    durable: std.heap.ArenaAllocator,     // allocations only under mu; freed at last unref
    app: *App,
    client_id: [32]u8,
    requested_account: []const u8 = "",
};
var registry_mu: std.Thread.Mutex = .{};
var registry: std.StringHashMapUnmanaged(*SseConn) = .empty; // clientId -> conn
```

No reset-per-callback `frame` arena (the WS trick is only safe under fio's serialization —
spike §3); delivery and uplink each use a per-call arena.

**Lock ordering law: `registry_mu` and `conn.mu` are never held simultaneously.** Registry
operations are pointer-only (insert/remove/lookup + `refs.fetchAdd` under `registry_mu`);
all conn-state work happens under `conn.mu` after `registry_mu` is released. This makes
deadlock impossible by construction: there is no second lock to wait on while holding
either. We never call fio APIs that can take another connection's task lock while holding
`conn.mu` (`http_sse_write` is a thread-safe enqueue; `http_sse_subscribe`/`unsubscribe`
take only the sse struct's internal spinlock).

**Lifecycle:**

- **on_open** (reactor, serialized): finish init, `http_sse_dup(sse)`, `refs = 1`, insert
  into registry, *then* write the connect frame. Registry-visible strictly before the client
  can learn the id — a POST with a valid id can never race ahead of registration.
- **uplink** (zap worker): `pin(client_id)` = { lock `registry_mu`; lookup; on hit
  `refs.fetchAdd(1)`; unlock } → miss ⇒ `404`. Then lock `conn.mu`; **if `closed` ⇒ unlock,
  `unref()`, `404`** (indistinguishable from unknown — non-oracle). Otherwise run the shared
  verb under `mu` (including the `http_sse_subscribe`/`unsubscribe` call and the durable-arena
  channel dupe), unlock, `unref()`, return the reply frame. Verbs hold `mu` across their
  bounded DB read (token verify / subscribe authz), which can delay a delivery or `on_close`
  by milliseconds — accepted; it is the simplest correct regime.
- **delivery** (`on_message`, reactor, fio-serialized *against other deliveries and
  on_close* but not against uplink): lock `mu`; if `closed` return; copy the decision
  inputs (hasSub, filter, `requestContext` snapshot) onto the per-call arena; unlock; run
  `hub.frameForDelivery` (DB work) with **no** lock held; `http_sse_write` (lock-free
  enqueue). The identity snapshot stays readable after unlock because the durable arena
  never frees until conn death and `clearAuth` only nulls references. An auth/unsubscribe
  landing between snapshot and write mirrors the WS status quo (an in-flight frame is
  decided under the identity current at decision time) — benign, and identical in class to
  today's publish-then-deliver window.
- **on_close** (reactor): (1) lock `registry_mu`, remove entry, unlock — no *new* uplink can
  pin it after this; (2) lock `mu`, set `closed = true`, unlock — facil.io itself tears down
  the connection's pub/sub subscriptions at socket close (same as WS); (3)
  `releaseConnectionSlot()` exactly once, here and only here; (4) `unref()`.
- **`unref()`**: `refs.fetchSub(1)`; on reaching zero: `durable.deinit()`,
  `fio.http_sse_free(sse)`, `app.allocator.destroy(conn)`.

**The named race — REST subscribe vs. stream closing — is safe in every interleaving:**

- *Uplink pins first, on_close runs before the verb*: `closed` was set under `mu`, uplink's
  `mu` acquisition serializes after, sees `closed`, returns 404. Memory is valid (pin holds
  a ref); the fio handle is valid (`http_sse_dup`).
- *Uplink's subscribe completes first*: the new fio subscription is registered on a live
  uuid; the close a moment later tears it down with the connection's other subscriptions.
  The durably-duped channel string outlives fio's use (freed at last unref).
- *Close wins between pin and `mu`*: same as case one — the `closed` flag under `mu` is the
  single serialization point, and `http_sse_subscribe` is never called after
  `closed = true` because the flag check and the subscribe happen under the same `mu`
  critical section.
- Double-free impossible: exactly one `on_close` (fio guarantee) performs the single
  registry-remove + slot-release + base-unref; uplinks only pair their own pin/unref.

**TTL / reaping.** `on_close` is the single authoritative reap (registry remove + slot
release). The TTL that the issue requires is delivered by the protocol tick: the built-in
`: ping` fires every heartbeat interval, a dead peer fails the write, fio closes the socket
→ `on_close`. Bound ≈ heartbeat interval + kernel retransmit for NAT-silent zombies —
identical to a dead WS peer today. **No sweeper thread in v1**: a second reap path racing
`on_close` is precisely the double-free/ordering hazard this design eliminates, and the
registry cannot leak (every entry's connection either writes successfully or fails a ping
write). A closed-but-briefly-pinned entry already answers 404.

### 1.4 Limits

- Global cap: the **same** `MAX_CONNECTIONS = 10_000` slot counter covers WS + SSE combined
  (issue: mirror WS knobs — it is the same knob). SSE upgrades past the cap → `503`, exactly
  like WS.
- `MAX_SUBS = 256` per connection applies via the shared subscribe verb.
- Browser reality: HTTP/1.1 EventSource ≈ 6 streams/origin — one docs line.

### 1.5 SDK surface (`zigbase-ts-sdk` repo, its own PR)

- `withRealtime(zb, { transport?: 'ws' | 'sse' })`, default `'ws'` (zero behavior change for
  existing consumers). The typed layer (`makeTypedRealtime`, typegen output) is unaffected —
  transport is under the same `subscribe` / `subscribeTopic` / live-store API.
- SSE driver: `EventSource` when `globalThis.EventSource` exists; otherwise `fetch` +
  `ReadableStream` SSE parser sending the exact `Accept: text/event-stream` header (Node,
  Bun, Deno, edge). Injectable like the existing `WebSocket` client option.
- Uplink: `POST {base}/api/realtime/sse/{clientId}` with the same frame objects the WS
  driver sends; responses are frames, so the frame-handling code is shared verbatim.
- Reconnect: EventSource reconnects natively (fetch driver: retry with the same backoff as
  the WS driver). Every (re)connect delivers a **new** clientId in the connect frame; the
  driver then replays `auth` + all subscriptions from the same subscription store the WS
  reconnect path already maintains. Live store semantics unchanged (refetch-on-reconnect
  already covers missed events — see §3).
- A `404` from the uplink (stream died between frames) triggers the reconnect path, not an
  error surface.

---

## 2. Cross-instance custom topics on Postgres

Today only record-change events cross instances (`pg_bridge`, #159/PR-6b);
`signalTopic`/`broadcastTopic` (ws.zig:582-599) are in-process `WS.publish` only.

### 2.1 Signals — payload-less NOTIFY (trivially safe)

New payload kind on the existing `zigbase_rt` channel: `{"o":"<origin>","s":"<topic>"}`.
`signalTopic` (and `broadcastFeaturesChanged`, which delegates to it) gains an `app` param
(internal signature; callers in `ctx.zig` have it) and, after the local publish, calls
`pg_bridge.emitSignal(app, topic)` — a no-op unless the active backend is Postgres, exactly
like `emit`. The listener decodes `s`-kind payloads, skips its own origin, rebuilds the
frame with the *same* `signalFrameAlloc(topic)` builder (byte-identical), and
`WS.publish`es on the topic channel — so it flows through the unchanged verbatim
custom-topic delivery path, and `canSubscribe` was already enforced per-subscriber at
subscribe time on the *receiving* instance. Nothing but a topic name rides the wire.
Immediate consequence: **`__features` flag/experiment signals become cross-instance
automatically** (a flag override on instance A now signals admin UIs on B/C).

Guard: topic length > 1024 bytes at emit → skip NOTIFY + `std.log.warn` (NOTIFY has an
~8000-byte ceiling; topics are channel names, so this is a can't-happen belt).

### 2.2 Message broadcasts — the decision: opaque token + side-table read-back (option b, made honest)

**Recommendation: carry message payloads cross-instance via a TTL side table keyed by a
random token; the NOTIFY carries only `{"o":…,"m":"<token>"}`. Not option (a), not (c).**

Rationale, honestly weighed:

- The "broadcast payloads are safe for every subscriber by contract" argument for inline
  payloads (option a) has a hole: *"every subscriber"* means every **app-level** subscriber
  admitted by `canSubscribe` — which is exactly the knob framework.md documents for gating
  **private** channels. A Postgres role with only CONNECT can `LISTEN zigbase_rt` with no
  table grants and no `canSubscribe` check. The `_rt_delete_snapshots` design comment
  (pg_bridge.zig:23-32, framework.md:895-905) *is* the project's written threat model: **no
  app data on the NOTIFY wire, ever**. Option (a) would make consumer broadcasts the single
  exception to that principle, and add an 8KB runtime failure mode on top.
- Option (b)'s stated objection — "nothing to refetch for ephemeral broadcasts" — is
  answered by the mechanism the codebase already ships: **manufacture the thing to fetch**,
  exactly as delete snapshots do. Writer stores the enveloped frame in a TTL side table;
  receivers read it back over their own authenticated connection. Cost: one INSERT + one
  indexed SELECT per broadcast per receiving instance — the identical cost profile already
  accepted for every cross-instance delete.
- Option (c) (signals-only) would leave the documented limitation half-fixed and push every
  consumer with a legitimate broadcast into modeling ephemeral fan-out as record writes.

**Mechanics.** New PG-only migration: `_rt_broadcasts (token TEXT PRIMARY KEY, topic TEXT,
frame TEXT, created TIMESTAMPTZ DEFAULT now())` mirroring `_rt_delete_snapshots`.
`broadcastTopic(app, topic, data_json)` on Postgres: build the envelope once
(`messageEnvelopeAlloc`), local `WS.publish` as today, then INSERT
(`token = crypto.genToken(io, alloc, 32)`; GC rows older than the shared 60s
`snapshot_ttl_seconds` as a piggyback, same as `storeDeleteSnapshot`), then NOTIFY
`{o, m:token}` on the *same* pooled connection (autocommit INSERT precedes the NOTIFY on
one connection, so a receiver that gets the notification always finds the row). Listener:
read `topic, frame` by token — **no row = forged or expired token = drop** (the same
forged-NOTIFY closure deletes have) — and `WS.publish(topic, frame)` verbatim:
byte-identical frames on every instance through the unchanged delivery path. Failures log
`std.log.warn` and degrade to local-only delivery (matching record-event `emit`).

**Compat and guarantees.** Rolling upgrades are safe by construction: the existing `decode`
(pg_bridge.zig:147) returns null on payloads missing `c`/`a`/`i`, so an old instance
silently ignores `s`/`m` payloads; new instances decode all three kinds. Delivery is
best-effort, at-most-once, unordered across instances — same contract as record events; a
missed signal costs one refetch (document). SQLite: byte-identical no-op, same comptime
gate (`db.dbNotify` seam + backend check). `ctx.realtime()`'s public API is unchanged.

**Docs carrying the per-instance caveat all change shape** — enumerated in §5.

---

## 3. Backfill / replay: DEFERRED (decision, with rationale)

Deferred out of this theme, recorded here so it is a decision rather than an omission:

1. **The semantics already degrade gracefully without it.** Signals are payload-less
   refetch hints by design; the SDK live store refetches on reconnect; record events
   re-fetch current state. A missed event costs one GET, not lost data — this was the
   issue's own motivation for SSE-fits-realtime.
2. **No cursor exists.** `Last-Event-ID` is out for v1 (issue lean, confirmed): frames
   carry no `id:`, so there is nothing for a replay request to be relative to.
3. **Real replay is real state.** A per-channel durable event log with retention/GC, plus
   the correctness minefield of *replay-time authorization* (viewRules, tenancy membership,
   and record contents change between emit and replay; replaying frames authorized under
   stale state is a leak class — the delete-snapshot machinery exists precisely because
   authorizing past events is hard). That is an event-sourcing feature, not a transport
   feature, and deserves its own design if ever built.
4. `KNOWN_LIMITATIONS.md:52` already lists "realtime backfill/replay" — the entry stays.
   Revisit trigger: concrete user demand for offline catch-up that live-store
   refetch-on-reconnect does not cover.

---

## 4. Test plan

### 4.1 Zig unit tests

- **Refactor parity (PR-1):** all existing realtime tests pass unchanged (the acceptance
  bar). New tests pin `frameForDelivery`: delete-snapshot strip → id-only frame, custom
  topic verbatim, `__features` verbatim, filter + viewRule + tenancy deny paths (these are
  moves of existing ws.zig behavior into a pure, directly-testable function).
- **sse_fio ABI smoke test**: extern-struct layout/field assertions against the vendored
  headers' documented shape (the spike verified field-for-field; the test pins it).
- **Registry/concurrency (PR-2):** insert/lookup/remove; pin-then-close returns 404 and
  frees exactly once (refcount asserted); threaded stress: N threads pinning + verbing
  while a closer thread runs `on_close` — no use-after-free under
  `zig build test` (and the allocator's double-free detection); `closed`-flag 404 is
  byte-identical to unknown-id 404; slot shared with WS (`connectionCount` covers both).
- **Verb parity:** authVerb/subscribeCheck driven directly for both conn kinds — the same
  decision table as the existing `subscribeDecision` tests.
- **pg_bridge codec:** encode/decode for `s` and `m` kinds; old-decoder tolerance (a
  record-event decoder returns null on `s`/`m` payloads); `_rt_broadcasts` round-trip +
  TTL GC + forged-token drop (extends `realtime_pg_test.zig`, which already proves
  NOTIFY-on-conn-A → listener-on-conn-B for record events; add signal + message kinds).

### 4.2 Dual-transport e2e delivery matrix (`tests/admin/`, browser CI job)

Parameterize the delivery assertions in `tests/admin/test_realtime.py` over a
`transport` fixture (`ws`, `sse`). The `ws` arm is the existing in-page `WebSocket`; the
`sse` arm is an in-page `new EventSource('/api/realtime/sse')` + `fetch` POSTs to the
uplink. Matrix rows (each asserted on both transports):

- connect frame delivers a clientId; anonymous subscribe to `@public` collection → ack +
  create/update events delivered.
- locked/expression collection: anonymous subscribe rejected
  ("authentication required to subscribe"); after `auth` verb → delivered.
- owner-scoped viewRule: owner receives, non-owner subscriber does not (two streams).
- delete: owner-scoped delete notifies only the owner; delivered frame is id-only (no
  snapshot leak).
- `__features` signal on flag override (existing test, gains the sse arm).
- custom topic: signal + payload broadcast via a golfsim-style route… not available on the
  stock binary — covered instead by `__features` (signal) e2e + Zig-level publish tests
  (message), and by the `examples/golfsim` build (which exercises `ctx.realtime()`).
- unsubscribe verb stops delivery; ack asserted.
- SSE-only rows: `404` non-oracle (random id vs. closed id — same body); heartbeat: launch
  the server with `ZIGBASE_SSE_HEARTBEAT_SECONDS=2` (conftest server fixture already builds
  env), read the raw stream via in-page `fetch`, assert a `: ping` comment arrives on an
  idle stream within 8s; killed stream reaps: close the EventSource, poll the uplink until
  `404`.
- Per repo convention (MEMORY: run browser suite after integration), the full
  `tests/admin` suite runs locally before each PR merges.

### 4.3 Multi-instance LISTEN/NOTIFY e2e (postgres CI job)

The `postgres` CI job (ci.yml:117) currently runs only Zig tests against the
`pgvector/pgvector:pg16` service container. Add a step after the unit tests:
`mise exec python@3.13 -- python -m pytest tests/multi_instance -q`. The new
`tests/multi_instance/test_pg_fanout.py` harness (plain `httpx`, **no browser** — SSE is
consumable as a fetch stream, which is itself a nice dogfood of the new transport):

1. Build once with `-Dpostgres=true`; launch **two** `zigbase serve` processes on two free
   ports, both pointed at the job's service container via `ZIGBASE_DB_URL`
   (= `ZIGBASE_PG_TEST_URL`), each with its own `ZIGBASE_DATA_DIR`, **sharing one
   `ZIGBASE_JWT_SECRET` env** (the auto-generated per-data-dir secret would otherwise
   diverge and instance-B tokens would fail on A), `--insecure-cookies`.
2. Record events: superuser on instance **A** creates a collection + record; an SSE stream
   subscribed on instance **B** receives the create/update/delete frames (delete id-only) —
   proving the existing record bridge end-to-end through the new transport.
3. Custom-topic signal: flip a feature flag on **A** (`PUT /api/settings/flag:x`);
   the `__features` subscriber on **B** receives `{"type":"signal","topic":"__features"}` —
   this exercises the *new* `emitSignal` path end-to-end with a stock binary (no consumer
   app needed). Message-payload fan-out is covered at the Zig level (§4.1) since the stock
   binary exposes no broadcast-calling route.
4. Negative: origin-skip — the writing instance's own subscriber receives exactly one frame
   (no NOTIFY double-delivery).

### 4.4 Prod-gate + examples

Both unit-test CI variants (`-Ddev-clock=false`) and all three example builds stay green;
`examples/golfsim` (realtime consumer) rebuilds against the changed internal
`signalTopic`/`broadcastTopic` signatures via its `ctx.realtime()` surface, which is
unchanged.

---

## 5. Docs checklist (every surface, with its site mirror)

- **`docs/api.md`** (+ `site/src/content/docs/api.md`): "Realtime (WebSocket)" section
  becomes "Realtime (WebSocket + SSE)": SSE endpoint, exact-`Accept` requirement for
  non-EventSource clients, uplink verbs + response table (incl. 404 non-oracle), heartbeat
  comment literal (`: ping`) + `--sse-heartbeat-seconds`, shared connection cap, browser
  ~6-streams/origin note, explicit "no token ever in a URL".
- **`docs/realtime-broadcast.md`** (+ site mirror): client examples gain the EventSource
  variant; the tail per-instance caveat paragraph is **replaced**: on Postgres, custom-topic
  `signal` *and* `broadcast` fan out across instances (best-effort, unordered,
  no-payload-on-the-NOTIFY-wire); SQLite unchanged.
- **`docs/framework.md`** ~880-911 (+ site mirror ~850-881): "Multi-instance realtime"
  section — remove the `ctx.realtime()` per-instance caveat (framework.md:910), document
  `_rt_broadcasts` alongside `_rt_delete_snapshots` and the token/side-table rationale;
  note `__features` is now cross-instance.
- **`docs/postgres.md`** (+ site mirror): "Realtime across instances" gains the custom-topic
  paragraph and the `_rt_broadcasts` table mention.
- **`docs/typescript-sdk.md`** (+ site mirror): `withRealtime` transport option, runtimes
  table row for the SSE driver, reconnect/clientId note.
- **Realtime feature cells** ("WS-only" → "WebSocket + SSE"): `README.md:6,47`,
  `docs/…/overview.md:12,28,63,97` + site mirror, landing copy
  `site/src/components/landing/Hero.astro:31` (this is the published comparison surface —
  no dedicated comparison page exists at 1bd02c4).
- **`KNOWN_LIMITATIONS.md`**: backfill/replay entry **stays** (§3); remove nothing else.
- **Changelog fragments** (`changelog.d/`, one per PR — never edit CHANGELOG.md):
  `### Features` for the SSE transport; `### Features` for cross-instance custom topics;
  `### Internal` for the behavior-preserving refactor PR and CI harness.
- `cd site && npm run build` on every docs-touching PR; PR-template sync checklist.

## 6. Delivery shape (firming the spike's 5 tasks)

1. **PR-1 — transport-neutral refactor** (hub verbs + `frameForDelivery` + limits hoist).
   Behavior-preserving; browser suite run locally.
2. **PR-2 — SSE transport**: `sse_fio.zig` wrapper, `sse.zig` adapter + registry +
   concurrency, upgrade dispatch fix, uplink route, heartbeat knob, unit tests.
3. **PR-3 — e2e matrix + docs**: dual-transport `tests/admin` matrix, api.md/README/
   overview/Hero cells + mirrors, fragment.
4. **PR-4 — cross-instance custom topics**: pg_bridge kinds + `_rt_broadcasts` migration +
   emit hooks, `realtime_pg_test` extension, `tests/multi_instance` + postgres-job step,
   framework/postgres/realtime-broadcast docs + mirrors, fragment.
5. **SDK PR** (`zigbase-ts-sdk`): SSE driver + transport option + tests; sync
   `docs/typescript-sdk.md` + mirror back in this repo.

Pre-1.0 breaking-change budget: none needed — every public surface here is additive; the
only signature changes (`signalTopic`/`broadcastTopic`/`broadcastFeaturesChanged` gaining
`app`) are internal.
