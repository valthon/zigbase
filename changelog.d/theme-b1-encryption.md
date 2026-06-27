### Features
- **Field/collection policy pipeline** — a value-transform seam at the records read/write path, applied transparently with the field schema in hand. Its first behavior ships below.
- **Transparent at-rest field encryption** — mark a `text`/`editor`/`json` field `.encrypted = true` to store it encrypted (AES-256-GCM) in SQLite while handlers, the records API, and HTTP responses see plaintext. Encrypted fields cannot be indexed, marked `.unique`, or used in a `?filter`/`?sort` (compile error / 400). Key rotation is designed into the versioned `v<N>:` envelope.

### Security
- Field encryption uses an authenticated AES-256-GCM envelope (`v1:` + base64url(nonce‖ciphertext‖tag)) with a fresh per-write nonce, sharing one audited primitive with OAuth-secret encryption via domain-separated key derivation. The key comes only from `ZIGBASE_FIELD_KEY` (HKDF-derived, never persisted or logged); the server refuses to start if an `.encrypted` field is declared without it. Reads are strict and fail-closed: a non-envelope (legacy plaintext), wrong key, or tampered value never yields plaintext.
