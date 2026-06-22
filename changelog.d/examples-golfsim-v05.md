### Features

- `golfsim` example: `require_verified = true` on the `users` auth collection — guests must verify their email before a session is minted (booking/payments justification).
- `golfsim` example: OTP passwordless login (`auto_create = false`) for existing verified accounts; first-time onboarding remains password signup + email verification.
- `golfsim` example: comptime indexes — `NOCASE` unique on `users.email` (prevents case-variant duplicate accounts) and a partial composite index on `bookings(listing, starts_at) WHERE status != 'cancelled'` (backs the double-booking overlap check and availability route).
- `golfsim` example: OAuth2 "Sign in with Google" via comptime `.auth.oauth2`; client credentials sourced from `ZIGBASE_OAUTH_GOOGLE_CLIENT_ID` / `ZIGBASE_OAUTH_GOOGLE_CLIENT_SECRET` at provision time; Google-verified accounts are created `verified=true`.
- `golfsim` frontend: multi-step `Auth` component covering password sign-in, OTP initiate/complete, signup, email-verification, and Google OAuth2 flows.
