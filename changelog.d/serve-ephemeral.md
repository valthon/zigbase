### Features

- `zigbase serve --ephemeral` starts a throwaway server on a fresh temp data dir and a
  free port, printing one JSON object — `{"url","port","data_dir","pid"}` — on stdout
  once it is actually answering. This is the zero-Zig test-backend story: an SDK test
  suite or a frontend dev script can spawn a real ZigBase, read one line, and use it.
  It composes with `--background`, and the temp dir is deleted on graceful shutdown and
  by `zigbase serve stop`.
