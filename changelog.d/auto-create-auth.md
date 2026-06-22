### Features

- `magic_link` and `otp` auth methods now honour `auto_create: true` — when an unknown identity calls `initiate`, a passwordless account is provisioned automatically (email set from the identity, `verified = false`) and the link or code is sent as usual. Enables "sign up or sign in" in one step. Accounts are created with `verified = false`; pair with `require_verified` only when a verification flow is in place.
