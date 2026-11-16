### Fixes
- Refuse SQLite rebuilds shadowed by TEMP tables, views or indexes, and keep rebuild table statements in the main database.
- Refuse collection updates that remove an index used by a migration trigger through `INDEXED BY`.
