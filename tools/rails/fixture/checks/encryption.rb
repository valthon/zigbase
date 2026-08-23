ActiveRecord::Base.connection.select_all("SELECT id, email, phone FROM users ORDER BY id").each do |r|
  puts "SQL   id=#{r['id']} #{r['email'].ljust(20)} phone=#{r['phone']}"
end
puts ""
User.order(:id).each do |u|
  puts "MODEL id=#{u.id} #{u.email.ljust(20)} phone=#{u.phone.inspect}"
end
