### Fixes

- Ranged dir-mode static downloads with a matching `If-Range` now correctly resume with a `206 Partial Content` instead of being restarted as a full `200` (RFC 9110 §13.1.5). The vendored facil.io had an inverted `If-Range` branch (it deleted the `Range` header on a match); zigbase now neutralizes it before delegating so interrupted downloads of served files resume instead of re-downloading from scratch. Owned record-file (`/api/files/…`) and embedded static serving were already RFC-correct. (#192)
