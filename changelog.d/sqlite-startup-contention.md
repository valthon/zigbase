### Fixes

- Apply SQLite's startup busy timeout before enabling WAL, allowing startup to
  wait for short-lived readers of an existing rollback-journal database.
