### Security

- Hardened attacker-facing parsers and auth/WebAuthn owned-result builders against leaks on allocation failures, and made multipart request-arena ownership explicit.

### Internal

- Added bounded coverage-guided fuzz targets for filter, query-string, PostgreSQL connection-string, and WebAuthn parsers.
