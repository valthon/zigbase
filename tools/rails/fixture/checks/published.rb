scope = Notification.where(kind: "post.published").order(:id)
puts "post.published notifications = #{scope.count} (total notifications = #{Notification.count})"
scope.each { |n| puts "  ##{n.id} user=#{n.user_id} #{n.payload.inspect}" }
