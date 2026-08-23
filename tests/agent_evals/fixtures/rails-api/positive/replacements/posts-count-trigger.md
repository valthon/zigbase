# posts_count maintenance

The source keeps `clubs.posts_count` with three SQLite triggers. The target
recomputes it in an after-create/after-delete hook on `posts`, so the value is
maintained by code that ships with the application rather than by DDL nobody
reads.
