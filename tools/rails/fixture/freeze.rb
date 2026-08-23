# Build railsgen/frozen/ -- the clean, copy-ready fixture tree.
#
# Deterministic: no Time.now anywhere, files are walked in sorted order, and
# every emitted JSON has sorted keys, 2-space indent and a trailing newline.
require "json"
require "digest"
require "fileutils"

ROOT   = File.expand_path(File.dirname(__FILE__))
APP    = File.join(ROOT, "bookclub_api")
FROZEN = File.join(ROOT, "frozen")
TAKEN_AT = "2024-01-15T09:00:00Z"

def sort_keys(v)
  case v
  when Hash then v.to_h { |k, x| [ k.to_s, x ] }.then { |h| h.keys.sort.to_h { |k| [ k, sort_keys(h[k]) ] } }
  when Array then v.map { |x| sort_keys(x) }
  else v
  end
end

def write_json(path, payload)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, JSON.pretty_generate(sort_keys(payload), indent: "  ") + "\n")
end

def sha(path) = Digest::SHA256.file(path).hexdigest

# --- what belongs in app_source ---------------------------------------------
#
# The runnable Rails tree. Excluded, each for a stated reason:
#
#   tmp/restart.txt, log/development.log  runtime output, not source
#   storage/*.sqlite3, storage/fi/**      frozen separately under db/ and storage/
#   config/master.key                     a per-machine generated secret. This app
#   config/credentials.yml.enc            reads nothing from credentials -- the
#                                         secret_key_base and the Active Record
#                                         encryption keys are literals in
#                                         config/application.rb -- and freezing a
#                                         master.key would trip secret scanners.
#                                         Verified: the app migrates, seeds,
#                                         serves and exports without them.
#   .bundle/ vendor/bundle/ node_modules/ installed dependencies

# `vendor` matters when the maintainer has `bundle config path vendor/bundle`: without
# it, every installed gem is swept into app_source, and freeze.json already claims it is
# excluded.
EXCLUDE_DIRS  = %w[.bundle vendor node_modules .git].freeze
EXCLUDE_PATHS = %w[
  tmp/restart.txt
  log/development.log
  config/master.key
  config/credentials.yml.enc
].freeze

def app_source_files
  Dir.chdir(APP) do
    Dir.glob("**/*", File::FNM_DOTMATCH)
       .select { |p| File.file?(p) }
       .reject { |p| p.split("/").any? { |seg| EXCLUDE_DIRS.include?(seg) } }
       .reject { |p| EXCLUDE_PATHS.include?(p) }
       .reject { |p| p.start_with?("storage/") && !p.end_with?("/.keep") }
       .reject { |p| p.end_with?(".sqlite3") || p.include?(".sqlite3-") }
       .sort
  end
end

# --- refuse to freeze anything but a pristine database -----------------------
#
# freeze.rb copies whatever is on disk at the moment it runs. proof.sh mutates
# the canonical database in place while the transcript is executing (it does
# restore it afterwards), so a freeze that overlaps a transcript run -- or that
# lands mid-`db:migrate`, when the triggers and the view do not exist yet --
# silently captures garbage that still looks structurally valid. Assert the
# pristine seeded state up front instead of trusting timing.

require "sqlite3"

PROOF_PORT = 3131

EXPECTED_COUNTS = {
  "users" => 4, "clubs" => 3, "memberships" => 4, "posts" => 4, "comments" => 3,
  "flags" => 2, "events" => 3, "notifications" => 1,
  "active_storage_blobs" => 1, "active_storage_attachments" => 1,
  "active_storage_variant_records" => 0, "schema_migrations" => 10
}.freeze

def refuse(message)
  abort <<~MSG
    freeze.rb: refusing to freeze -- #{message}

    The frozen tree must be built from a pristine seeded database. Run:

        cd #{APP}
        bin/rails db:migrate:reset && bin/rails db:seed
        bin/rails runner <extractor> -- --out ../export --taken-at #{TAKEN_AT}
        ruby freeze.rb

    and do not run proof.sh concurrently -- it mutates this database in place
    while the transcript executes.
  MSG
end

def preflight!
  db = File.join(APP, "storage", "development.sqlite3")
  refuse("#{db} does not exist") unless File.exist?(db)

  # Uncheckpointed WAL means rows are committed but not in the file we copy.
  %w[-wal -shm].each do |suffix|
    refuse("#{db}#{suffix} exists; the database is not checkpointed") if File.exist?(db + suffix)
  end

  # A live server means a transcript may be running against this database.
  if system("curl -sS -o /dev/null --max-time 2 http://127.0.0.1:#{PROOF_PORT}/up", out: File::NULL, err: File::NULL)
    refuse("something is serving on port #{PROOF_PORT}; a transcript may be running")
  end

  conn = SQLite3::Database.new(db, readonly: true)

  triggers = conn.execute("SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger'").flatten.first
  views    = conn.execute("SELECT COUNT(*) FROM sqlite_master WHERE type = 'view'").flatten.first
  refuse("expected 3 triggers and 1 view, found #{triggers} and #{views} -- the database was rebuilt with `db:migrate` rather than `db:migrate:reset`") unless triggers == 3 && views == 1

  EXPECTED_COUNTS.each do |table, expected|
    actual = conn.execute("SELECT COUNT(*) FROM #{table}").flatten.first
    refuse("#{table} has #{actual} rows, expected #{expected} -- this is not the pristine seed") unless actual == expected
  end

  # Two mutations the transcript makes that a row count alone would not catch.
  if conn.execute("SELECT COUNT(*) FROM users WHERE email = 'eve@example.test'").flatten.first.positive?
    refuse("user eve@example.test exists -- this database carries transcript writes")
  end
  name = conn.execute("SELECT name FROM clubs WHERE id = 1").flatten.first
  refuse("clubs.id=1 is named #{name.inspect}, expected \"Morning Pages\" -- this database carries transcript writes") unless name == "Morning Pages"

  conn.close

  # Opening a WAL database -- even read-only -- creates `-wal`/`-shm`, and a
  # read-only handle cannot checkpoint them away on close. The check above
  # proved neither existed before this read, so anything here now is ours and
  # is safe to remove. Without this, running freeze.rb twice makes the second
  # run refuse on a sidecar the first run created.
  %w[-wal -shm].each { |suffix| FileUtils.rm_f(db + suffix) }
  # NB: this total covers the #{EXPECTED_COUNTS.length} asserted tables only. The extractor's
  # "rows=" figure is larger because it also counts ar_internal_metadata.
  puts "preflight: pristine seeded database (3 triggers, 1 view, " \
       "#{EXPECTED_COUNTS.values.sum} rows across #{EXPECTED_COUNTS.length} asserted tables)"
end

preflight!

# --- build -------------------------------------------------------------------

FileUtils.rm_rf(FROZEN)
FileUtils.mkdir_p(FROZEN)

# inventory/
FileUtils.mkdir_p(File.join(FROZEN, "inventory"))
inventory = Dir[File.join(ROOT, "export", "*.json")].sort
inventory.each { |f| FileUtils.cp(f, File.join(FROZEN, "inventory", File.basename(f))) }

# db/
FileUtils.mkdir_p(File.join(FROZEN, "db"))
FileUtils.cp(File.join(APP, "storage", "development.sqlite3"), File.join(FROZEN, "db", "development.sqlite3"))

# storage/
FileUtils.mkdir_p(File.join(FROZEN, "storage", "fi", "xt"))
FileUtils.cp(File.join(APP, "storage", "fi", "xt", "fixturecover0000000000000001"),
             File.join(FROZEN, "storage", "fi", "xt", "fixturecover0000000000000001"))

# http/
FileUtils.mkdir_p(File.join(FROZEN, "http"))
FileUtils.cp(File.join(ROOT, "http", "cases.json"), File.join(FROZEN, "http", "cases.json"))

# app_source/
sources = app_source_files
sources.each do |rel|
  dest = File.join(FROZEN, "app_source", rel)
  FileUtils.mkdir_p(File.dirname(dest))
  FileUtils.cp(File.join(APP, rel), dest)
end

# A stable identity for the source tree: sha256 over the sorted "<sha>  <path>"
# lines. The scratchpad is not a git checkout, so this stands in for a revision.
tree_lines = sources.map { |rel| "#{sha(File.join(APP, rel))}  #{rel}" }
app_source_tree_sha256 = Digest::SHA256.hexdigest(tree_lines.join("\n") + "\n")

versions = JSON.parse(File.read(File.join(FROZEN, "inventory", "versions.json")))
db_path  = File.join(FROZEN, "db", "development.sqlite3")

write_json(File.join(FROZEN, "freeze.json"), {
  "fixture" => "bookclub_api",
  "description" => "Synthetic Rails 8.1 API-only application frozen as a migration-test fixture.",
  "synthetic" => {
    "is_synthetic" => true,
    "statement" => "THIS IS NOT A PRODUCTION SNAPSHOT. Every byte of this fixture was fabricated for testing.",
    "no_real_personal_data" => "The four seeded users (Ada, Brian, Coral, Dane) are invented. The email addresses use the reserved .test TLD and the phone numbers are in the +1-555-01xx reserved range. No real person is represented.",
    "passwords_published_deliberately" => "The plaintext passwords and their bcrypt digests are both recorded in db/seeds.rb on purpose, so that the recorded HTTP cases can be replayed. They are cost-4 hashes over a fixed salt and guard nothing.",
    "keys_are_obvious_test_literals" => "config/application.rb hard-codes secret_key_base as sixty-four zeroes and the Active Record encryption key set as the literal strings fixture_primary_key_..., fixture_deterministic_key_... and fixture_key_derivation_salt_.... They are placeholders chosen to be unmistakable on sight, they protect nothing, and they must never be reused by a real application.",
    "why_hard_coded" => "Byte-reproducibility. Random salts, random IVs and random Active Storage keys would make the frozen database differ on every rebuild."
  },
  "taken_at" => TAKEN_AT,
  "revision" => {
    "kind" => "content_digest",
    "note" => "The fixture is generated, not checked out; there is no git revision. This digest is sha256 over the sorted '<sha256>  <path>' lines of app_source/.",
    "app_source_tree_sha256" => app_source_tree_sha256,
    "app_source_file_count" => sources.length
  },
  "ruby_version" => versions["ruby_version"],
  "ruby_description" => versions["ruby_description"],
  "rails_version" => versions["rails_version"],
  "adapter" => versions["adapter"],
  "database_version" => versions["database_version"],
  "api_only" => versions["api_only"],
  "schema_format" => versions["schema_format"],
  "gemfile_lock_sha256" => versions["gemfile_lock_sha256"],
  "database_sha256" => sha(db_path),
  "rebuild" => {
    "command" => "bin/rails db:migrate:reset && bin/rails db:seed",
    "note" => "Plain `bin/rails db:migrate` against a MISSING database loads db/schema.rb instead of running the migrations, and the :ruby schema format cannot express triggers or views -- the rebuilt database would silently have neither. db:migrate:reset runs the migrations for real; db:seed is required after it (it deletes the stray schema_migrations version '0' that db:migrate:reset leaves behind, pins ar_internal_metadata timestamps, and VACUUMs).",
    "reproducible" => true,
    "reproducibility_note" => "A from-scratch rebuild yields a byte-identical database file. Re-running db:seed on top of an existing database yields identical ROWS but a different file hash: SQLite's header change counter and schema cookie survive VACUUM."
  },
  "extractor" => {
    "path" => "tools/rails/export_source.rb",
    "invocation" => "bin/rails runner tools/rails/export_source.rb -- --out DIR --taken-at #{TAKEN_AT}",
    "outputs" => Dir[File.join(FROZEN, "inventory", "*.json")].map { |f| File.basename(f) }.sort,
    "deterministic" => true
  },
  "http_cases" => {
    "path" => "http/cases.json",
    "recorded_from" => "a live `bin/rails server` run driven by proof.sh; never transcribed",
    "replay_note" => "Replay in file order against a freshly seeded database. Tokens and runtime-assigned ids are {{placeholders}}; resolve them per the file's own `placeholders` map."
  },
  "excluded_from_app_source" => [
    { "path" => "config/master.key", "reason" => "generated per-machine secret; this app reads nothing from Rails credentials (secret_key_base and the Active Record encryption keys are literals in config/application.rb) and freezing it would trip secret scanners. Verified: migrate, seed, serve and export all work without it." },
    { "path" => "config/credentials.yml.enc", "reason" => "unused, and unreadable without config/master.key" },
    { "path" => "log/development.log", "reason" => "runtime output" },
    { "path" => "tmp/restart.txt", "reason" => "runtime output" },
    { "path" => "storage/development.sqlite3", "reason" => "frozen separately as db/development.sqlite3" },
    { "path" => "storage/test.sqlite3", "reason" => "side effect of db:migrate:reset; not part of the fixture" },
    { "path" => "storage/fi/xt/fixturecover0000000000000001", "reason" => "frozen separately under storage/" },
    { "path" => ".bundle/, vendor/bundle/, node_modules/", "reason" => "installed dependencies" }
  ]
})

# --- manifest ----------------------------------------------------------------

files = Dir.chdir(FROZEN) do
  Dir.glob("**/*", File::FNM_DOTMATCH).select { |p| File.file?(p) }.reject { |p| p == "fixture-manifest.json" }.sort
end

entries = files.map do |rel|
  full = File.join(FROZEN, rel)
  { "path" => rel, "bytes" => File.size(full), "sha256" => sha(full) }
end

write_json(File.join(FROZEN, "fixture-manifest.json"), {
  "fixture" => "bookclub_api",
  "taken_at" => TAKEN_AT,
  "count" => entries.length,
  "total_bytes" => entries.sum { |e| e["bytes"] },
  "note" => "sha256 and byte size for every file in frozen/, sorted by path. fixture-manifest.json itself is excluded (it cannot contain its own digest).",
  "files" => entries
})

puts "frozen/: #{entries.length} files, #{entries.sum { |e| e['bytes'] }} bytes"
puts "  inventory=#{inventory.length} app_source=#{sources.length}"
puts "  app_source_tree_sha256=#{app_source_tree_sha256}"
puts "  database_sha256=#{sha(db_path)}"
