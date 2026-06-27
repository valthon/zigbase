### Features

- Auth lifecycle hook `beforeAuthSuccess` (#80): a writable, transactional, abortable hook
  that runs after credentials/token verification and **before** the session is issued, with
  a `*Ctx` bound to the login's in-transaction writer. Its `ctx.records()` writes commit
  atomically with the login; returning an error rolls them back (and, for magic-link,
  un-consumes the link token) and blocks the session (fail closed). Fires on the unified
  `POST /api/collections/:col/auth/:method/complete` endpoint (password / otp / webauthn /
  oauth2 / custom) and the magic-link `consume` link. The existing notify-only `onAuth` is
  unchanged and still fires once, after issuance. Motivating use case: claim anonymous
  records on a user's first login.
- Session management surface `ctx.auth()` with `clearSession` (#86): `ctx.auth().clearSession()`
  and `zigbase.auth.clearSession(ctx)` return the cleared `zb_auth`/`zb_csrf` cookies built
  from the framework's own cookie policy, so a logout handler is one line and can never drift
  from the built-in logout.
