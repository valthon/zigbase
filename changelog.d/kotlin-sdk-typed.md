### Features

- Kotlin SDK typed tier: `zigbase typegen --lang kotlin` generates `@Serializable` record data classes with `fromRecord` coercion, `Create`/`Update` payloads with `toMap` wire encoding, injection-safe fluent filter builders, and typed collection services (plus Flow-based typed realtime) over the new `io.github.valthon.zigbase.typed` runtime — golden-gated in CI against the dating fixture.
