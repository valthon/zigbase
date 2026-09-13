### Fixes

- Make `superuser create` use PostgreSQL-compatible bound parameters and timestamps when PostgreSQL is selected. Failed insertions, including duplicate emails on either backend, now return a nonzero exit status instead of reporting process success; existing operator passwords are preserved.
