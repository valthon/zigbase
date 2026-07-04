### Internal

- Fix a ~2.4%-per-run flake in the Postgres realtime cross-instance tests
  (`realtime_pg_test.zig`): the delete-snapshot leak-canary asserted a bare
  owner value `u9` was absent from the NOTIFY payload, but the payload embeds a
  32-char random base36 token that coincidentally contains `u9` ~2.4% of runs.
  The canaries are now anchored to their JSON string quotes (`"u9"`, `"ssn"`),
  which a quote-less token/id can never forge, while still catching a real leak.
  The cross-instance waits also now loop over benign non-notification async
  messages (matching the production `pg_bridge` listener's tolerant contract)
  instead of failing on the first one.
