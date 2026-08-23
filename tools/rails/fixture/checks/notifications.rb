puts "notifications=#{Notification.count} memberships=#{Membership.count}"
Notification.order(:id).each do |n|
  puts "  ##{n.id} user=#{n.user_id} #{n.kind.ljust(20)} #{n.payload.inspect}"
end
