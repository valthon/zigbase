### Features

- Add bounded finalized-statement lifecycle timing to the opt-in SQLite query workbench, separating measured prepare/step/reset/finalize calls from held intervals without changing existing execution/slow counters. Default-off builds retain no added state or instrumentation.
