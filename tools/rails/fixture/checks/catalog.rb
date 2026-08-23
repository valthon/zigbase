# Triggers and views, read straight out of the SQLite catalog.
rows = ActiveRecord::Base.connection.select_all(
  "SELECT type, name, tbl_name FROM sqlite_master WHERE type IN ('trigger','view') ORDER BY type, name"
)
if rows.to_a.empty?
  puts "(none)"
else
  rows.each { |r| puts format("%-8s %-32s %s", r["type"], r["name"], r["tbl_name"]) }
end
