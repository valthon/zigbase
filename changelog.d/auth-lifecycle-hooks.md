### Features

- Auth lifecycle hooks (#98): a new `.auth` config group adds **before/after** hooks for
  `register`, `logout`, `refresh`, and `password-change`, extending the Theme D
  `beforeAuthSuccess` discipline into a uniform lifecycle. Before-hooks run with a `*Ctx`
  bound to the action's connection (in-transaction for register / refresh /
  password-change), so `ctx.records()` writes commit atomically with the action; returning
  an error aborts and fails closed (rolling back where a write transaction exists — e.g. an
  aborting `beforePasswordChange` leaves the password unchanged and the reset token
  un-consumed, an aborting `beforeRegister` creates no account). After-hooks are notify-only.
  Hooks fire on `register` (auth-collection record create), `POST …/auth-logout`,
  `POST …/auth-refresh`, and `POST …/confirm-password-reset`. A typo'd hook name or a
  wrong-typed handler is a compile error. The existing `beforeAuthSuccess` and `onAuth`
  hooks are unchanged.
