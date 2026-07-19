### Fixes

- Realtime (Postgres cross-instance bridge): fixed a compile error that broke `-Dpostgres=true` builds — the `LISTEN` reconnect backoff passed an unsigned duration where a signed one was required.
- Realtime subscribe: when recording a just-created transport subscription failed under memory pressure, the live subscription was stranded (the client was told "subscribed" but a later unsubscribe could never cancel it). The subscription is now rolled back and the client receives an error it can retry, on both WebSocket and SSE.

### Performance

- Realtime delete authorization: the per-subscriber in-memory authorization sandbox for a deleted record is now reused across every subscriber of the same delete event that is served on a given worker thread, instead of being rebuilt once per subscriber. Large delete fan-outs do far less redundant work; per-subscriber authorization decisions are unchanged.

### Security

- Realtime auth: a connection that repeatedly re-authenticated with a valid token no longer grows per-connection memory without bound — the verified identity is now held in a dedicated arena that is reclaimed on each re-authentication, closing an inbound-driven single-connection memory-exhaustion vector.
