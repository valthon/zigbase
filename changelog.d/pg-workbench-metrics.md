### Features

- Extend the default-off query workbench to PostgreSQL prepared executions, with bounded backend-labelled route/shape statistics and client-side exchange/lifecycle timing. Buffered rows add no per-row timestamps or telemetry copies; PostgreSQL query-plan inspection remains unsupported.

### Changed

- Query-workbench stats now label each item's backend and measurement semantics. The top-level measurement is `backend-specific-see-items`; PostgreSQL durations include network/server wait and result materialization, not CPU or pool-wait time.
