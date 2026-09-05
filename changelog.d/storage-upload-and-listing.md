### Breaking
- Record-file uploads write bytes before acquiring the database writer. Storage plugins must not assume the destination record exists during `put`. Upload POST returns `409` on collection changes during transfer; upload PATCH also returns `409` on record changes and requires update access to the existing row before transfer as well as the updated row before commit.

### Fixes
- S3 record cleanup follows all listing pages, decodes XML-escaped keys, and rejects malformed or out-of-prefix results instead of silently leaving later pages behind.
- Failed uploads clean up the object whose PUT failed as well as earlier writes, covering partial writes and lost replies.

### Internal
- Exercise upload writer availability, concurrent-update conflicts, failure cleanup, and S3 pagination with regression tests.
