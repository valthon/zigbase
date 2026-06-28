### Features

- Consumer-facing realtime broadcast API for custom (non-record) channels, reachable from a
  custom route handler or a background job via `ctx.realtime()`:
  - `ctx.realtime().signal(topic)` — publish a signal-only `{"type":"signal","topic":"<topic>"}`
    frame so subscribers re-fetch over an authenticated GET (the recommended default for
    private/per-subject state — it carries no payload).
  - `ctx.realtime().broadcast(topic, payload)` — publish a payload-carrying
    `{"type":"message","topic":"<topic>","data":<payload>}` frame, delivered verbatim to every
    subscriber of `topic` (`payload` is any JSON-serializable value).
  - Clients use the **same** subscribe/unsubscribe WebSocket protocol they already use for record
    topics. A custom topic is any name that is not a collection; subscribing to a collection name
    still goes through that collection's normal record-channel authorization.
  - Both publish entry points are a no-op when the realtime reactor isn't running (tests/CLI), so
    they are safe to call unconditionally.
- New optional `App(.{ .realtime = .{ .canSubscribe = fn } })` config: a
  `fn(ctx: *Ctx, topic: []const u8) bool` predicate that gates who may subscribe to a custom
  topic. An unknown `.realtime` sub-key is a compile error.

### Security

- Custom topics default to **public signal channels** (anyone, including anonymous sockets, may
  subscribe) — exactly the existing `__features` behavior. Keep private/per-subject state
  **signal-only** and re-fetch it over an authenticated GET; payload-carrying `broadcast` is an
  explicit opt-in for data that is safe for every subscriber of the topic.
- The `.realtime.canSubscribe` guard gates private custom channels — returning `false` denies the
  subscription before it is registered.
- The custom-topic subscribe path is strictly scoped to topics that are **not** collections, so it
  can never be used to subscribe to (or receive records from) a real collection's topic without
  that collection's normal per-record authorization. Custom-topic frames are delivered verbatim
  with no per-record viewRule, since subscription was already authorized at subscribe time.
