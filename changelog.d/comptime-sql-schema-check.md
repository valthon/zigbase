### Features
- `zigbase.checkSql` / `checkedSql`: comptime validation of raw-SQL table/column identifiers
  against the `.collections` schema, failing the build on an unknown table or a mistyped
  qualified column. Best-effort by design (tables strict, qualified columns checked, unqualified
  columns/functions untouched) to guarantee zero false compile errors on valid SQL — including
  upserts: the `UPDATE` in `ON CONFLICT ... DO UPDATE SET` is recognized as a conflict clause
  (no table operand), not an `UPDATE <table>` statement.
- `zigbase.Query.select`: a comptime, schema-checked single-table SELECT builder that emits
  validated SQL + positional binds for `queryAs` — an unknown table/column is a build error, and
  binds are positional by construction. SELECT-only / single-table in v1 (joins, writes, and `in`
  are noted as future work).
