# ZigBase SP7 — Realtime (WebSocket) Design

**Status:** Approved design (brainstorm complete). Sub-project 7 of the ZigBase roadmap
(`docs/superpowers/specs/2026-06-08-zigbase-architecture-design.md`).

**Goal:** Clients open a WebSocket, authenticate with a JWT message, subscribe to collection/record
topics (with an optional filter), and receive **rule-filtered** create/update/delete events as
records change — reusing the SP4 access-rules engine so a subscriber only ever sees what it could
`GET`.

**Depends on:** SP3 (records + the filter compiler), SP4 (access rules — `rules.matches`/the guarded
`SELECT 1 … WHERE id=? AND (rule)`), SP5 (auth — JWT verification, `RequestContext`), the
collections engine, and zap's WebSocket + facil.io pub/sub support.

**Transport decision:** **WebSocket**, not SSE. zap exposes first-class WebSocket support
(`websockets.Handler`, connection `upgrade`, thread-safe `write`, and facil.io's native pub/sub
`fio_publish`/`websocket_subscribe`). facil.io's HTTP handler is one-shot, so SSE would require
hand-rolled chunked streaming / a zap fork — the open risk the architecture doc flagged. WebSocket
retires that risk and is supported today with no patching. (This supersedes the roadmap's tentative
"Realtime (SSE)".)

---

## 1. Decisions (from brainstorming)

1. **Transport: WebSocket** (native zap/facil.io). Cross-thread event push rides facil.io pub/sub:
   the record-writer thread `publish`es to a channel; facil.io delivers on each subscribed
   connection's own thread, where writing to the socket is safe.
2. **Subscription model: collection + per-record topics + filter expressions.** Subscribe to a whole
   collection (`posts`), a single record (`posts/<id>`), each with an optional filter expression
   (e.g. `status="published"`) evaluated server-side via the SP3 filter compiler.
3. **Connection auth: an `auth` message over the WS** carrying the ZigBase JWT (never the `zb_auth`
   cookie). The connection opens anonymous; the client sends `auth` to set its identity and may
   re-send to refresh before expiry. This structurally defeats cross-site WS hijacking (no ambient
   credentials) and keeps tokens out of URLs/logs.
4. **Fan-out: facil.io pub/sub + per-connection filtering.** facil.io owns the registry, cross-thread
   marshaling, and thread-correct delivery; each connection keeps its own subscription state (topic →
   filter) and auth; the per-connection delivery callback runs the viewRule guard + filter and writes
   only on a pass.
5. **Delete events carry id-only** (no record body), gated by the coarse auth tier — see §4.
6. **Delivery is ephemeral**: at-most-once while connected; no backfill/replay (YAGNI for MVP).

---

## 2. Architecture & modules

New `src/realtime/` package; handlers stay pure where possible; `server.zig` remains the only
zap-importing module (it hosts the `websockets.Handler` instantiation).

| Module | Responsibility | Depends on |
|---|---|---|
| `src/realtime/protocol.zig` | **Pure** parse of client messages + serialize of server events | std.json |
| `src/realtime/connection.zig` | Per-connection `Conn` context (auth, subscriptions, clientId) + lifetime-stable storage for WS settings / subscribe args | schema, query |
| `src/realtime/hub.zig` | `broadcast(io, alloc, col, action, record)` (publish to channels) + the per-connection delivery callback (`shouldDeliver` + write) | rules, records, collections, query |
| `src/api/realtime.zig` | `GET /api/realtime` → upgrade to WebSocket; on_open/on_message/on_close dispatch | realtime/*, auth |

**Auth reuse:** SP5's `auth.authenticate` needs the HTTP `RequestCtx` (it reads bearer/cookie
headers). SP7 refactors the token→identity core into a shared
`auth.verifyToken(io, alloc, app, conn, token) !?Authed` (peek claims → load record + tokenKey →
deriveKey → `jwt.verify` against SQLite `unixepoch`), which both `authenticate` (HTTP) and the WS
`auth` message use. No behavior change to the HTTP path.

### zap WebSocket API (verified, v0.10.6)

- `const WS = zap.WebSockets.Handler(Conn);`
- `WS.upgrade(h: *http_s, settings: *WS.WebSocketSettings) !void` — `WebSocketSettings{ on_open:
  fn(?*Conn), on_message: fn(?*Conn, WsHandle, []const u8 message, bool is_text), on_close:
  fn(?*Conn, isize uuid), context: ?*Conn }`. **The settings struct must outlive the connection**
  (facil.io holds `udata = settings`) — store it on the `Conn`.
- `WS.write(handle: WsHandle, message: []const u8, is_text: bool) !void` — safe on the connection's
  own thread (i.e. inside the callbacks).
- `WS.publish(.{ channel, message, is_json })` → `fio_publish` — **callable from any thread**
  (the record-writer thread uses this).
- `WS.subscribe(handle, args: *WS.SubscribeArgs) !usize` — `SubscribeArgs{ channel, on_message:
  fn(?*Conn, WsHandle, []const u8 channel, []const u8 message), context: ?*Conn }`. **Each
  SubscribeArgs must outlive the subscription** (facil.io holds the pointer) — store per-subscription
  on the `Conn`. Returns a subscription id; `0`/error on failure.

---

## 3. Connection lifecycle & wire protocol

**Lifecycle:**
1. `GET /api/realtime` → **Origin check** (reject disallowed origins; defense-in-depth) → allocate a
   `Conn` (and its `WebSocketSettings`) from `app.allocator` → `WS.upgrade`.
2. `on_open` → assign a `clientId` (random base36) → `WS.write` a
   `{"type":"connect","clientId":"…"}` frame.
3. `on_message` → parse JSON → dispatch (`auth` / `subscribe` / `unsubscribe`). Unknown/oversized/
   malformed → an `{"type":"error",…}` reply (never drop the connection).
4. `on_close` → free the `Conn`, its settings, and its subscribe-args (facil.io has stopped
   delivering by then).

**Client → server (JSON text frames):**

| Message | Effect | Reply |
|---|---|---|
| `{"action":"auth","token":"<jwt>"}` | `verifyToken`; set `conn.auth` (or clear on failure) | `{"type":"auth","status":"ok"\|"error"}` |
| `{"action":"subscribe","topic":"posts","filter":"status='published'"}` | Validate collection exists; parse filter (SP3); `WS.subscribe(channel="posts")`; store `{topic→filter}` on conn | `{"type":"ack","action":"subscribe","topic":"posts"}` or `error` |
| `{"action":"unsubscribe","topic":"posts"}` | Unsubscribe the channel; drop the stored entry | `{"type":"ack","action":"unsubscribe","topic":"posts"}` |

- `topic` is `<collection>` or `<collection>/<recordId>`. `filter` is optional. Subscribing to an
  unknown collection → `error`. A malformed filter → `error` (the connection stays up).
- Subscriptions are allowed before `auth` (they just see anonymous-visible events until auth lands).

**Server → client (JSON text frames):**
- `{"type":"event","topic":"posts","action":"create"|"update","record":{…}}` — full record, hidden
  fields stripped (identical projection to a REST `GET`).
- `{"type":"event","topic":"posts","action":"delete","record":{"id":"REC1"}}` — **id-only**.
- `{"type":"connect"|"ack"|"auth"|"error", …}` control frames.

**Topics & channels:** channel names mirror topics. A record event publishes to **both** its
collection channel (`posts`) and its record channel (`posts/<id>`). A client subscribed to both
receives two frames and dedups by `id`+`action` (accepted minor cost).

---

## 4. Event broadcast & rule-filtered delivery

**Broadcast hook:** after a successful, committed mutation, the `api/records.zig` create / update /
delete handlers call `realtime.broadcast(io, alloc, col, action, record)`. It builds the event JSON
(full record for create/update; id-only for delete) and `WS.publish`es it to the collection channel
and the record channel. This is the only new coupling into the record path — one call at the end of
each handler, after the response record is in hand.

**Per-subscriber delivery (facil.io delivers on the connection's thread):** the subscription callback
`(conn, channel, message)`:
1. Parse the event → `{action, record_id, record_json}` and the collection from the channel.
2. Build a `request.RequestContext` from `conn.auth` (so `@request.auth.*` resolves).
3. **`shouldDeliver`** — the security-critical, unit-tested decision:
   - **create/update:** authorize + filter in a **single guarded query** — `SELECT 1 … WHERE
     id=record_id AND (viewRule) AND (subscription_filter)`, both expressions compiled by the SP4/SP3
     compiler with the subscriber's auth bound (`viewRule==null` short-circuits to superuser-only
     before any query; `viewRule==""` contributes no clause; an absent subscription filter
     contributes no clause). One per-event reader query; deliver iff it returns a row. (The accepted
     cost; caching deferred.)
   - **delete:** the row is gone, so the SQL guard can't re-authorize it and we have no in-memory
     rule evaluator (rules compile to SQL). Deliver the **id-only** event gated by the coarse tier:
     `viewRule==null` → superuser subscribers only; otherwise → the topic's subscribers. No record
     body is ever sent on delete, so no field-level content can leak regardless of `viewRule`.
     *Limitation (documented):* fine-grained per-record delete authorization is deferred (needs
     in-memory rule eval).
4. On pass, `WS.write` the event frame; otherwise silently skip.

A reader connection for the guard comes from the pool (per-call reader; WAL allows concurrent reads).

---

## 5. Security model

- **Auth is the explicit JWT message only** — the `zb_auth` cookie is never consulted for WS, which
  structurally defeats cross-site WebSocket hijacking (an attacker page can open an anonymous socket
  but cannot supply the victim's token). The JWT travels in a data frame, not the URL — no token in
  access/proxy logs.
- **Origin check at upgrade** (configurable allowlist; default permissive in dev, like
  `cookie_secure`) as defense-in-depth.
- **Authorization reuses the REST path exactly** (`viewRule` guard + filter compiler), so realtime
  visibility can't diverge from `GET` visibility. Hidden fields (`passwordHash`/`tokenKey`) are
  stripped by the same `records.get` projection.
- **Expired token** → the connection stores the verified token's `exp`; at each event's delivery the
  guard compares `exp` against current time (SQLite `unixepoch`), and a past-due connection is
  treated as **anonymous** for that event (only public topics) until a fresh `auth` message restores
  it. An expired identity never keeps receiving private events, with no periodic-sweep machinery.
- **Delete events leak no content** (id-only).
- **Robustness:** malformed frames / bad filters / unknown collections produce an `error` reply, not
  a disconnect. Event/frame size is bounded (oversized inbound frames rejected). No SQL reaches the
  DB unparameterized (channel/topic strings are validated collection identifiers + record ids bound).

---

## 6. Error handling

| Condition | Result |
|---|---|
| Bad JSON / unknown action / oversized frame | `{"type":"error","message":"…"}` reply; connection stays up |
| `auth` with an invalid/expired token | `{"type":"auth","status":"error"}`; conn becomes/stays anonymous |
| `subscribe` to an unknown collection | `{"type":"error",…}` |
| `subscribe` with a malformed filter | `{"type":"error",…}` (filter compiler error mapped) |
| Disallowed `Origin` at upgrade | upgrade refused (HTTP 403; no WS) |
| Delivery-time guard/DB error for one subscriber | that event skipped for that subscriber; logged; other subscribers unaffected |

---

## 7. Testing strategy

- **`protocol.zig` (pure):** exhaustive parse tests (auth/subscribe/unsubscribe, missing fields, bad
  JSON, unknown action) + serialize tests (create/update full record, delete id-only, connect/ack/
  error frames).
- **`shouldDeliver` (against a real in-memory DB):** the security matrix — `viewRule` ∈
  {null, "", macro} × auth ∈ {anonymous, owner, non-owner, superuser} × filter ∈ {none, match,
  no-match} × action ∈ {create, update, delete}. Asserts deliver/skip with **no leakage** — the same
  rigor that proved the OAuth decision tree, without a live socket.
- **`broadcast` event building (pure):** correct topics + payloads (full vs id-only) per action.
- **Live smoke (WS transport + fan-out):** a real WS client connects, `auth`s, `subscribe`s; a record
  is created/updated/deleted via REST; the client asserts the correct events arrive, an unauthorized
  subscriber receives nothing, and an anonymous subscriber sees only public-collection events. (Uses
  a small scripted WS client — e.g. Python `websockets` or `websocat` if available; otherwise a
  minimal Zig WS client.)
- **Holistic security review** before merge: CSWSH (no cookie/ambient auth), leakage (viewRule reuse,
  delete id-only, hidden-field stripping), SQLi via topic/filter strings, thread-safety (writes only
  on the connection thread; cross-thread only via `publish`), lifetime correctness
  (settings/subscribe-args outlive the connection; no use-after-free on close), and DoS (per-event
  guard cost, frame-size bounds).

---

## 8. Build slicing — two plans

**7a — protocol & delivery logic (no WebSocket):**
- `realtime/protocol.zig` (parse client messages + serialize server events), fully unit-tested.
- The `Conn`/subscription data model (`realtime/connection.zig`), minus the live WS glue.
- `shouldDeliver` (`realtime/hub.zig` core): viewRule guard + filter evaluation against a DB, with
  the full security matrix tested.
- `broadcast`'s event-building (pure), tested.
- No facil.io WS yet — fast, pure, and where the security logic lives.

**7b — WS transport & wiring:**
- `auth.verifyToken` refactor (token→Authed, shared with HTTP `authenticate`).
- `api/realtime.zig` upgrade handler + the zap `WS` callbacks (on_open/on_message/on_close) wired to
  the protocol dispatch + `WS.subscribe`/`unsubscribe`, with lifetime-stable settings/args storage.
- `realtime.broadcast`'s `WS.publish` calls + the subscription delivery callback (`shouldDeliver` +
  `WS.write`).
- The `broadcast` hook in `api/records.zig` (create/update/delete).
- Origin check + route registration in `server.zig`.
- Live smoke, holistic security review, then merge SP7 (7a+7b) as a unit to `main`.

---

## 9. Out of scope (deferred)

- SSE transport / backend-driven streaming.
- Backfill / replay / "catch-up since last event" (events are ephemeral).
- In-memory rule evaluation (would enable fine-grained per-record delete authorization and avoid the
  per-event DB guard).
- Subscription-filter caching / compiled-filter reuse across events (perf).
- Presence, typing indicators, server-initiated push beyond record events.
- Per-connection rate limiting / backpressure tuning (rely on facil.io defaults for MVP).
- Admin SPA realtime UI (SP9).
