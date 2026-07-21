### Internal

- Restore leak detection across the codegen module and make it contract-1 correct. 86
  leak-detector-masked tests in `src/codegen/` were converted to run under
  `std.testing.allocator`, which surfaced pervasive ownership bugs the masking arena hid:
  `identifiers.recordName` returned a sub-slice of an internal allocation (freeing it was an
  invalid free — a latent crash for any non-arena caller); the shared `emit.putf` format
  helper leaked at every call site; every language generator (`gen_client`/`gen_python`/
  `gen_kotlin`/`gen_dart`) leaked all of its scratch; and several type mappers and name
  manglers leaked intermediates. All are fixed — generators now own their scratch in an
  internal arena and return a single caller-owned slice; helpers free what they own; the
  `ts`/`dart`/`python`/`kotlin` type mappers return a uniform always-owned string. An
  adversarial review additionally caught a leak of the whole generated buffer on
  `gen_client.generate`'s reachable `error.RpcTypeNameCollision` path (now guarded by
  `errdefer`). Generated client output is byte-identical (golden snapshots unchanged). Six
  `acquire*`/`typegen_cli` tests remain arena-scoped, blocked on a single missing primitive —
  a `schema.freeCollections` deep-free — now recorded with that reason in the allocator
  allowlist. This is a build-time tool, so none of these bugs affected the shipped server.
