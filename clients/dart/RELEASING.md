# Releasing `zigbase_client` (Dart)

The Dart SDK is versioned **independently** of the ZigBase server, exactly like the
TypeScript SDK (see [`clients/typescript/RELEASING.md`](../typescript/RELEASING.md)).

- The **server** is released with `vX` tags (e.g. `v0.11.0`).
- The **TypeScript SDK** is released with `client-v*` tags (e.g. `client-v0.3.0`).
- The **Dart SDK** is released with `dart-client-v*` tags (e.g. `dart-client-v0.1.0`) — a
  distinct prefix from the TypeScript SDK's `client-v*`, since the two packages version
  independently and a shared prefix would collide.

## Prerequisites

`zigbase_client` publishes via pub.dev's **automated publishing** (GitHub Actions OIDC,
the Dart-ecosystem equivalent of npm trusted publishing) — the
[`release-dart-sdk.yml`](../../.github/workflows/release-dart-sdk.yml) workflow needs no
token (`id-token: write` only). This depends on **one-time setup by the repository owner**
on pub.dev (below), which has not happened yet — see [Status](#status-first-publish-pending)
before tagging a release.

### One-time owner setup (do this before the first tag)

pub.dev's automated publishing binds to the **GitHub repository + a tag pattern**, configured
on the package's own Admin tab — this is *different* from npm, where the trusted publisher
binds to the workflow **filename**. Renaming `release-dart-sdk.yml` is safe on pub.dev's side;
changing the tag pattern (or the repository) is not.

1. **First publish must be manual.** Per pub.dev's docs, *"you can only automate publishing
   of existing packages — to create a new package, you must publish the first version using
   `dart pub publish`."* There is no pub.dev Admin tab for a package that doesn't exist yet,
   so automated publishing cannot be configured until after this step. From a maintainer
   machine with `dart pub login` already done:
   ```bash
   cd clients/dart
   mise exec dart@3.12 -- dart pub publish
   ```
   This reserves the `zigbase_client` name and publishes the version currently in
   `pubspec.yaml`.
2. **Enable automated publishing.** On `pub.dev/packages/zigbase_client/admin`, under
   *Automated publishing*, click *Enable publishing from GitHub Actions* and set:
   - **Repository**: `valthon/zigbase`
   - **Tag pattern**: `dart-client-v{{version}}` — must stay **in sync with** (not
     textually identical to) the `on.push.tags` glob in `release-dart-sdk.yml` (currently
     `dart-client-v*`): pub.dev's `{{version}}` placeholder and the workflow's `*` glob must
     accept the same tags, or the workflow either won't trigger or won't be allowed to
     publish.
3. **Optional hardening — GitHub Actions environment.** `release-dart-sdk.yml`'s publish job
   already sets `environment: pub.dev`, but that's inert until pub.dev is told to require it:
   on the same Admin tab, click *Require GitHub Actions environment*, name it `pub.dev`, and
   create a matching environment under the repo's **Settings → Environments** (optionally with
   required reviewers, mirroring `tests/admin`-style safe-by-default posture). Until this is
   done, the workflow publishes without the extra gate.
4. **Optional — tag protection.** Restrict who can push `dart-client-v*` tags with a
   repository ruleset (**Settings → Rules → Rulesets**, targeting tags) to limit who can
   trigger a publish, independent of step 3. (The classic **Settings → Tags** tag-protection
   page still exists, but rulesets are GitHub's current mechanism.)

Once steps 1–2 are done, every subsequent `dart-client-v*` tag push publishes automatically —
no further manual `dart pub publish` needed.

## Status: first publish pending

`zigbase_client` is not yet on pub.dev — step 1 above has not been run. **Do not tag a
`dart-client-v*` release** until it has; `release-dart-sdk.yml` exists and will run on the
tag, but its `publish` job cannot succeed against a package that pub.dev doesn't know yet
(and step 2's Admin-tab configuration doesn't exist for an unpublished package either).

## Cutting a release

1. Bump the version in `clients/dart/pubspec.yaml` (e.g. `0.1.0` → `0.1.1`). Follow semver.
2. Update `clients/dart/CHANGELOG.md` with the new version's entries.
3. Commit the bump:
   ```bash
   git commit -am "chore(dart-sdk): release dart-client-v0.1.1"
   ```
4. Tag with the matching `dart-client-v<version>` tag (the version after the prefix MUST
   equal `pubspec.yaml`'s `version`, or the workflow fails its assertion):
   ```bash
   git tag dart-client-v0.1.1
   ```
5. Push the commit and the tag:
   ```bash
   git push origin main
   git push origin dart-client-v0.1.1
   ```
6. The `release-dart-sdk.yml` workflow runs on the pushed tag: it analyzes, format-checks,
   runs unit tests, asserts the tag matches `pubspec.yaml`, dry-runs the publish, then (via
   [`dart-lang/setup-dart`'s reusable publish workflow](https://dart.dev/tools/pub/automated-publishing))
   publishes `zigbase_client@0.1.1` to pub.dev over OIDC.

## Notes

- `pubspec.lock` is not published (pub.dev packages are libraries, not applications); pub.dev
  resolves consumer dependency ranges from `pubspec.yaml` directly.
- The workflow does **not** build or run the Zig server / integration tests — the merge CI
  already covers those (`zig build test` + the unit suite in `clients/dart/test/`, tagged
  `integration` tests opt-in via `ZIGBASE_TEST_BINARY`, see
  [docs/dart-sdk.md](../../docs/dart-sdk.md#integration-test-recipe)). SDK releases should stay
  fast and deterministic, mirroring the TypeScript SDK's release posture.
