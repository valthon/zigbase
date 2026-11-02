### Features
- Exported local-file response helpers, Range/conditional planning, and MIME lookup for custom routes.
- Added `static_headers` for CSP and per-path cache headers across embedded and directory static serving.

### Fixes
- Serve `.webmanifest` as `application/manifest+json` and `.ics` as `text/calendar`.
- Capture streamed file response bodies in the in-process test harness.
- Local-file response options are copied into the request arena; static-header validation supports generated multi-kilobyte CSPs, and file captures follow the live whole-file offset semantics.
