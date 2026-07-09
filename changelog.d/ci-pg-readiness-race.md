### Internal

- Fixed a CI flake in the `postgres` and `postgres-tls` jobs where the readiness loop polled the postgres server itself (`pg_isready`), which can report "accepting connections" before the container entrypoint's own `createdb` step has actually created the `zbpgtest` database (postgres:16 restarts itself during init). The loops now poll the target database directly (`psql -d zbpgtest -c 'select 1'`) with a bounded retry count and a clear failure message.
