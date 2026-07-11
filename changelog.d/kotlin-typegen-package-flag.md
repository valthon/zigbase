### Features

- `zigbase typegen --lang kotlin` gains a `--package <name>` flag that sets the emitted `package` declaration; unqualified invocations still default to the dating fixture's `io.github.valthon.zigbase.codegen.dating` namespace (keeping the committed golden and `zig build gen-dating-kotlin-client` byte-stable), so no hand-editing of the generated file is needed to target your own app's package.
