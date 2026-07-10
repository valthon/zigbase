# Releasing `zigbase-client` (Kotlin)

The Kotlin SDK is versioned **independently** of the ZigBase server, exactly like the
TypeScript SDK (see [`clients/typescript/RELEASING.md`](../typescript/RELEASING.md)), the
Dart SDK (see [`clients/dart/RELEASING.md`](../dart/RELEASING.md)), and the Python SDK (see
[`clients/python/RELEASING.md`](../python/RELEASING.md)).

- The **server** is released with `vX` tags (e.g. `v0.11.0`).
- The **TypeScript SDK** is released with `client-v*` tags (e.g. `client-v0.3.0`).
- The **Dart SDK** is released with `dart-client-v*` tags (e.g. `dart-client-v0.1.0`).
- The **Python SDK** is released with `python-client-v*` tags (e.g. `python-client-v0.1.0`).
- The **Kotlin SDK** is released with `kotlin-client-v*` tags (e.g. `kotlin-client-v0.1.0`) —
  a distinct prefix from the other three, since all four packages version independently and
  a shared prefix would collide.

## > FIRST PUBLISH PENDING — do not push `kotlin-client-v*` until the secrets exist

`io.github.valthon:zigbase-client` is not yet on Maven Central. **Do not push a
`kotlin-client-v*` tag** until every item in [One-time owner setup](#one-time-owner-setup-do-this-before-the-first-tag)
below is done and the four repository secrets exist — `release-kotlin-sdk.yml`'s `publish`
job will run on the tag regardless, and will fail loudly (missing credentials / unverified
namespace) rather than silently no-op, but a failed release run still burns a tag you'd have
to re-cut under a new version. See [Status](#status-first-publish-pending).

## Prerequisites

Unlike PyPI (OIDC Trusted Publishing) and pub.dev (OIDC automated publishing), **Maven
Central has no GitHub Actions OIDC integration** — publishing goes through
[Central Portal](https://central.sonatype.com/), Sonatype's current (post-OSSRH) publishing
service, authenticated with a **user token** (a long-lived username/password pair, scoped to
your Central Portal account) plus a **GPG signature** on every artifact (a Maven Central
hard requirement, unlike PyPI/pub.dev). `release-kotlin-sdk.yml`'s `publish` job therefore
has **no `id-token: write` permission** anywhere in the file — there is nothing to exchange
an OIDC token for — and instead reads four secrets (below) into
`ORG_GRADLE_PROJECT_*`-prefixed env vars that the
[`com.vanniktech.maven.publish`](https://github.com/vanniktech/gradle-maven-publish-plugin)
Gradle plugin (configured in `build.gradle.kts`) reads directly.

### One-time owner setup (do this before the first tag)

1. **Verify the `io.github.valthon` namespace on Central Portal.** Central Portal grants a
   namespace automatically once you prove control of it — for a `io.github.*` groupId, that
   means proving control of the `valthon` **GitHub account** (not a custom domain):
   1. Sign in to <https://central.sonatype.com/> with (or link) the `valthon` GitHub account.
   2. Under **Namespaces**, add `io.github.valthon`. Central Portal verifies GitHub-account
      namespaces automatically (no DNS TXT record needed, unlike a custom-domain namespace) —
      this is normally near-instant once you're signed in as that account.
2. **Generate a Central Portal user token.** On <https://central.sonatype.com/account>,
   generate a **user token** (NOT your account password — the token is a separate
   username/password-shaped credential scoped for automation). Save both halves; the token is
   shown once.
   - Repo secret **`MAVEN_CENTRAL_USERNAME`** = the token's username half.
   - Repo secret **`MAVEN_CENTRAL_PASSWORD`** = the token's password half.
3. **Generate a GPG key and publish it to a keyserver.** Central Portal validates that every
   uploaded artifact is signed by a key resolvable from a public keyserver:
   ```bash
   gpg --batch --gen-key <<'EOF'
   %no-protection
   Key-Type: RSA
   Key-Length: 4096
   Name-Real: <your name>
   Name-Email: <the email you publish under>
   Expire-Date: 2y
   %commit
   EOF
   gpg --list-secret-keys --keyid-format long   # note the key id (after "rsa4096/")
   gpg --keyserver keyserver.ubuntu.com --send-keys <KEY_ID>
   # A second keyserver improves propagation odds; Central Portal accepts any of the
   # common ones (keyserver.ubuntu.com, keys.openpgp.org, pgp.mit.edu).
   gpg --keyserver keys.openpgp.org --send-keys <KEY_ID>
   gpg --armor --export-secret-keys <KEY_ID> > signing-key.asc
   ```
   - Repo secret **`MAVEN_CENTRAL_SIGNING_KEY`** = the full contents of `signing-key.asc`
     (the ASCII-armored **private** key block, `-----BEGIN PGP PRIVATE KEY BLOCK-----` …
     `-----END PGP PRIVATE KEY BLOCK-----`).
   - Repo secret **`MAVEN_CENTRAL_SIGNING_KEY_PASSWORD`** = the key's passphrase (empty
     string is fine if you generated it with `%no-protection` above — set the secret to an
     empty value rather than omitting it, since the workflow always sets the env var).
   - **Securely delete `signing-key.asc` from disk** once the secret is saved
     (`shred -u signing-key.asc` or equivalent) — it is a long-lived private key.
4. **Add the four secrets to this repository.** Under **Settings → Environments**, create an
   environment named `maven-central` (matching `release-kotlin-sdk.yml`'s
   `environment: maven-central`) and add all four secrets there (rather than
   repository-wide secrets) — this scopes them to only the release workflow's `publish` job,
   and lets you optionally add required reviewers for extra release-time gating.
5. **Optional — tag protection.** Restrict who can push `kotlin-client-v*` tags with a
   repository ruleset (**Settings → Rules → Rulesets**, targeting tags) to limit who can
   trigger a publish.

### Automatic vs. manual release on Central Portal

`build.gradle.kts`'s `publishToMavenCentral()` call uses the plugin's default
(`automaticRelease = false`): a `kotlin-client-v*` tag's `publish` job uploads a **deployment**
that lands in Central Portal in a `PENDING`/`VALIDATED` state, not yet visible to consumers.
After the workflow succeeds, sign in to <https://central.sonatype.com/publishing/deployments>,
confirm the deployment validated cleanly (correct coordinates, POM, sources/javadoc jars,
valid signatures), and click **Publish** to release it — typically live within ~30 minutes.
This manual checkpoint is deliberate for a package's early releases; switching to
`publishToMavenCentral(automaticRelease = true)` later (once the release process is trusted)
is a one-line `build.gradle.kts` change.

## Status: first publish pending

`io.github.valthon:zigbase-client` is not yet on Maven Central — none of the one-time setup
above has been run. **Do not tag a `kotlin-client-v*` release** until it has (see the banner
at the top of this file).

## Cutting a release

1. Bump the version in `clients/kotlin/build.gradle.kts`'s top-level `version = "…"` (e.g.
   `0.1.0` → `0.1.1`). Follow semver.
2. Move `clients/kotlin/CHANGELOG.md`'s `## [Unreleased]` entries under a new
   `## [0.1.1] - <date>` heading (keep a fresh empty `## [Unreleased]` above it for the next
   round of changes).
3. Commit the bump:
   ```bash
   git commit -am "chore(kotlin-sdk): release kotlin-client-v0.1.1"
   ```
4. Tag with the matching `kotlin-client-v<version>` tag (the version after the prefix MUST
   equal `build.gradle.kts`'s `version`, or the workflow's assertion step fails closed):
   ```bash
   git tag kotlin-client-v0.1.1
   ```
5. Push the commit and the tag:
   ```bash
   git push origin main
   git push origin kotlin-client-v0.1.1
   ```
6. The `release-kotlin-sdk.yml` workflow runs on the pushed tag:
   - `verify` runs `spotlessCheck build` (format/lint/unit tests), asserts the tag matches
     `build.gradle.kts`, and runs `publishToMavenLocal` as a sanity check — all **without**
     any signing secrets (see [Prerequisites](#prerequisites); `signAllPublications()` is
     gated in `build.gradle.kts` on the in-memory signing key actually being present).
   - `publish` re-resolves and rebuilds from source (this time with the four secrets present)
     and runs `gradle publishToMavenCentral`, which builds the jar/sources/javadoc artifacts,
     GPG-signs them, and uploads a deployment to Central Portal.
   - Finish the release per [Automatic vs. manual release](#automatic-vs-manual-release-on-central-portal)
     above.

## Notes

- The workflow does **not** build or run the Zig server / integration tests — the merge CI
  already covers those (`zig build test` + the unit suite in `clients/kotlin/src/test/`,
  `integrationTest` opt-in via `ZIGBASE_TEST_BINARY`/`ZIGBASE_TEST_DATING_BINARY`, see the
  `kotlin-sdk` job in `.github/workflows/ci.yml`). SDK releases stay fast and deterministic,
  mirroring the TypeScript/Dart/Python SDKs' release posture.
- The `publish` job rebuilds from source rather than reusing `verify`'s build outputs (unlike
  the PyPI/pub.dev lanes' upload/download-artifact handoff) — GPG signing wires the `.asc`
  files into the publication as part of the same Gradle invocation that assembles it, so
  there is no unsigned intermediate artifact worth passing between jobs.
- The Maven **groupId** is `io.github.valthon` and the **artifactId** is `zigbase-client`
  (`coordinates(...)` in `build.gradle.kts`) — distinct from the Gradle project name
  (`rootProject.name` in `settings.gradle.kts`, also `zigbase-client`) which they happen to
  match here, but are two different Gradle concepts.
