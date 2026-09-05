### Features
- Capture up to 1024 analytics events atomically with `ctx.trackBatch`, reusing one writer acquisition and prepared statement. Actor and tenant values remain server-derived; nested batches respect the enclosing transaction.

### Internal
- Lower analytics SQL into bounded stack scratch instead of allocating through a hidden global allocator.
