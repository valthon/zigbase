### Internal

- `mail/unsubscribe.verify` now returns an owned `Parts` (contract-2) with a `deinit` that frees its decode buffer, instead of leaving the buffer for a caller arena to reclaim. Its own tests plus the `mail/bulk.zig` `jobHandler` List-Unsubscribe test now run under the raw leak-detecting `std.testing.allocator`; `mail/bulk.zig` drops off the allocator allowlist and `api/mail_unsubscribe.zig`'s entry is rewritten to state its genuine RequestArena (contract-4) handler-test justification.
