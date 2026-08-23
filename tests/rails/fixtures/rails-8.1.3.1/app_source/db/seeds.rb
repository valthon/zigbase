# =============================================================================
# bookclub_api fixture seed
# =============================================================================
# Every id, timestamp, password digest and Active Storage key below is a fixed
# literal. Re-running this file wipes and rebuilds the same rows, so the
# resulting SQLite database and the extractor output are byte-reproducible.
#
# All data is synthetic. The passwords and digests are published on purpose so
# that tests can log in; they guard nothing.
# =============================================================================

def t(year, month, day, hour = 0, minute = 0, second = 0)
  Time.utc(year, month, day, hour, minute, second)
end

# --- wipe (makes the seed re-runnable, not just runnable-from-empty) ---------

ActiveRecord::Base.connection.disable_referential_integrity do
  %w[
    active_storage_variant_records active_storage_attachments active_storage_blobs
    flags comments posts events memberships notifications clubs users
  ].each do |table|
    ActiveRecord::Base.connection.execute("DELETE FROM #{table}")
    ActiveRecord::Base.connection.execute("DELETE FROM sqlite_sequence WHERE name = '#{table}'")
  end
end

# Drop previously-uploaded blob files (2-char shard dirs under storage/), while
# leaving the SQLite database file itself alone.
Dir.children(Rails.root.join("storage")).each do |entry|
  path = Rails.root.join("storage", entry)
  FileUtils.rm_rf(path) if File.directory?(path) && entry.match?(/\A[0-9a-z]{2}\z/)
end

# --- users ------------------------------------------------------------------
#
#   id | email                | password         | role
#   ---+----------------------+------------------+-----------
#    1 | ada@example.test     | ada-password-1   | admin
#    2 | brian@example.test   | brian-password-2 | member
#    3 | coral@example.test   | coral-password-3 | moderator
#    4 | dane@example.test    | dane-password-4  | member
#
# password_digest values are hard-coded bcrypt (cost 4, fixed salt) literals:
# bcrypt embeds a random salt by default, so hashing at seed time would produce
# a different digest on every run.

USERS = [
  { id: 1, email: "ada@example.test",   display_name: "Ada Lovelace",   phone: "+1-555-0100", role: "admin",
    password_digest: "$2a$04$fixturesaltfixtures00uU9RJtmTs6Ml/RaXilZAdMIc8h2dgkl2" },
  { id: 2, email: "brian@example.test", display_name: "Brian Kernighan", phone: "+1-555-0101", role: "member",
    password_digest: "$2a$04$fixturesaltfixtures00uHwpqdZtciRktP2/o29MZB1VmZY6R8qS" },
  { id: 3, email: "coral@example.test", display_name: "Coral Reeves",   phone: "+1-555-0102", role: "moderator",
    password_digest: "$2a$04$fixturesaltfixtures00uxE/.ZfVDxQ5fafaZ9tMFnMj871GVJ1y" },
  { id: 4, email: "dane@example.test",  display_name: "Dane Ortiz",     phone: "+1-555-0103", role: "member",
    password_digest: "$2a$04$fixturesaltfixtures00uDa51YdFpme/J21kiDAzSdudyx3k4.HW" }
].freeze

USERS.each_with_index do |attrs, i|
  User.create!(attrs.merge(created_at: t(2024, 1, 15, 9, i), updated_at: t(2024, 1, 15, 9, i)))
end

# --- clubs ------------------------------------------------------------------
#
# Club 3 is ARCHIVED: `default_scope { where(archived_at: nil) }` hides it from
# every unqualified model read. Only raw SQL or `Club.unscoped` sees it.

Club.create!(id: 1, name: "Morning Pages",   slug: "morning-pages",   owner_id: 1,
             visibility: "public_club",  created_at: t(2024, 1, 15, 10, 0), updated_at: t(2024, 1, 15, 10, 0))
Club.create!(id: 2, name: "Night Owls",      slug: "night-owls",      owner_id: 3,
             visibility: "private_club", created_at: t(2024, 1, 15, 10, 1), updated_at: t(2024, 1, 15, 10, 1))
Club.create!(id: 3, name: "Retired Readers", slug: "retired-readers", owner_id: 1,
             visibility: "public_club",  archived_at: t(2024, 2, 1, 0, 0),
             created_at: t(2024, 1, 15, 10, 2), updated_at: t(2024, 2, 1, 0, 0))

# --- memberships ------------------------------------------------------------

Membership.create!(id: 1, user_id: 2, club_id: 1, role: "reader",
                   joined_at: t(2024, 1, 16, 8, 0), created_at: t(2024, 1, 16, 8, 0), updated_at: t(2024, 1, 16, 8, 0))
Membership.create!(id: 2, user_id: 2, club_id: 2, role: "curator",
                   joined_at: t(2024, 1, 16, 8, 5), created_at: t(2024, 1, 16, 8, 5), updated_at: t(2024, 1, 16, 8, 5))
Membership.create!(id: 3, user_id: 3, club_id: 1, role: "reader",
                   joined_at: t(2024, 1, 16, 8, 10), created_at: t(2024, 1, 16, 8, 10), updated_at: t(2024, 1, 16, 8, 10))
# Membership in the ARCHIVED club. `save!` would FAIL here with
# "Club must exist": `belongs_to :club` resolves the parent through Club's
# default_scope, which cannot see club 3. Validation is skipped so the row
# exists -- exactly the state a real app ends up in after archiving a club.
Membership.new(id: 4, user_id: 4, club_id: 3, role: "reader",
               joined_at: t(2024, 1, 16, 8, 15), created_at: t(2024, 1, 16, 8, 15),
               updated_at: t(2024, 1, 16, 8, 15)).save!(validate: false)

# --- posts ------------------------------------------------------------------
#
# Inserting these fires the `posts_count_after_insert` SQLite trigger, so
# clubs.posts_count is maintained by the DATABASE, never assigned here.

Post.create!(id: 1, club_id: 1, author_id: 1, title: "On Marginalia",
             body: "Notes in the margin are the only honest book review.",
             status: "published", published_at: t(2024, 1, 17, 12, 0),
             created_at: t(2024, 1, 17, 11, 0), updated_at: t(2024, 1, 17, 12, 0))
Post.create!(id: 2, club_id: 1, author_id: 2, title: "Drafting In Public",
             body: "A half-finished thought about unfinished books.",
             status: "draft",
             created_at: t(2024, 1, 18, 9, 30), updated_at: t(2024, 1, 18, 9, 30))
Post.create!(id: 3, club_id: 2, author_id: 3, title: "Private Notes",
             body: "Members only: the reading order for February.",
             status: "published", published_at: t(2024, 1, 19, 20, 0),
             created_at: t(2024, 1, 19, 19, 0), updated_at: t(2024, 1, 19, 20, 0))
# Same story as membership 4: the post belongs to the archived club, so the
# `belongs_to :club` presence check cannot see its parent.
Post.new(id: 4, club_id: 3, author_id: 1, title: "Farewell Thread",
         body: "This club is archived; the post is not.",
         status: "archived",
         created_at: t(2024, 1, 20, 7, 0), updated_at: t(2024, 2, 1, 0, 0)).save!(validate: false)

# --- comments ---------------------------------------------------------------

Comment.create!(id: 1, post_id: 1, author_id: 2, body: "Marginalia is why I never lend books.",
                created_at: t(2024, 1, 17, 13, 0), updated_at: t(2024, 1, 17, 13, 0))
Comment.create!(id: 2, post_id: 1, author_id: 3, body: "Counterpoint: pencil only.",
                created_at: t(2024, 1, 17, 13, 5), updated_at: t(2024, 1, 17, 13, 5))
Comment.create!(id: 3, post_id: 3, author_id: 2, body: "Noted, thanks.",
                created_at: t(2024, 1, 19, 21, 0), updated_at: t(2024, 1, 19, 21, 0))

# --- flags (polymorphic) ----------------------------------------------------
#
# One flag points at a Post row, the other at a Comment row, through the same
# two columns.

Flag.create!(id: 1, flaggable_type: "Post",    flaggable_id: 1, reporter_id: 2, reason: "off_topic",
             created_at: t(2024, 1, 18, 10, 0), updated_at: t(2024, 1, 18, 10, 0))
Flag.create!(id: 2, flaggable_type: "Comment", flaggable_id: 2, reporter_id: 1, reason: "tone",
             created_at: t(2024, 1, 18, 10, 5), updated_at: t(2024, 1, 18, 10, 5))

# --- events (single table inheritance) --------------------------------------

MeetingEvent.create!(id: 1, club_id: 1, title: "January Meetup", location: "Library, Room 2",
                     starts_at: t(2024, 1, 25, 18, 0),
                     created_at: t(2024, 1, 15, 11, 0), updated_at: t(2024, 1, 15, 11, 0))
ReadingEvent.create!(id: 2, club_id: 1, title: "Chapters 1-6", pages_target: 120,
                     starts_at: t(2024, 1, 22, 7, 0),
                     created_at: t(2024, 1, 15, 11, 5), updated_at: t(2024, 1, 15, 11, 5))
MeetingEvent.create!(id: 3, club_id: 2, title: "Owl Hours", location: "Video call",
                     starts_at: t(2024, 1, 26, 22, 0),
                     created_at: t(2024, 1, 15, 11, 10), updated_at: t(2024, 1, 15, 11, 10))

# --- notifications ----------------------------------------------------------
#
# Seeded rows only. The interesting ones are written at runtime by
# MembershipsController's transaction and by PostPublishedNotificationJob.

Notification.create!(id: 1, user_id: 1, kind: "seed.welcome",
                     payload: { "message" => "Fixture seeded." }, created_at: t(2024, 1, 15, 9, 30))

# --- active storage ---------------------------------------------------------
#
# Blob keys are random by default (`ActiveStorage::Blob.generate_unique_secure_token`),
# which would move the on-disk path on every seed. They are pinned here, so the
# file always lands at storage/fi/xt/fixturecover0000000000000001.

COVER_PNG = [
  "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4",
  "890000000d4944415478da63f8cfc0f01f0005fb02fea6b7cd6f0000000049454e44ae426082"
].join.freeze

cover_bytes = [ COVER_PNG ].pack("H*")

blob = ActiveStorage::Blob.new(
  id: 1,
  key: "fixturecover0000000000000001",
  filename: "morning-pages-cover.png",
  content_type: "image/png",
  metadata: { "identified" => true, "analyzed" => true },
  service_name: "local",
  byte_size: cover_bytes.bytesize,
  checksum: OpenSSL::Digest::MD5.base64digest(cover_bytes),
  created_at: t(2024, 1, 17, 11, 30)
)
blob.save!
blob.service.upload(blob.key, StringIO.new(cover_bytes), checksum: blob.checksum)

ActiveStorage::Attachment.create!(
  id: 1,
  name: "cover",
  record_type: "Post",
  record_id: 1,
  blob_id: blob.id,
  created_at: t(2024, 1, 17, 11, 30)
)

# Attaching touches the attached record, which would stamp posts.updated_at
# with the wall clock. Put it back to its fixed value.
Post.unscoped.where(id: 1).update_all(updated_at: t(2024, 1, 17, 12, 0))

# --- normalize Rails' own bookkeeping ---------------------------------------
#
# `ar_internal_metadata` is written by the migration tasks with wall-clock
# timestamps. Pinning them removes the last per-run difference between two
# freshly built copies of this fixture.

ActiveRecord::Base.connection.execute(
  "UPDATE ar_internal_metadata SET created_at = '2024-01-15 09:00:00', updated_at = '2024-01-15 09:00:00'"
)

# `db:migrate:reset` expands to
#   ["db:drop", "db:create", "db:schema:dump", "db:migrate"]
# and that third step dumps the schema of a database that is still EMPTY, so it
# rewrites db/schema.rb as `define(version: 0)`. The following db:migrate then
# loads that empty schema -- recording version "0" in schema_migrations -- before
# running the real migrations (and re-dumping the correct schema.rb afterwards).
# The "0" row corresponds to no migration file; drop it so schema_migrations
# matches db/migrate exactly.
ActiveRecord::Base.connection.execute("DELETE FROM schema_migrations WHERE version = '0'")

# VACUUM rewrites the file in canonical page order. Without it two freshly
# seeded databases hold identical rows but differ byte-for-byte, because
# SQLite's free-page layout depends on the order pages happened to be freed.

ActiveRecord::Base.connection.execute("VACUUM")

# --- summary ----------------------------------------------------------------

puts "seeded:"
puts "  users=#{User.count} clubs_visible=#{Club.count} clubs_total=#{Club.unscoped.count}"
puts "  memberships=#{Membership.count} posts=#{Post.count} comments=#{Comment.count}"
puts "  flags=#{Flag.count} events=#{Event.count} notifications=#{Notification.count}"
puts "  blobs=#{ActiveStorage::Blob.count} attachments=#{ActiveStorage::Attachment.count}"
puts "  clubs.posts_count (trigger-maintained) = " +
     Club.unscoped.order(:id).pluck(:id, :posts_count).map { |id, n| "##{id}=#{n}" }.join(" ")
