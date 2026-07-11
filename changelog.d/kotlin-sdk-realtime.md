### Features

- Kotlin SDK realtime tier (`zb.realtime`, bundled — no extra dependency): ack-gated `subscribe`/`subscribeTopic` with an unsubscribe-function return, `stream()`/`streamTopic()` cold `Flow`s, custom broadcast topics (`signal`/`message`), automatic re-auth from `authStore` on login/logout/refresh, and exponential-backoff reconnection with full resubscribe.
