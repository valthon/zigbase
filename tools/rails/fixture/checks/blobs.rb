ActiveStorage::Blob.order(:id).each do |b|
  path = "storage/#{b.key[0, 2]}/#{b.key[2, 2]}/#{b.key}"
  attachment = ActiveStorage::Attachment.find_by(blob_id: b.id)
  puts "##{b.id} key=#{b.key}"
  puts "     filename=#{b.filename} content_type=#{b.content_type} byte_size=#{b.byte_size} checksum=#{b.checksum}"
  puts "     attached_to=#{attachment&.record_type}##{attachment&.record_id} as #{attachment&.name}"
  puts "     path=#{path} exists=#{File.exist?(Rails.root.join(path))}"
end
