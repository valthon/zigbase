### Features

- `ctx.webhook(url, payload, .{…})` delivers outbound webhooks in the background on the built-in `"webhook"` job kind (riding the multi-queue engine). Transport errors, `5xx`, and `429` (honoring an integer `Retry-After`) are retried with backoff up to `retries` attempts; any other `4xx` is terminal. A terminal rejection or exhausted attempts fires `onError` with the new `.webhook` error phase. Options: `queue`, `retries`, `backoff`, `timeout_s`, `sign`, `idempotency`.

### Security

- Webhook bodies can be HMAC-SHA256 signed (`WebhookOpts.sign`): the receiver verifies authenticity by recomputing `hex(HMAC-SHA256(secret, "<timestamp>.<body>"))` against the `X-Signature` header (timestamp in `X-Webhook-Timestamp`), and the signed timestamp limits replay.
- Each webhook delivery carries a stable `Idempotency-Key` header generated once at enqueue and reused across every retry/replay, so receivers can dedupe at-least-once deliveries. TLS certificate verification stays on for all webhook requests.
