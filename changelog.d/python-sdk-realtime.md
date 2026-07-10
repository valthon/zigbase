### Features

- Python SDK realtime tier (`zigbase[realtime]`): `AsyncZigBase.realtime` with ack-gated `subscribe`/`unsubscribe`, `stream()` async iteration, custom broadcast topics (`signal`/`message`), automatic re-auth on auth-store changes, and exponential-backoff reconnection with full resubscribe.
