### Security

- File downloads via the `?token=` query parameter now accept **only** purpose-built `.file`
  tokens (minted by `POST /api/files/token`), not full `.auth` session tokens. A session token
  in a URL query travels into access logs, `Referer` headers, and browser history, so permitting
  it there invited long-lived credentials into those sinks. Session-authenticated downloads
  continue to work via the `Authorization: Bearer` header or the auth cookie.

### Breaking

- A file download URL built with a raw `.auth` session token in `?token=` (rather than a `.file`
  token from `POST /api/files/token`) is no longer authenticated by that token. No first-party
  client did this — the SDKs and admin UI already use `.file` tokens or the auth cookie/header —
  but a hand-built URL relying on the old behavior must switch to a `.file` token.
