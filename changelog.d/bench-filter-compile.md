### Internal

- Add a `query/filter-compile` benchmark (`zig build bench`): lex -> parse -> compile a
  moderately complex filter into parameter-bound SQL, the SQL-injection-critical path every
  filtered list request runs. Measured ~24 allocations / ~6us under the request arena with no
  large allocations — a useful negative result confirming filter compilation is not a hotspot
  (~40x cheaper than a record list read) and is not the source of the record list's larger
  allocations. Reached via the existing `dev_mode`-gated `internal` seam (extended with the
  query modules), so it adds nothing to the shipped public surface.
