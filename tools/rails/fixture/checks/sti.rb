puts "Event.all (STI, mixed classes):"
Event.order(:id).each { |e| puts "  ##{e.id} #{e.class.name.ljust(13)} type=#{e.type} club=#{e.club_id} #{e.title}" }
puts "MeetingEvent.all -> #{MeetingEvent.order(:id).pluck(:id).inspect}  sql: #{MeetingEvent.all.to_sql}"
puts "ReadingEvent.all -> #{ReadingEvent.order(:id).pluck(:id).inspect}"
puts ""
puts "Flag.all (polymorphic targets):"
Flag.order(:id).each { |f| puts "  ##{f.id} #{f.flaggable_type}##{f.flaggable_id} -> #{f.flaggable.class.name} reporter=#{f.reporter_id} reason=#{f.reason}" }
