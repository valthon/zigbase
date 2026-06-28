### Features
- TypeScript client codegen now emits **precise typed I/O for custom auth methods**. Enable a custom method in the new struct form — `.custom = &.{ .{ .slug = "corp-sso", .Initiate = .{ .Input = …, .Output = … }, .Complete = .{ .Input = …, .Output = … } } }` — and `zig build gen-client` reflects the declared Zig types into `zb.auth.<col>.<method>.{initiate,complete}` interfaces (named by the Zig type, like the typed `zb.rpc.*` route surface). A `void` Input omits the input argument; a `void` Output maps to `Promise<void>`. Bare-string slugs (`.custom = .{"slug"}`) stay fully back-compatible and untyped. Typed customs are a build-time feature (the runtime-introspection typegen tier keeps them untyped, exactly like typed routes).
</content>
</invoke>
