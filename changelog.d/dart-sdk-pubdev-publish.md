### Internal

- Added `release-dart-sdk.yml`, a `dart-client-v*`-tag-triggered workflow that verifies
  (`dart analyze`, format check, unit tests, tag/`pubspec.yaml` version consistency,
  `dart pub publish --dry-run`) and then publishes `zigbase_client` to pub.dev via the
  official OIDC-based automated-publishing flow. The first publish still needs one-time
  owner setup on pub.dev — see `clients/dart/RELEASING.md`.
