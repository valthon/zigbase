### Fixes
- Postgres SCRAM authentication now applies RFC 4013 SASLprep to passwords: soft hyphens are stripped and non-ASCII spaces map to space before PBKDF2, prohibited/bidi-invalid and non-UTF-8 passwords keep PostgreSQL's own use-verbatim parity, and a password that would require NFKC normalization fails loudly at connect with a message naming the fix (previously: verbatim bytes and a mysterious `password authentication failed`). Printable-ASCII passwords are byte-identical fast-path (zero allocation).

### Security
- The SASLprep mapping/prohibited/bidi/NFKC-quick-check sets are vendored-generated range tables (`scripts/gen-saslprep-tables.py` over the frozen RFC 3454 appendices + Unicode 16.0.0 UCD extracts) — auditable binary-search tables, mechanical to bump.
