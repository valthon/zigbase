### Internal

- e2e test harnesses (`clients/typescript`, `examples/{blog,golfsim,plugins}`) now retry server startup on a port-bind race: each attempt picks a fresh OS-assigned free port, watches for the child exiting early (the zap `ListenError` bind failure) to retry immediately rather than waiting out the health deadline, and cleans up the failed process + temp data-dir between attempts (up to 5). Fixes the intermittent `ListenError` → "server did not become healthy" flake in the `ts-sdk`/`browser` CI jobs.
