# Security Policy

ZigBase is a backend server: it terminates HTTP, authenticates users, enforces per-collection
access rules, and stores your data. Security reports are taken seriously and get priority over
feature work.

## Supported versions

ZigBase is **pre-1.0** and moves fast. Only the **latest released version** receives security
fixes; there are no backported patch branches for older minors.

| Version | Supported |
|---------|-----------|
| Latest [release](https://github.com/valthon/zigbase/releases) | ✅ |
| Any earlier release | ❌ — upgrade to the latest |

If you are pinned to an older version and cannot upgrade, say so in your report and we will tell
you which commit fixes the issue so you can carry the patch yourself.

## Reporting a vulnerability

**Do not open a public issue for a security vulnerability.**

Report it privately through GitHub:

1. Go to the [**Security** tab](https://github.com/valthon/zigbase/security) of this repository.
2. Click **Report a vulnerability**.
3. Fill in the advisory form.

This opens a private advisory visible only to you and the maintainers. It also gives us a place to
collaborate on a fix, request a CVE, and credit you when the advisory is published.

If GitHub private reporting is unavailable to you for any reason, contact the maintainer privately
at the address on their [GitHub profile](https://github.com/valthon) instead of filing a public
issue.

### What to include

The more of this you can provide, the faster a fix lands:

- **Version** — `zigbase --version` output, or the commit SHA you built from.
- **Build configuration** — the `-D` flags in play (`-Dpostgres`, `-Ds3`, `-Dvector`, `-Dfts5`,
  `-Ddev-mode`), since several subsystems are compile-time gated and absent from a stock build.
- **Backend** — SQLite (default) or PostgreSQL.
- **Deployment shape** — stock `zigbase serve`, the Docker image, or an embedded consumer using
  `App(.{...})`; whether it sits behind a reverse proxy and whether `--trust-proxy` is set.
- **Impact** — what an attacker gains: auth bypass, cross-tenant or cross-user data access, RCE,
  SQL injection, token/secret disclosure, denial of service.
- **Reproduction** — a minimal `curl` sequence, a failing test, or a small `App(.{...})` config.
  A concrete repro is worth more than a description.

### What to expect

- **Acknowledgement within 7 days** that the report was received and is being looked at.
- **An assessment within 14 days**: accepted (with a rough fix timeline), or declined (with the
  reasoning — see "Out of scope" below).
- **Coordinated disclosure.** We aim to ship a fix and publish the advisory within 90 days of the
  report. You are credited in the advisory unless you ask not to be. Please hold public disclosure
  until the advisory is published, or until 90 days have elapsed, whichever comes first.

ZigBase is maintained by a very small team, so timelines are best-effort rather than contractual —
but a report will never be silently ignored.

## Out of scope

These are **documented, intentional** behaviors, not vulnerabilities. Reports about them will be
closed with a pointer here — though a report that a documented mitigation *does not actually work*
is very much in scope.

- **`--insecure-cookies`.** Drops the `Secure` flag on auth cookies. It exists for plain-HTTP local
  development and is off by default; using it in production is an operator error.
- **`-Ddev-mode=true` seams.** The `ZIGBASE_FAKE_NOW` clock, `ZIGBASE_FAKE_SEED` entropy, and
  `ZIGBASE_FIELD_CRYPTO` fake crypto are compiled in only in `Debug` builds and fold to comptime
  no-ops in a release build. Demonstrating them on a dev build is expected behavior; demonstrating
  one reachable in a *release* build is a real finding.
- **`"@public"` access rules.** The explicit allow-all sentinel. Blank rules (`null` or `""`) mean
  *locked (superusers only)*; `@public` is opt-in and logs a startup warning for every rule that
  uses it. Data exposed by a rule the operator wrote as `@public` is working as designed.
- **Unauthenticated static file serving.** `--serve-static` has no access rules by design; use file
  storage for access-controlled delivery. See [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md).
- **Presigned S3 URLs as bearer capabilities.** With the opt-in
  `.files.s3_presign_redirect = true`, the issued URL is valid until it expires and is not bound to
  the requester. This trade-off is documented in [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md).
- **Spoofed `X-Forwarded-For` without `--trust-proxy`.** Proxy headers are ignored by default
  precisely because they are spoofable; the rate limiter falls back to a non-spoofable key.
- **Other entries in [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md)** — anything listed there is a
  known trade-off. If you think one is under-stated, open a normal issue and argue the case.
- **Vulnerabilities in a *consumer's* application code** — hooks, custom routes, or access rules
  written against the framework. Report those to that project.

## Dependency advisories

ZigBase statically links a vendored SQLite amalgamation, the `zap`/facil.io HTTP server, and
optionally sqlite-vec. Pinned versions are checked against a curated advisory list:

```sh
zig build audit       # compares the pinned versions against docs/security-advisories.md
zig build versions    # prints the baked-in component versions
zigbase --version     # the same, from a built binary (also exposed at GET /api/health)
```

If you know of an advisory affecting a pinned dependency, a PR adding a row to
[`docs/security-advisories.md`](docs/security-advisories.md) is welcome and does **not** need to go
through private reporting — the advisory is already public.

## Further reading

- [`docs/security-audit.md`](docs/security-audit.md) — the full threat model, every past finding
  (F1–F18) with its fix, a footgun list for integrators, and a hardening checklist for operators.
- [`KNOWN_LIMITATIONS.md`](KNOWN_LIMITATIONS.md) — current known gaps and accepted trade-offs.
