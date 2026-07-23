### Fixes
- A collection field's `hidden` flag is now persisted and round-trips through a reload. It was never written to the stored schema, so every collection load silently reset user fields to `hidden = false` (the API and admin then reported hidden fields as visible); it now survives create/update/get correctly.
- Fixed a memory leak on the auth-collection load path: `get` (and the create/update it now backs) leaked the inner fields array when prepending the auth system columns, on non-arena allocators.

### Internal
- `schema.Collection` gained a `deinit(alloc)` that frees a fully-owned collection graph, and `collections.create`/`update` now return a fully-owned reload of the just-written row instead of a mixed-ownership hand-assembled value — so a non-arena caller (or a test) can free the result with one call. This is the foundation for removing the arena masking from the collection/record engine tests.
