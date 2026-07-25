### Internal

- Collapsed a duplicated JSON deep-clone helper: `records.zig`'s private `coerceClone` (used by
  multipart field coercion) was a byte-for-byte copy of `values.zig`'s private `cloneValue`. Made
  `values.cloneValue` public and deleted the records-side duplicate, so the multipart coercion path
  reuses the single canonical clone.
