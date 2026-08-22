### Fixes

- Stop the HTTP reactor from closing file descriptors it does not own. facil.io's poll
  review loop force-closed on any error event without checking whether it still owned the
  descriptor, so a stale event could close a descriptor the OS had already reissued to
  something else in the same process — most visibly an outbound SMTP socket, but any
  descriptor was reachable, including SQLite's. It showed up as an intermittent `BADF`
  panic in a queue worker mid-`connect`, and as unexplained dropped connections. Fixed in
  the pinned `zap`/facil.io build; no application change is required.
