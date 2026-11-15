### Security
- Keep the source row locked on PostgreSQL while authorizing and validating preserved relation ids, including idempotent updates.

### Performance
- Check source read access for preserved relation ids only when tenant-scoped relation validation needs it.
