conn = ActiveRecord::Base.connection
conn.tables.sort.each do |table|
  n = conn.select_value("SELECT COUNT(*) FROM #{conn.quote_table_name(table)}")
  puts format("%-34s %d", table, n)
end
