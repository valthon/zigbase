### Features

- **Dart codegen.** The client generator now emits Dart alongside TypeScript. Pass
  `--lang dart` to `zigbase typegen` (runtime introspection) or `zig build gen-client`
  (comptime, via the `genClientStep` `lang` option) to generate a `zbase.gen.dart` — concrete
  typed record classes, per-collection typed services (typed CRUD, a fluent where-builder that
  compiles to server filter strings, int/fixed decimal-string coercion, typed expand, files, and
  realtime) over the base `@zigbase/client` Dart SDK's new `package:zigbase_client/typed.dart`
  runtime. Typed `rpc.*`, auth-method, and feature-flag surfaces remain TypeScript-only for now.
