### Breaking

- `beforeAuthSuccess` now fires on the legacy `POST …/auth-with-password` and `POST …/auth-refresh` routes — **including `_superusers`** (the admin SPA login). A hook that errors unconditionally will lock superusers out of the admin UI (fail closed, by design); fix the hook and rebuild.
- `events.AuthMethod` gained a `.refresh` variant; exhaustive `switch`es over the enum must add an arm (compile error).

### Fixes

- `onAuth` on `POST …/auth-refresh` now reports `.refresh` instead of the mislabeled `.password`.
