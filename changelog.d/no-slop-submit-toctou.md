### Fixes

- Fixed a rare crash where enqueuing a background job (for example an error report) at the moment the in-memory job pool was shutting down could dereference a just-cleared pool pointer and panic the process. `App.submit` now null-checks the pool rather than asserting it, so a submit that races shutdown fails cleanly (the job is dropped) instead of crashing.
