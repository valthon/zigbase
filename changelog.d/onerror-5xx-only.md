### Fixes
- `onError` / Sentry integration now fires only for server-side (5xx) errors; client errors (4xx) no longer trigger the error handler or Sentry reports.
