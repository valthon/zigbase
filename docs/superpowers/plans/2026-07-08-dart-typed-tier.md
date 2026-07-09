# Dart typed / codegen tier — implementation plan

Spec: `docs/superpowers/specs/2026-07-08-dart-typed-tier-design.md`. Branch: `feat/dart-typed-tier`.
Toolchains via mise (zig@0.16.0, dart@3.12, node@24, python@3.13).

## Chapter 1 — Dart typed runtime (`clients/dart/lib/typed.dart`) + unit tests

1. Create `clients/dart/lib/typed.dart` exporting the runtime described in spec §4:
   `FieldType`/`NumberMode`/`FieldMeta`/`CollectionMeta`; `Expr` + `FieldExpr` family
   (`StringFieldExpr`, `NumFieldExpr`, `BoolFieldExpr`, `EnumFieldExpr<E>`, `RelFieldExpr<F>`);
   `coerceInt`/`coerceDouble`/`coerceString`/list helpers; `TypedList<T>`/`TypedCursorPage<T>`;
   `TypedCollection<T>`; `TypedRealtimeEvent<T>`/`TypedRealtime<T>`. Reuse `src/query.dart`'s
   `filterValue` for operand serialization (import it internally; re-export nothing private).
2. Unit tests (`clients/dart/test/typed_where_test.dart`, `typed_coerce_test.dart`,
   `typed_service_test.dart`) — MockClient pattern from the base SDK. Cover operators, nesting
   (`author.name ~`), `inList` incl. empty, enum wire mapping, int/fixed round-trip, list mapping.
3. Gate: `dart analyze --fatal-infos`, `dart format --set-exit-if-changed`, `dart test --exclude-tags integration`.
4. Fold spec + plan commit here (chapter 1 = runtime + design docs).

## Chapter 2 — Zig generator Dart emission + golden test

1. `src/codegen/dart_type.zig`: `DartKind`, `dartBaseTypeOf`, `dartTypeOf`, `selectEnumName`,
   `dartValueType` (record vs create/update nullability). Unit tests.
2. `src/codegen/emit_dart.zig`: per-collection fragment emitters (enums, record + expand class,
   create/update, fields builder, meta const, service, realtime, files, factory). Reuse
   `identifiers.pascal`/`recordName`; add Dart reserved-name guard as needed.
3. `src/codegen/gen_dart.zig`: `pub fn generate(...)` — same signature as `gen_client.generate`;
   header (schema-hash + `ignore_for_file`), imports, loop over collections, factory. RPC section
   stubbed behind a comptime-routes check (implement if budget; else omit cleanly).
4. Thread `--lang ts|dart`: `cli.zig` `TypegenArgs.lang` + parse; `typegen_cli.Options.lang` +
   `run()` dispatch; `gen_client.parseArgsSlice`/`mainWithCollections` `--lang`; `build.zig`
   `GenOpts.lang` + `genClientStep`; `framework.zig` dispatch. Add all new files to `root.zig`'s
   test import block.
5. `build.zig`: `gen-dating-dart-client` + `gen-dating-dart-client-check` steps (out =
   `clients/dart/test/codegen/dating/zbase.gen.dart`); `gen-dart-test` golden byte-exact test
   wired into `test_step`.
6. Generate the snapshot, commit it, then `dart analyze` it to prove the emitted Dart is valid.
7. Gate: `zig build test --summary all` (authoritative `Build Summary` line), `zig build gen-dating-dart-client-check`.

## Chapter 3 — E2E proof + CI

1. `clients/dart/test/integration/typed_dating_test.dart` (tagged `integration`): mirror
   `dating.integration.test.ts` — spawn dating-server via the existing Dart harness (extend
   `harness.dart` with a `DATING_BINARY` env + `startAppServer(bin:)` if needed), run CRUD +
   nested filter + expand + cursor + realtime + files. No-op skip when env unset.
2. Import the committed `zbase.gen.dart` from the test (path import) so a compile failure of the
   generated file fails the suite.
3. `.github/workflows/ci.yml`: `dart-sdk` job exports `ZIGBASE_TEST_DATING_BINARY` (download the
   prebuilt `dating-server` artifact like `ts-sdk`) and runs the typed integration test; `build`
   job runs `zig build gen-dating-dart-client-check`.
4. Gate locally: `ZIGBASE_TEST_DATING_BINARY=<abs> dart test --tags integration` green.

## Chapter 4 — Docs + changelog + PR

1. `docs/dart-sdk.md`: add `## Typed tier` section (mirror the TS `## Typed client` structure:
   which tier, generate, create client, records, typed where/fluent, expand, realtime, files,
   int/fixed note). Mirror into `site/src/content/docs/dart-sdk.md` (or the site path). Build the
   site if docs changed (`cd site && npm run build`).
2. `changelog.d/dart-typed-tier.md` (`### Features`): generator now emits Dart (`--lang dart`).
   `clients/dart/CHANGELOG.md` 0.1.0 `### Added`: typed tier runtime.
3. `docs/typescript-sdk.md`: add the `--lang` flag to the typegen flags table (shared behavior).
4. `tell-a-git-story`; rename branch `feat/dart-typed-tier`; push; open DRAFT PR
   `feat(dart-sdk): typed client tier + Dart codegen` with an honest scope statement.

## Risks / notes

- Snapshot churn: keep emitted Dart deterministic (sorted collections already guaranteed by
  acquisition; iterate fields in schema order like TS).
- `dart analyze --fatal-infos` on generated code: prepend `ignore_for_file` for
  `non_constant_identifier_names`/`unused_element`/`unused_import`.
- Expand narrowing is nullable-by-design (Dart limitation) — document it, don't fake it.
- If RPC/auth-method/flags don't fit, omit their sections cleanly and state so in the PR + report.
