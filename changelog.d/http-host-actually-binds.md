### Security

- `serve` now binds the address it was given. `--http-host` / `ZIGBASE_HTTP_HOST` was parsed,
  printed in the `zigbase listening on …` line, recorded in `serve.json`, and graded by
  `doctor` — but never handed to the listener, so every deployment listened on all
  interfaces regardless: the documented loopback default, and an operator who explicitly
  asked for `127.0.0.1`, both got a server reachable from every interface on the host while
  the logs said otherwise. Instances kept loopback-only behind a reverse proxy were the ones
  exposed by this. The default bind is now genuinely `127.0.0.1`, and `0.0.0.0` (or `::`) is
  once again the deliberate opt-in it is documented to be. The official container image is
  unaffected — it sets `ZIGBASE_HTTP_HOST=0.0.0.0` for exactly this reason.

  One consequence worth knowing before upgrading: because the host is now honoured, a host
  this machine has no address for — a typo, an address belonging to another box, an
  interface that is not up yet — fails at boot naming the address and the knob, instead of
  silently falling back to every interface.
