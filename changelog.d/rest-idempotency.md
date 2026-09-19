### Features
- Opt-in authenticated JSON record create/update/delete retry receipts persist atomically with SQLite/PostgreSQL mutations, with bounded retention/capacity, current replay authorization and explicit unsupported-operation refusal.

### Fixes
- Native tenant membership resolution now uses PostgreSQL parameter placeholders, including authorization inside mutation transactions.
- TypeScript record and generated typed services accept explicit `idempotencyKey` options; combined durable replay captures only the first committed mutation.
- Hold schema-generation coordination through keyed authorization and commit, including receipt replay, with PostgreSQL concurrency coverage.
- Use GET-shaped replay visibility, preserve validation details without dangling request pointers, and refuse reuse of an unrecoverable database writer.
