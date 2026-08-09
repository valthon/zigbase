### Breaking

- `zigbase serve` now takes an exclusive lock on its data dir and refuses to start when
  another `serve` process already owns it. Two servers sharing one data dir silently
  half-worked before (two JWT secrets, two schedulers running the same cron, two
  provisioners racing the same DDL). Pass `--ignore-lock` for the old behavior — that
  instance is untracked and invisible to `zigbase serve status/stop/logs`.
