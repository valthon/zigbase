### Fixes

- Generated Dart/Python/Kotlin client headers now point consumers at the real regeneration path — your server's `typegen --lang <lang>` command (or the build-time comptime gen-client build step) — instead of the repo-internal `zig build gen-dating-*-client` step, which only exists in this repo and does not exist in a consumer's project.
- The comptime `gen-client` build step now honors `--package <name>` for Kotlin instead of hardcoding the dating fixture's `io.github.valthon.zigbase.codegen.dating` namespace, so a consumer wiring `genClientStep` with `lang: "kotlin"` no longer gets an unoverridable wrong `package` declaration in a file marked "do not edit" (unqualified invocations still default to the dating namespace, keeping the committed golden byte-stable).

### Internal

- Hoisted the byte-identical, language-neutral schema-query helpers that the four client emitters (`emit.zig` / `emit_dart.zig` / `emit_kotlin.zig` / `emit_python.zig`) each kept their own copy of into a single `src/codegen/schema_query.zig`. The visible auth fields are now derived from the canonical `schema.authSystemFields()` (filtered to its non-hidden subset) rather than a hand-maintained triple in each emitter, so a new non-hidden auth system field flows into every generated SDK automatically instead of silently diverging until all four copies are edited. Pure refactor — generated client bytes are unchanged.
- Corrected the Dart/Python/Kotlin generator module docs, which claimed the shared identifier guard is "language-neutral": it is TS-derived (TS identifier validity + the TS typed-core reserved-name set) and applied to every language as a conservative lowest common denominator, with the actual per-language keyword/member sanitizing living in each emitter.
