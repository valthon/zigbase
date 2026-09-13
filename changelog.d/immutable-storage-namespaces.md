### Features

- Collection files retain an engine-owned immutable namespace through offline
  renames across local, S3, and custom storage. Upload/cleanup metadata follows
  logical names transactionally without moving payload bytes or storage objects.
  Relinking uses bounded keyset batches and rejects oversized metadata rather
  than retaining an entire PostgreSQL cleanup queue in memory.

### Performance

- Index case-folded namespace reservations on SQLite and PostgreSQL so collection
  creation can probe growing tombstone ledgers without scanning every reservation.

### Breaking

- Physical namespace reservations survive collection deletion. Creating a new
  collection under a reserved prefix fails with a conflict rather than adopting
  leftover files, including case variants on all backends to protect local
  case-insensitive filesystems. Reservations are not automatically reclaimed.
  Upgrade rejects ambiguous legacy case aliases for explicit operator repair;
  unambiguous legacy prefixes retain their exact spelling.
- Custom storage callbacks receive the physical namespace, not necessarily the
  current collection name. Public URLs and hooks continue using logical names.
