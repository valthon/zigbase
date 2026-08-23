# Cross-check of what GET /api/v1/internal/stats reported, read from a SEPARATE
# process. If the server and this disagree, the discrepancy is in the server's
# connection state, not in the stored rows.
conn = ActiveRecord::Base.connection
puts "db file      = #{conn.pool.db_config.database}"
puts "users  model=#{User.count}  sql=#{conn.select_value('SELECT COUNT(*) FROM users')}  #{User.order(:id).pluck(:id, :email).inspect}"
puts "posts  model=#{Post.count}  sql=#{conn.select_value('SELECT COUNT(*) FROM posts')}"
puts "clubs  model=#{Club.count}  unscoped=#{Club.unscoped.count}"
