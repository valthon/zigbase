### Security

- Realtime: a duplicate `subscribe` to a topic a socket already holds now REPLACES its subscription in place instead of stacking a second facil.io subscription. The old behavior let an (even anonymous) client loop subscribes on any public collection to bypass the per-connection `MAX_SUBS` cap entirely, grow per-connection memory without bound, multiply every published event's server-side authorization/delivery work N×, and orphan all-but-the-last facil.io subscription until socket close — a connection-scoped denial-of-service. Applies to both the WebSocket and SSE transports.
- Realtime: `auth` frames are now verified on a throwaway scratch arena, with only a successful identity persisted to the connection-durable arena. Previously every `auth` frame — including a garbage token, which allocated during pre-validation claim parsing — leaked permanently into the durable arena (freed only at connection close), so a single connection looping `auth` frames could exhaust server memory with no credentials required.

### Performance

- Realtime: per-subscriber event delivery now parses only the three envelope fields it needs (`action`, `record.id`, and the delete-authorization snapshot) with a typed, unknown-field-skipping parse, instead of materializing the entire record body into a throwaway JSON tree for every subscriber. A create/update of a large record fanned out to many subscribers no longer does O(subscribers × record-size) redundant allocation.

### Fixes

- Realtime: a facil.io `subscribe` failure is no longer acked to the client as success — it now rolls back the logical subscription, logs, and returns an error frame, so the client is not stranded in a silent dead subscription (WebSocket and SSE).
- Realtime: a dropped broadcast/signal/message frame (allocation failure on an already-committed write) is now logged with the collection/topic and action, matching the cross-instance paths, so a client-reported "missed update" is diagnosable instead of vanishing silently.
- Realtime (Postgres): cross-instance delete-snapshot and broadcast side-table failures now distinguish a genuinely-absent row (a forged/expired token — a quiet fail-closed drop) from a real database/parse error, which is now logged instead of collapsed into the same silent null.
- Realtime (Postgres): the cross-instance `LISTEN` reconnect backoff now resets only after a connection has stayed healthy for several seconds, and sleeps before reconnecting after a short-lived session. A proxy or mid-failover node that accepts the connection and `LISTEN` but drops it on the first wait no longer drives a zero-delay connect/reconnect loop.
