### Fixes
- SQLite `-Dvector=true` builds: `?vector=` list queries no longer fail with a 500 (`no such function: vec_distance_cosine`). Pooled reader connections now register sqlite-vec like the writer does, and every SQLite connection is opened through one constructor so the per-connection functions cannot drift apart again (#488).
