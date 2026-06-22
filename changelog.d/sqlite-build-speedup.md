### Performance

- Trim unused subsystems from the vendored SQLite amalgamation (`OMIT_UTF16`, `OMIT_DECLTYPE`, `OMIT_DEPRECATED`, `OMIT_PROGRESS_CALLBACK`, `OMIT_TRACE`, `OMIT_SHARED_CACHE`, `DEFAULT_MEMSTATUS=0`). The framework uses only SQLite's UTF-8 prepare/step/bind/column/exec surface, so this is a pure build-cost/size win — a smaller shipped binary and ~10% faster SQLite C compile — with no behavior change. FTS5 is intentionally retained.

### Internal

- Cache Zig's **local** cache dir (`ZIG_LOCAL_CACHE_DIR`) across CI runs, where the compiled SQLite object actually lives. The previous "global cache" step only persisted toolchain artifacts (compiler_rt/translate-c), so every CI run recompiled the SQLite amalgamation once per `zig build` invocation (~6×/run: main + each example + the unit job). All builds in a job now share one cached local dir, eliminating those recompiles on warm cache. Corrected the misleading comment on the global-cache step.
