### Internal

- Restore real leak detection for the web-push subsystem: convert all 13 arena-masked tests in
  `src/push/{config,encrypt,send,sender,vapid}.zig` to run under `std.testing.allocator`, and
  remove those files from `scripts/allocator-allowlist.txt`. The conversion surfaced several
  latent ownership bugs — masked in production because the push send/queue paths run on a
  request/job arena, but incorrect under any non-arena allocator — now fixed to the ownership
  contracts: `vapid.buildJwt`/`vapidAuthHeader` and `sender.deliver`/`buildPayload` freed none of
  their intermediate scratch (contract-1: added `defer` frees, one escaping return each);
  `config.generateKeypair` could leak the first base64 key if the second allocation failed
  (added `errdefer`); and `push.jobHandler` parsed its payload with a leaky parser onto the job
  arena (contract-2: `parseFromSlice` + `defer parsed.deinit()` on `app.allocator`, since the
  fields are read synchronously and never retained).
