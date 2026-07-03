### Features

- Realtime over Server-Sent Events (#188): `GET /api/realtime/sse` (EventSource-compatible — no SDK required) + `POST /api/realtime/sse/:clientId` uplink speaking the same verb grammar as WebSocket. Same frames, same per-record delivery authorization, same Origin policy, same shared connection cap. New `--sse-heartbeat-seconds` / `ZIGBASE_SSE_HEARTBEAT_SECONDS` knob for the `: ping` heartbeat interval.

### Internal

- Dual-transport (ws/sse) realtime e2e delivery matrix in the browser suite.
