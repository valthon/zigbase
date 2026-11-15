### Fixes
- On PostgreSQL, deleting a record of an auth collection over REST now succeeds and removes its OAuth links. It used to answer 500 and leave the record in place, because the OAuth-link cleanup sent SQLite placeholders to PostgreSQL (#519).
