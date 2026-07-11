### Features
- `zigbase.checkSql` / `checkedSql`: comptime validation of raw-SQL table/column identifiers
  against the `.collections` schema, failing the build on an unknown table or a mistyped
  qualified column. Best-effort by design (tables strict, qualified columns checked, unqualified
  columns/functions untouched) to guarantee zero false compile errors on valid SQL.
