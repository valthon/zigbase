### Features

- **Dev-only test-mode capture for outbound mail + HTTP (`zigbase.testcapture`)** — for
  deterministic e2e/integration tests, the framework can now capture what it *sent* and
  inject canned responses: an in-memory mail **outbox** (`testcapture.mail`) records every
  `Mailer.send` (from/to/subject/body, optionally suppressing real delivery), and an HTTP
  **capture/mock** seam (`testcapture.http`) records every outbound `ctx.http()` call and
  returns canned responses matched by URL substring — with no network — mirroring the OAuth
  `Transport` injection. Tests read/assert the captures via a small API (`mail.count/get/
  find`, `http.mock/requestAt/requests`). Like the test clock, it shares the **same comptime
  gate** (`dev_clock` build option; on in `Debug`, off in any release build): on a production
  build `testcapture.enabled` is `comptime false`, both seams fold away, and the binary is
  byte-for-byte unaffected with no runtime branch or perf cost (#96).
