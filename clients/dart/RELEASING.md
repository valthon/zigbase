# Releasing `zigbase_client` (Dart)

The Dart SDK is versioned **independently** of the ZigBase server, exactly like the
TypeScript SDK (see [`clients/typescript/RELEASING.md`](../typescript/RELEASING.md)).

- The **server** is released with `vX` tags (e.g. `v0.11.0`).
- The **TypeScript SDK** is released with `client-v*` tags (e.g. `client-v0.3.0`).
- The **Dart SDK** is released with `dart-client-v*` tags (e.g. `dart-client-v0.1.0`) — a
  distinct prefix from the TypeScript SDK's `client-v*`, since the two packages version
  independently and a shared prefix would collide.

## Status: publishing is not yet automated

**This package is not yet published to pub.dev**, and there is no `release-sdk-dart.yml`
CI workflow (unlike the TypeScript SDK's `release-sdk.yml`). The first publish is a
documented follow-up:

1. Reserve/verify the `zigbase_client` name on pub.dev.
2. Add a `release-sdk-dart.yml` workflow (analyze, test, `dart pub publish --dry-run`) that
   triggers on a pushed `dart-client-v*` tag — mirroring `release-sdk.yml`'s shape (typecheck,
   test, build, assert the tag matches `pubspec.yaml`'s `version`, publish).
3. Configure pub.dev **automated publishing** (pub.dev's GitHub Actions OIDC integration —
   the Dart-ecosystem equivalent of npm trusted publishing): no long-lived credentials in CI,
   gated on the repository + workflow filename, same posture as npm's trusted publisher for
   `@zigbase/client`.
4. Cut the first release manually (`dart pub publish` from a maintainer machine) if pub.dev's
   automated-publishing setup requires the package to already exist, then hand releases off
   to CI for every subsequent tag — the same bootstrap sequence the TypeScript SDK followed.

Until all four steps land, **do not tag a `dart-client-v*` release** — there is nothing on
the other end to consume the tag push.

## Cutting a release (once automated)

1. Bump the version in `clients/dart/pubspec.yaml` (e.g. `0.1.0` → `0.1.1`). Follow semver.
2. Update `clients/dart/CHANGELOG.md` with the new version's entries.
3. Commit the bump:
   ```bash
   git commit -am "chore(dart-sdk): release dart-client-v0.1.1"
   ```
4. Tag with the matching `dart-client-v<version>` tag (the version after the prefix MUST
   equal `pubspec.yaml`'s `version`, or the workflow should fail its assertion):
   ```bash
   git tag dart-client-v0.1.1
   ```
5. Push the commit and the tag:
   ```bash
   git push origin main
   git push origin dart-client-v0.1.1
   ```
6. The release workflow runs on the pushed tag and publishes `zigbase_client@0.1.1` to
   pub.dev.

## Notes

- `pubspec.lock` is not published (pub.dev packages are libraries, not applications); pub.dev
  resolves consumer dependency ranges from `pubspec.yaml` directly.
- The workflow does **not** build or run the Zig server / integration tests — the merge CI
  already covers those (`zig build test` + the unit suite in `clients/dart/test/`, tagged
  `integration` tests opt-in via `ZIGBASE_TEST_BINARY`, see
  [docs/dart-sdk.md](../../docs/dart-sdk.md#integration-test-recipe)). SDK releases should stay
  fast and deterministic, mirroring the TypeScript SDK's release posture.
