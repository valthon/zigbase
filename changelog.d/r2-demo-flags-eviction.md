### Changed

- The release binary no longer ships the demo feature flags/experiment (`dark_mode`, `maintenance`, `onboarding_flow`) — they were Playwright fixtures riding in production. `GET /api/features` on a stock binary is now empty until you declare your own.

### Internal

- Browser feature tests drive a dedicated `features-fixture` binary (`fixtures/features/`).
