### Features

- `zigbase doctor` runs nine preflight checks over a deployment — JWT-secret
  persistence, every `@public` access rule enumerated by name, cookie security, bind
  address, reverse-proxy coherence, mailer configuration, pending migrations, data-dir
  writability, and auth records still carrying a legacy password hash — and exits `1`
  when any of them is an error, `2` when it found warnings only, and `0` when the
  deployment is fully clean. `--production` judges the
  same facts as a production deployment, escalating the risky warnings (an anonymously
  writable collection, insecure cookies, an unconfigured mailer, a spoofable
  `--trust-proxy`) into errors. `--json` emits NDJSON findings plus one summary object, and
  the check ids are frozen, so a script can match on them forever. It never opens or
  creates anything under a data dir it already found unwritable — the two DB-backed
  checks report `skipped` instead — so a read-only diagnostic never mutates a deployment
  it can't safely reach.

  The legacy-password-hash check stays a *warning* even under `--production`: a legacy
  hash is a normal transitional state that re-hashes itself on the owner's next
  successful login, so what a migrating operator wants is to watch the count fall to
  zero, not to be blocked from deploying.
