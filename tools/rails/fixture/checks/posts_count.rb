puts "id | slug             | posts_count (trigger-maintained) | actual COUNT(*)"
Club.unscoped.order(:id).each do |c|
  actual = ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM posts WHERE club_id = #{c.id}")
  puts format("%-2d | %-16s | %-32d | %d", c.id, c.slug, c.posts_count, actual)
end
