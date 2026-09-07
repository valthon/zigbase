### Features
- Opt into durable HTTP file replacement/deletion cleanup with `.files.cleanup_queue`, using a declared durable queue for transactional enqueue, retries, physical-reference-safe replacement cleanup, and guarded record-prefix deletion on local or S3 storage.
