### Features
- `serve wait --timeout-ms N --json` waits for a healthy tracked session with a bounded deadline, including unresponsive health probes.

### Internal
- Admin browser fixtures require HTTP health readiness and retain startup logs instead of trusting an open TCP port.

### Fixes
- `serve wait --json` reports `ready: true` on success and distinguishes internal worker failures from deadline expiry, with explicit diagnostics and synchronized control-verb documentation.
