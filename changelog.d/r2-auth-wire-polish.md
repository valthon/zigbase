### Breaking

- Side-effect auth successes are now uniform **204 No Content**: `confirm-verification` (was `{"verified":true}`), `confirm-password-reset` (was `{"success":true}`), `webauthn/register/finish` (was `{"registered":true}`). Treat any 2xx as success; `@zigbase/client` types updated to `Promise<void>`.
- The magic-link consume URL is now dash-case: `GET …/auth/magic-link/consume` (was `auth/magic_link/consume`). Hard cutover — links emailed by pre-upgrade servers 404 (tokens are short-lived). The method slug (`/auth/magic_link/initiate|complete`, `onAuth` tag) is unchanged.
