### Security

- Fixed an unauthenticated, remotely-triggerable heap double-free (and double connection-slot release) on the realtime WebSocket upgrade path: a malformed `Sec-WebSocket-Version` handshake drives facil.io's `bad_request` branch, which already invokes the connection's `on_close` teardown before returning failure — the adapter then tore the connection down a second time. In a release build this was a potential denial of service. The SSE upgrade path (new in 0.10.0) is hardened identically. Both transports now leave failure-path teardown solely to facil.io's `on_close`.
