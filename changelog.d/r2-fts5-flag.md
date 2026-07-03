### Features

- New `-Dfts5` build flag (default **on**): lean custom builds can drop SQLite's FTS5 (~250-400 KB). With `-Dfts5=false`, `?search=` answers 400 and a `.searchable` SQLite schema refuses at startup. Default builds are unchanged; Postgres full-text search is independent of the flag.
