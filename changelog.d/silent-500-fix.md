### Fixes

- **A failing built-in endpoint no longer returns an unexplained 500 in silence.** Errors escaping the built-in route table, the feature-state route, and custom-route dispatch are now logged and delivered to your `onError` hook (and to Sentry, when configured) exactly as consumer-route errors already were. A static-file read failure is logged as a warning and still returns 404.
- Custom-route dispatch failures (connection-pool acquisition, authentication) used to be swallowed and fall through to static-file handling, answering with the wrong status; they now return 500.
