# Reads one recorded HTTP case (metadata + raw response body) written by
# proof.sh and normalizes it into the frozen `http/cases.json` shape.
#
# Called twice: once per case as it executes (to persist the raw record), and
# once at the end with --assemble (to normalize and emit the final file). The
# split matters: a token is only learned from the response of the login case
# that issues it, so normalization cannot happen until every case has run.
require "json"
require "digest"

module RecordCase
  module_function

  def sort_keys(value)
    case value
    when Hash
      stringified = value.to_h { |k, v| [ k.to_s, v ] }
      stringified.keys.sort.to_h { |k| [ k, sort_keys(stringified[k]) ] }
    when Array then value.map { |v| sort_keys(v) }
    else value
    end
  end

  # Placeholders present in the request form, e.g. "{{token:brian}}".
  def placeholders_in(*values)
    values.compact.flat_map { |v| v.to_s.scan(/\{\{([^}]+)\}\}/) }.flatten.uniq.sort
  end

  # --- normalization -------------------------------------------------------

  # Fractional seconds and numeric offsets included: Rails emits both in places, and a
  # stamp the pattern does not match is neither normalized NOR flagged as a leak --
  # it is simply frozen verbatim into the fixture.
  ISO8601 = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})\z/

  # Every seeded timestamp is in 2024; anything else was stamped by the wall
  # clock during this run and must not be frozen into an expectation.
  def normalize_scalar(value, tokens)
    return value unless value.is_a?(String)
    return "{{#{tokens[value]}}}" if tokens.key?(value)
    return "{{timestamp}}" if value.match?(ISO8601) && !value.start_with?("2024-")
    value
  end

  def normalize_tree(node, tokens)
    case node
    when Hash  then node.to_h { |k, v| [ k, normalize_tree(v, tokens) ] }
    when Array then node.map { |v| normalize_tree(v, tokens) }
    else normalize_scalar(node, tokens)
    end
  end

  # `volatile` is a list of "dot.path=placeholder" pairs declared at the call
  # site, for runtime-assigned ids that are not otherwise detectable.
  def apply_volatile(body, volatile)
    return body if body.nil? || volatile.nil? || volatile.empty?

    volatile.each do |spec|
      path, placeholder = spec.split("=", 2)
      next if path.nil? || placeholder.nil?

      keys = path.split(".")
      leaf = keys.pop
      target = keys.reduce(body) { |acc, k| acc.is_a?(Hash) ? acc[k] : nil }
      target[leaf] = "{{#{placeholder}}}" if target.is_a?(Hash) && target.key?(leaf)
    end

    body
  end

  # --- per-case capture ----------------------------------------------------

  # `meta_path` holds NUL-separated key/value pairs. Shell-quoting a label that
  # contains quotes, backticks and arrows into JSON is a bug farm; let Ruby
  # build the JSON instead.
  def read_meta(path)
    parts = File.read(path).split("\0")
    meta = {}
    parts.each_slice(2) { |k, v| meta[k] = v.to_s unless k.nil? }
    meta["n"] = meta["n"].to_i
    meta["observed_status"] = meta["observed_status"].to_i
    meta["stateful"] = meta["stateful"] == "1"
    meta["chain"] = nil if meta["chain"].to_s.empty?
    meta["volatile"] = meta["volatile"].to_s.split("|").reject(&:empty?)
    meta
  end

  def capture(meta_path, args_path, headers_path, body_path, out_path)
    meta = read_meta(meta_path)
    args = File.read(args_path).split("\0").reject(&:empty?)

    headers = {}
    request_body = nil
    multipart = nil

    i = 0
    while i < args.length
      case args[i]
      when "-H"
        name, value = args[i + 1].to_s.split(":", 2)
        headers[name.strip] = value.to_s.strip
        i += 2
      when "-d"
        raw = args[i + 1].to_s
        request_body = (JSON.parse(raw) rescue raw)
        i += 2
      when "-F"
        field, spec = args[i + 1].to_s.split("=", 2)
        file = spec.to_s.sub(/\A@/, "").split(";").first
        multipart = {
          "field" => field,
          "file" => File.basename(file.to_s),
          "content_type" => (spec.to_s[/;type=(.*)\z/, 1]),
          "bytes" => (File.size(file) rescue nil),
          "sha256" => (Digest::SHA256.file(file).hexdigest rescue nil)
        }
        i += 2
      else
        i += 1
      end
    end

    response_headers = File.read(headers_path).split(/\r?\n/)
    content_type = response_headers.grep(/\Acontent-type:/i).first.to_s.split(":", 2)[1].to_s.strip
    content_type = nil if content_type.empty?

    raw = File.binread(body_path)
    body_kind, body, body_bytes, body_sha =
      if content_type.to_s.include?("json")
        parsed = (JSON.parse(raw) rescue nil)
        if parsed.is_a?(Hash) && parsed.key?("traces")
          # Rails' development-mode error page. The traces blob is multi-kilobyte
          # and full of gem paths and object ids; only the shape is an expectation.
          [ "rails_routing_error", nil, raw.bytesize, Digest::SHA256.hexdigest(raw) ]
        else
          [ "json", parsed, raw.bytesize, Digest::SHA256.hexdigest(raw) ]
        end
      else
        [ "binary", nil, raw.bytesize, Digest::SHA256.hexdigest(raw) ]
      end

    record = meta.merge(
      "headers" => headers,
      "body" => request_body,
      "multipart" => multipart,
      "observed_status" => meta["observed_status"],
      "observed_content_type" => content_type,
      "body_kind" => body_kind,
      "observed_body" => body,
      "observed_body_bytes" => body_bytes,
      "observed_body_sha256" => body_sha
    )

    File.write(out_path, JSON.pretty_generate(record, indent: "  ") + "\n")
  end

  # --- invariants ----------------------------------------------------------
  #
  # A regeneration that can silently emit a WRONG cases.json is worse than one
  # that fails, because the wrong file is indistinguishable from the right one.
  # These assertions run BEFORE anything is written; any failure aborts and
  # leaves the previous file untouched.

  EXPECTED_CASE_COUNT = 42

  # The seed creates 4 users and 4 posts. Case 1 signs one user up and case 25
  # creates one post, so by the time the stats cases run the totals are fixed.
  SEEDED_USERS = 4
  SEEDED_POSTS = 4
  USERS_CREATED_BY_CASES = 1   # case 1
  POSTS_CREATED_BY_CASES = 1   # case 25

  # Counts reported by GET /api/v1/internal/stats. `clubs_visible` vs
  # `clubs_total` is the default_scope trap and must not drift either.
  STATS_EXPECTED = {
    "users_total"   => SEEDED_USERS + USERS_CREATED_BY_CASES,
    "posts_total"   => SEEDED_POSTS + POSTS_CREATED_BY_CASES,
    "clubs_visible" => 2,
    "clubs_total"   => 3
  }.freeze

  # Listed independently of STATS_EXPECTED on purpose: deriving these from it
  # means relaxing one pinned value silently switches off the monotonicity
  # check for that key too.
  MONOTONIC_KEYS = %w[users_total posts_total clubs_visible clubs_total].freeze

  ISO8601_ANY = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})\z/

  def collect_strings(node, out = [])
    case node
    when Hash  then node.each_value { |v| collect_strings(v, out) }
    when Array then node.each { |v| collect_strings(v, out) }
    when String then out << node
    end
    out
  end

  def validate!(cases, tokens)
    errors = []

    if cases.length != EXPECTED_CASE_COUNT
      errors << "expected #{EXPECTED_CASE_COUNT} cases, recorded #{cases.length}"
    end

    numbers = cases.map { |c| c["n"] }
    unless numbers == (1..cases.length).to_a
      errors << "case numbers are not a dense ordered sequence: #{numbers.inspect}"
    end

    # (a) internal consistency of the derived counts
    stats_cases = cases.select { |c| c.dig("expect", "body", "data").is_a?(Hash) && c.dig("expect", "body", "data").key?("users_total") }
    errors << "no stats case recorded; the count invariants cannot be checked" if stats_cases.empty?

    stats_cases.each do |c|
      data = c.dig("expect", "body", "data")
      STATS_EXPECTED.each do |key, expected|
        actual = data[key]
        next if actual == expected
        errors << "case #{c['n']} (#{c['label']}): #{key} is #{actual.inspect}, expected #{expected} " \
                  "(#{key.start_with?('users') ? "#{SEEDED_USERS} seeded + #{USERS_CREATED_BY_CASES} from case 1" : key.start_with?('posts') ? "#{SEEDED_POSTS} seeded + #{POSTS_CREATED_BY_CASES} from case 25" : 'fixed by the seed'})"
      end
    end

    # (b) monotonicity: a count may never decrease as the transcript proceeds
    seen = {}
    cases.each do |c|
      data = c.dig("expect", "body", "data")
      next unless data.is_a?(Hash)
      MONOTONIC_KEYS.each do |key|
        value = data[key]
        next unless value.is_a?(Integer)
        previous = seen[key]
        if previous && value < previous[:value]
          errors << "case #{c['n']} reports #{key}=#{value}, lower than case #{previous[:n]}'s #{previous[:value]}; " \
                    "counts must never decrease across the transcript"
        end
        seen[key] = { value: value, n: c["n"] } if previous.nil? || value >= previous[:value]
      end
    end

    # (c) no secret and no wall-clock value may survive parameterization
    token_values = tokens.keys
    cases.each do |c|
      # Scan the WHOLE case, not a hand-listed set of fields: `path` and `multipart`
      # were never checked, so a leak there would have been frozen into the fixture in
      # silence. Enumerating what to inspect is how you miss the one you forgot.
      strings = collect_strings(c)
      strings.each do |str|
        errors << "case #{c['n']} leaks a raw bearer token" if token_values.any? { |t| str.include?(t) }
        if str.match?(ISO8601_ANY) && !str.start_with?("2024-")
          errors << "case #{c['n']} leaks a wall-clock timestamp #{str.inspect}; it should have been normalized to {{timestamp}}"
        end
      end
    end

    return if errors.empty?

    warn "record_case.rb --assemble: REFUSING to write cases.json"
    warn ""
    errors.uniq.each { |e| warn "  - #{e}" }
    warn ""
    warn "  The recorded run is inconsistent, so the file it would produce would be"
    warn "  wrong while looking correct. Nothing was written; the previous"
    warn "  cases.json is untouched. Re-run proof.sh against a freshly seeded"
    warn "  database with no other server on the port."
    exit 1
  end

  # --- final assembly ------------------------------------------------------

  def assemble(dir, tokens_path, out_path)
    # value -> placeholder name, e.g. "1.b44d…" -> "token:ada"
    tokens = JSON.parse(File.read(tokens_path))

    cases = Dir[File.join(dir, "*.json")].sort.map do |path|
      r = JSON.parse(File.read(path))

      body = r["observed_body"]
      body = normalize_tree(body, tokens) unless body.nil?
      body = apply_volatile(body, r["volatile"])

      expect = { "status" => r["observed_status"], "content_type" => r["observed_content_type"] }
      case r["body_kind"]
      when "json"
        expect["body"] = body
        expect["body_shape"] = "json"
      when "rails_routing_error"
        # Deliberately no body: Rails' dev-mode traces blob is not a stable
        # expectation and carries absolute gem paths.
        expect["body"] = nil
        expect["body_shape"] = "rails_routing_error"
      when "binary"
        expect["body"] = nil
        expect["body_shape"] = "binary"
        expect["body_bytes"] = r["observed_body_bytes"]
        expect["body_sha256"] = r["observed_body_sha256"]
      end

      request_body = r["body"].nil? ? nil : normalize_tree(r["body"], tokens)

      {
        "n" => r["n"],
        "label" => r["label"],
        "method" => r["method"],
        "path" => r["path"],
        "actor" => r["actor"],
        "headers" => r["headers"],
        "body" => request_body,
        "multipart" => r["multipart"],
        "expect" => expect,
        "depends_on" => placeholders_in(r["path"], *r["headers"].values, r["body"].to_json),
        # Declared at the call site: this case's EXPECTATION depends on a
        # mutation made by an earlier case in this file.
        "stateful" => !!r["stateful"],
        # Computed: this case itself changes server state.
        "mutates" => %w[POST PATCH PUT DELETE].include?(r["method"]) && (200..299).cover?(r["observed_status"]),
        "chain" => r["chain"],
        "source" => "observed"
      }
    end

    payload = {
      "source" => "observed",
      "count" => cases.length,
      "notes" => [
        "Recorded from a live `bin/rails server` run by proof.sh; never transcribed.",
        "Cases are in execution order and MUST be replayed in order against a freshly seeded database.",
        "Bearer tokens and runtime-assigned ids appear only as {{placeholders}}; resolve them per `placeholders`.",
        "`stateful: true` marks a case whose EXPECTATION depends on a mutation made by an earlier case; `mutates: true` marks a case that itself changes state.",
        "`chain` groups a sequence that must not be split or reordered."
      ],
      "placeholders" => {
        "{{token:ada}}"   => { "kind" => "bearer_token", "resolve" => "POST /api/v1/sessions {email: ada@example.test, password: ada-password-1} -> data.token" },
        "{{token:brian}}" => { "kind" => "bearer_token", "resolve" => "POST /api/v1/sessions {email: brian@example.test, password: brian-password-2} -> data.token" },
        "{{token:coral}}" => { "kind" => "bearer_token", "resolve" => "POST /api/v1/sessions {email: coral@example.test, password: coral-password-3} -> data.token" },
        "{{token:dane}}"  => { "kind" => "bearer_token", "resolve" => "POST /api/v1/sessions {email: dane@example.test, password: dane-password-4} -> data.token" },
        "{{token:eve}}"   => { "kind" => "bearer_token", "resolve" => "POST /api/v1/sessions {email: eve@example.test, password: eve-password-5} -> data.token; eve is created by case 1, not by the seed" },
        "{{user:eve}}"    => { "kind" => "record_id", "resolve" => "data.id from case 1 (POST /api/v1/users)" },
        "{{post:new}}"    => { "kind" => "record_id", "resolve" => "data.id from case 25 (POST /api/v1/clubs/morning-pages/posts)" },
        "{{membership:new}}" => { "kind" => "record_id", "resolve" => "data.id from case 22 (POST /api/v1/clubs/night-owls/memberships)" },
        "{{blob:new_id}}"      => { "kind" => "record_id",  "resolve" => "data.blob_id from case 32" },
        "{{blob:new_key}}"     => { "kind" => "record_key", "resolve" => "data.key from case 32; Active Storage assigns it randomly" },
        "{{blob:private_id}}"  => { "kind" => "record_id",  "resolve" => "data.blob_id from case 34" },
        "{{blob:private_key}}" => { "kind" => "record_key", "resolve" => "data.key from case 34; Active Storage assigns it randomly" },
        "{{timestamp}}"   => { "kind" => "volatile", "resolve" => "a wall-clock timestamp written during the run; assert presence and ISO8601 shape, never equality" }
      },
      "cases" => cases
    }

    validate!(cases, tokens)

    File.write(out_path, JSON.pretty_generate(sort_keys(payload), indent: "  ") + "\n")
    puts "cases.json: validated, #{cases.length} cases, #{cases.count { |c| c['stateful'] }} stateful, " \
         "#{cases.count { |c| !c['chain'].nil? }} chained, " \
         "#{cases.count { |c| c['expect']['body_shape'] == 'binary' }} binary, " \
         "#{cases.count { |c| c['expect']['body_shape'] == 'rails_routing_error' }} routing-error"
  end
end

if ARGV.first == "--assemble"
  RecordCase.assemble(ARGV[1], ARGV[2], ARGV[3])
else
  RecordCase.capture(*ARGV)
end
