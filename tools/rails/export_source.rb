# =============================================================================
# tools_rails_export_source.rb
# =============================================================================
# Dump OBSERVED metadata from a booted Rails application to a directory of JSON
# files. Nothing here is inferred from source text: every fact is read back out
# of the live application object graph (routes set, model reflections, the
# database connection, Active Storage/Active Job registries).
#
# Usage:
#
#   bin/rails runner /path/to/tools_rails_export_source.rb -- \
#     --out ./export --taken-at 2024-01-15T09:00:00Z
#
# `--taken-at` is REQUIRED: the timestamp is an input, never Time.now, so that
# two runs of this script over the same application produce byte-identical
# files.
#
# Output is written with sorted keys and 2-space indentation. Every emitted
# record carries "source": "observed".
# =============================================================================

require "fileutils"
require "time"  # Time.iso8601 for the --taken-at gate
require "json"
require "digest"

# -----------------------------------------------------------------------------
# argv
# -----------------------------------------------------------------------------

module RailsExportSource
  # 1.3.0: inspect PostgreSQL triggers/views, recover configured OmniAuth provider
  # names from the Rails middleware stack, and distinguish gem-owned jobs by source.
  # 1.2.0: record PostgreSQL array columns explicitly for safe row extraction.
  # 1.1.1: ignore Rails-generated HABTM join classes and retain Ruby 2.7 syntax.
  # 1.1.0: wide model walk (ActiveRecord::Base, not ApplicationRecord), Action
  # Text inventory, foreign-key inspection failures reported as unknown, storage
  # locality made explicit.
  VERSION = "1.3.0"
  OBSERVED = "observed".freeze

  # Credential-ish keys whose VALUES are replaced with "[REDACTED]".
  SECRET_KEY_PATTERN = /
    (?: access_key | secret | password | token | credential | private_key |
        signature | salt | api_key | passphrase | connection_string )
  /xi

  module_function

  def parse_argv(argv)
    opts = { out: nil, taken_at: nil }
    rest = argv.dup
    rest.shift while rest.first == "--"

    until rest.empty?
      arg = rest.shift
      case arg
      when "--out"      then opts[:out] = rest.shift
      when "--taken-at" then opts[:taken_at] = rest.shift
      when /\A--out=(.*)\z/       then opts[:out] = Regexp.last_match(1)
      when /\A--taken-at=(.*)\z/  then opts[:taken_at] = Regexp.last_match(1)
      when "--"         then next
      else
        abort "tools_rails_export_source: unknown argument #{arg.inspect}"
      end
    end

    abort "tools_rails_export_source: --out DIR is required" if opts[:out].to_s.empty?
    abort "tools_rails_export_source: --taken-at ISO8601 is required" if opts[:taken_at].to_s.empty?
    # The value is provenance: it is written verbatim into versions.json and never
    # recomputed, so a typo would be frozen into the record with nothing to catch it.
    # Shape AND range: a regex alone accepts `2026-13-45T25:61:61Z`, and calling that
    # ISO8601 validation while letting it through is worse than not checking.
    begin
      raise ArgumentError unless opts[:taken_at].end_with?("Z")

      Time.iso8601(opts[:taken_at])
    rescue ArgumentError
      abort "tools_rails_export_source: --taken-at must be ISO8601 UTC " \
            "(YYYY-MM-DDTHH:MM:SSZ), got #{opts[:taken_at].inspect}"
    end
    opts
  end

  # JSON-safety: validator options and route constraints hold Regexps, Procs,
  # Classes and Symbols. Anything that cannot round-trip through JSON is
  # rendered as a stable, inspectable string instead of being dropped.
  def jsonify(value)
    case value
    when nil, true, false, Integer, Float then value
    when String then scrub_path(value)
    when Symbol then value.to_s
    when Regexp then { "type" => "regexp", "source" => value.source, "options" => value.options }
    when Range  then { "type" => "range", "begin" => jsonify(value.begin), "end" => jsonify(value.end), "exclude_end" => value.exclude_end? }
    when Array  then value.map { |v| jsonify(v) }
    when Hash   then value.to_h { |k, v| [ k.to_s, redact(k, v) ] }
    when Proc   then { "type" => "proc", "arity" => value.arity }
    when Class, Module then { "type" => "class", "name" => value.name }
    when Time then value.utc.iso8601
    else
      if value.respond_to?(:to_hash) then jsonify(value.to_hash)
      else { "type" => "opaque", "class" => value.class.name }
      end
    end
  end

  # Absolute filesystem paths differ per machine and would break byte
  # reproducibility, so the application root is replaced by a placeholder.
  def scrub_path(value)
    root = Rails.root.to_s
    value.include?(root) ? value.gsub(root, "<rails_root>") : value
  end

  def redact(key, value)
    return "[REDACTED]" if key.to_s.match?(SECRET_KEY_PATTERN) && !value.nil? && value != false
    jsonify(value)
  end

  # Recursive key sort so `JSON.pretty_generate` emits a canonical byte stream.
  # Values are fetched by key rather than with `||`, so `false` survives.
  def sort_keys(value)
    case value
    when Hash
      stringified = value.to_h { |k, v| [ k.to_s, v ] }
      stringified.keys.sort.to_h { |k| [ k, sort_keys(stringified[k]) ] }
    when Array then value.map { |v| sort_keys(v) }
    else value
    end
  end

  def write_json(dir, name, payload)
    path = File.join(dir, name)
    File.write(path, JSON.pretty_generate(sort_keys(payload), indent: "  ") + "\n")
    path
  end

  # ---------------------------------------------------------------------------
  # routes.json
  # ---------------------------------------------------------------------------

  def routes_payload
    routes = Rails.application.routes.routes.map do |route|
      defaults = route.defaults || {}
      controller = defaults[:controller]
      action = defaults[:action]
      path_spec = route.path.spec.to_s

      # Segment/format constraints live on the PATH (`path.requirements`).
      # `route.requirements` is the same thing merged with the defaults, and
      # `route.constraints` is empty for ordinary routes -- reading the wrong
      # one silently reports "no constraints".
      segment_constraints = route.path.requirements || {}
      requirements = (route.requirements || {}).reject { |k, _| k == :controller || k == :action }

      {
        "source" => OBSERVED,
        "name" => route.name,
        "verb" => verb_for(route),
        "path" => path_spec.sub(/\(\.:format\)\z/, ""),
        "path_spec" => path_spec,
        "format_optional" => path_spec.end_with?("(.:format)"),
        "controller" => controller,
        "action" => action,
        "controller_class" => controller && "#{controller.camelize}Controller",
        "required_parts" => route.required_parts.map(&:to_s),
        "segment_keys" => route.segment_keys.map(&:to_s),
        "defaults" => jsonify(defaults),
        "constraints" => jsonify(segment_constraints),
        "requirements" => jsonify(requirements),
        "namespace_prefix" => namespace_prefix(controller),
        "internal" => !!route.internal,
        "engine" => engine_for(route)
      }
    end

    { "source" => OBSERVED, "count" => routes.length, "routes" => routes }
  end

  def verb_for(route)
    verb = route.verb
    return verb if verb.is_a?(String) && !verb.empty?
    "ANY"
  end

  # "api/v1/clubs" -> "api/v1"
  def namespace_prefix(controller)
    return nil if controller.nil?
    parts = controller.split("/")
    return nil if parts.length < 2
    parts[0..-2].join("/")
  end

  def engine_for(route)
    app = route.app
    return nil unless app.respond_to?(:app)
    inner = app.app
    inner.respond_to?(:routes) ? inner.class.name : nil
  end

  # ---------------------------------------------------------------------------
  # models.json
  # ---------------------------------------------------------------------------

  # Rails' own engines define Active Record models -- Active Storage blobs and
  # attachments, Action Text rich texts, Action Mailbox inbound emails. They are
  # genuine `ActiveRecord::Base` descendants, so a wide walk picks them up, and
  # they must not be counted as application models.
  INTERNAL_MODEL_NAMESPACES = %w[
    ActiveRecord ActiveStorage ActionText ActionMailbox ActionCable ActiveJob
    SolidQueue SolidCache SolidCable
  ].freeze

  def internal_model?(klass)
    name = klass.name.to_s
    INTERNAL_MODEL_NAMESPACES.any? { |ns| name == ns || name.start_with?("#{ns}::") }
  end

  # Active Record creates one implementation class named `HABTM_<Association>`
  # behind every has_and_belongs_to_many reflection. These are framework plumbing,
  # not application models; several owners may legitimately generate the same name.
  # Their join behavior is already represented by the owners' reflections.
  def generated_habtm_model?(klass)
    klass.name.to_s.start_with?("HABTM_")
  end

  # Walk from `ActiveRecord::Base`, NOT from `ApplicationRecord`. A model written
  # as `class Legacy < ActiveRecord::Base` -- still supported, and what every
  # pre-5.0 application is full of -- is invisible to the ApplicationRecord walk.
  # Its table would migrate (the schema walk reads the connection) while its
  # associations, validators, enums, encryption, serialization and attachments
  # silently vanished: the exact shape of "unknown reported as none".
  def active_record_models
    ActiveRecord::Base.descendants.reject { |k| k.abstract_class? || k.name.nil? }
  rescue StandardError
    []
  end

  # The application's own models: every concrete Active Record class Rails itself
  # does not own.
  def application_models
    active_record_models.reject { |k| internal_model?(k) || generated_habtm_model?(k) }
  end

  # Framework-owned models, recorded separately so that their absence from
  # `models` is a stated fact rather than an omission.
  def framework_models
    active_record_models.select { |k| internal_model?(k) }
  end

  def models_payload
    models = application_models.sort_by(&:name).map { |klass| model_entry(klass) }
    framework = framework_models.sort_by(&:name).map { |klass|
      { "source" => OBSERVED, "name" => klass.name, "table_name" => (klass.table_name rescue nil) }
    }

    {
      "source" => OBSERVED,
      "count" => models.length,
      "models" => models,
      "framework_models" => framework,
      "action_text" => action_text_payload
    }
  end

  def model_entry(klass)
    {
      "source" => OBSERVED,
      "name" => klass.name,
      "table_name" => klass.table_name,
      "primary_key" => klass.primary_key,
      "abstract" => !!klass.abstract_class?,
      "sti" => sti_entry(klass),
      "associations" => associations_for(klass),
      "attachments" => attachments_for(klass),
      "rich_texts" => rich_texts_for(klass),
      "validators" => validators_for(klass),
      "enums" => enums_for(klass),
      "default_scope" => default_scope_for(klass),
      "encrypted_attributes" => encrypted_attributes_for(klass),
      "record_timestamps" => !!klass.record_timestamps,
      "serialized_attributes" => serialized_attributes_for(klass)
    }
  end

  def sti_entry(klass)
    base = klass.base_class
    {
      "enabled" => klass.has_attribute?(klass.inheritance_column.to_s) && base.name != klass.name || base.descendants.any?,
      "inheritance_column" => klass.inheritance_column.to_s,
      "base_class" => base.name,
      "is_base_class" => base.name == klass.name,
      "subclasses" => base.descendants.map(&:name).sort
    }
  end

  def associations_for(klass)
    klass.reflect_on_all_associations.map { |r|
      {
        "source" => OBSERVED,
        "name" => r.name.to_s,
        "macro" => r.macro.to_s,
        "class_name" => (r.polymorphic? ? nil : safe_class_name(r)),
        "foreign_key" => safe_foreign_key(r),
        "foreign_type" => (r.respond_to?(:foreign_type) ? r.foreign_type&.to_s : nil),
        "polymorphic" => !!r.options[:polymorphic],
        "as" => r.options[:as]&.to_s,
        "through" => r.options[:through]&.to_s,
        "source_reflection" => (r.options[:source] || (r.options[:through] ? r.name : nil))&.to_s,
        "dependent" => r.options[:dependent]&.to_s,
        "inverse_of" => r.options[:inverse_of]&.to_s,
        "table_name" => (r.options[:polymorphic] ? nil : safe_table_name(r))
      }
    }.sort_by { |h| h["name"] }
  end

  def safe_class_name(r)
    r.class_name
  rescue StandardError
    nil
  end

  def safe_table_name(r)
    r.klass.table_name
  rescue StandardError
    nil
  end
  # NOT `.to_s`: a Rails 7.1 composite key is an Array, and `Array#to_s` is `inspect`,
  # which yields the literal `["a_id", "b_id"]` -- a string that is the name of nothing.
  # The converter cannot tell that from a real column name, so it looked the column up,
  # failed to find it, and skipped the association without a word. Emitted faithfully,
  # the shape is visible and the converter refuses it by name.
  def safe_foreign_key(r)
    composite_or_name(r.foreign_key)
  rescue StandardError
    nil
  end

  # A single key stays a string, as every consumer expects; a composite stays a list.
  def composite_or_name(value)
    value.is_a?(Array) ? value.map(&:to_s) : value.to_s
  end

  def attachments_for(klass)
    return [] unless klass.respond_to?(:reflect_on_all_attachments)

    klass.reflect_on_all_attachments.map { |r|
      {
        "source" => OBSERVED,
        "name" => r.name.to_s,
        "macro" => r.macro.to_s,
        "variants" => (r.variants.keys.map(&:to_s).sort rescue [])
      }
    }.sort_by { |h| h["name"] }
  end

  def validators_for(klass)
    klass.validators.flat_map { |validator|
      kind = validator.kind.to_s
      options = jsonify(validator.options)
      attrs = validator.respond_to?(:attributes) ? validator.attributes : []
      attrs = [ nil ] if attrs.empty?

      attrs.map do |attribute|
        {
          "source" => OBSERVED,
          "attribute" => attribute&.to_s,
          "kind" => kind,
          "class" => validator.class.name,
          "options" => options
        }
      end
    }.sort_by { |h| [ h["attribute"].to_s, h["kind"], h["class"].to_s ] }
  end

  def enums_for(klass)
    klass.defined_enums.to_h { |attribute, mapping|
      [ attribute, {
        "source" => OBSERVED,
        "values" => mapping.to_h { |label, db_value| [ label.to_s, jsonify(db_value) ] },
        "backing_type" => (klass.columns_hash[attribute]&.type&.to_s)
      } ]
    }
  end

  def default_scope_for(klass)
    present = klass.respond_to?(:default_scopes) && klass.default_scopes.any?
    entry = { "source" => OBSERVED, "present" => present, "count" => (present ? klass.default_scopes.length : 0) }

    if present
      # The scope BODY is a Proc and cannot be serialized, but its effect is
      # observable: compare the SQL of the scoped and unscoped relations.
      entry["scoped_sql"] = (klass.all.to_sql rescue nil)
      entry["unscoped_sql"] = (klass.unscoped.all.to_sql rescue nil)
    end

    entry
  end

  def encrypted_attributes_for(klass)
    return [] unless klass.respond_to?(:encrypted_attributes)

    (klass.encrypted_attributes || []).map { |attribute|
      scheme = (klass.type_for_attribute(attribute).scheme rescue nil)
      {
        "source" => OBSERVED,
        "attribute" => attribute.to_s,
        "deterministic" => (scheme ? !!scheme.deterministic? : nil),
        "downcase" => (scheme ? !!scheme.downcase? : nil)
      }
    }.sort_by { |h| h["attribute"] }
  end

  def serialized_attributes_for(klass)
    klass.attribute_types.filter_map { |name, type|
      next unless type.class.name.to_s.include?("Serialized")
      { "source" => OBSERVED, "attribute" => name, "coder" => (type.coder.class.name rescue nil) }
    }.sort_by { |h| h["attribute"] }
  end

  # ---------------------------------------------------------------------------
  # Action Text
  # ---------------------------------------------------------------------------
  #
  # A rich text body does NOT live on its model's table. `has_rich_text :content`
  # stores an HTML document in `action_text_rich_texts`, keyed polymorphically by
  # (record_type, record_id, name), with its embedded attachments in Active
  # Storage. A migration that copies a model's columns therefore carries the
  # record across and leaves the prose behind -- and nothing in the column list,
  # the validators or the attachment reflections says so.

  ACTION_TEXT_TABLE = "action_text_rich_texts".freeze

  # `has_rich_text` installs a `rich_text_<name>` has_one, which is what
  # `rich_text_association_names` reports. The scan fallback exists for a Rails
  # too old to expose that method; both read the reflections, never source text.
  def rich_texts_for(klass)
    names =
      if klass.respond_to?(:rich_text_association_names)
        klass.rich_text_association_names
      elsif defined?(::ActionText)
        klass.reflect_on_all_associations(:has_one).map(&:name).select { |n| n.to_s.start_with?("rich_text_") }
      else
        # Action Text is not loaded, so `has_rich_text` could not have been
        # called: this is an observed absence, not an unanswered question.
        []
      end

    names.map { |association_name|
      class_name = (klass.reflect_on_association(association_name)&.class_name rescue nil)
      {
        "source" => OBSERVED,
        "name" => association_name.to_s.sub(/\Arich_text_/, ""),
        "association_name" => association_name.to_s,
        "class_name" => class_name,
        "encrypted" => (class_name.nil? ? nil : class_name.to_s == "ActionText::EncryptedRichText")
      }
    }.sort_by { |h| h["name"] }
  rescue StandardError
    nil
  end

  def action_text_payload
    models = application_models.filter_map { |klass|
      rich_texts = rich_texts_for(klass)
      next if rich_texts.nil? || rich_texts.empty?
      {
        "source" => OBSERVED,
        "model" => klass.name,
        "table_name" => (klass.table_name rescue nil),
        "rich_texts" => rich_texts
      }
    }.sort_by { |h| h["model"].to_s }

    exists = action_text_table_exists?

    {
      "source" => OBSERVED,
      "loaded" => (defined?(::ActionText) ? true : false),
      "table" => ACTION_TEXT_TABLE,
      "table_exists" => exists,
      "row_count" => (exists == true ? action_text_row_count : nil),
      "models_with_rich_text" => models
    }
  end

  def action_text_table_exists?
    ActiveRecord::Base.connection.table_exists?(ACTION_TEXT_TABLE)
  rescue StandardError
    nil
  end

  def action_text_row_count
    connection = ActiveRecord::Base.connection
    value = connection.select_value("SELECT COUNT(*) FROM #{connection.quote_table_name(ACTION_TEXT_TABLE)}")
    value.nil? ? nil : value.to_i
  rescue StandardError
    nil
  end

  # ---------------------------------------------------------------------------
  # schema.json
  # ---------------------------------------------------------------------------

  def schema_payload
    connection = ActiveRecord::Base.connection

    tables = connection.tables.sort.map { |table| table_entry(connection, table) }
    triggers = catalog_rows(connection, "trigger")
    views = catalog_rows(connection, "view")

    {
      "source" => OBSERVED,
      "adapter" => connection.adapter_name,
      "database" => File.basename(connection.pool.db_config.database.to_s),
      "schema_migrations" => connection.select_values("SELECT version FROM schema_migrations ORDER BY version").map(&:to_s),
      "tables" => tables,
      # An empty array from an adapter we cannot interrogate is a LIE stamped `observed`:
      # a Postgres source with twenty triggers would report none. Say whether the catalog
      # was actually readable, so the converter can refuse rather than believe silence.
      "catalog_supported" => (catalog_supported?(connection) && !triggers.nil? && !views.nil?),
      # Distinguishes "this adapter has no foreign key concept at all" from "this
      # one table's inspection failed" -- both surface as a null `foreign_keys`.
      "foreign_keys_supported" => foreign_keys_supported?(connection),
      "triggers" => triggers || [],
      "views" => views || []
    }
  end

  # Trigger/view inspection is explicit per adapter. Anything else must be reported as
  # UNKNOWN, never as absent.
  def catalog_supported?(connection)
    adapter = connection.adapter_name.to_s.downcase
    adapter.include?("sqlite") || adapter.include?("postgres")
  end

  # `schema.rb` cannot express a check constraint, so the guide tells readers not to
  # trust it -- and this extractor was making the same omission one layer down.
  def check_constraints_for(connection, table)
    return nil unless connection.respond_to?(:supports_check_constraints?)
    return nil unless connection.supports_check_constraints?

    connection.check_constraints(table).map { |c|
      {
        "source" => OBSERVED,
        "name" => (c.name.to_s rescue nil),
        "expression" => (c.expression.to_s rescue nil),
        "validated" => (c.validated? rescue nil)
      }
    }.sort_by { |c| c["name"].to_s }
  rescue StandardError
    nil
  end

  # The same discipline as `check_constraints_for`, for the same reason. A blanket
  # `rescue []` around `foreign_keys` renders an adapter that cannot answer, or a
  # role without catalog permissions, identical to a table that genuinely has no
  # foreign keys -- and the relational structure is precisely what a converter
  # rebuilds from. `nil` means UNKNOWN; `[]` means observed-and-empty.
  def foreign_keys_for(connection, table)
    return nil unless connection.respond_to?(:supports_foreign_keys?)
    return nil unless connection.supports_foreign_keys?

    connection.foreign_keys(table).map { |fk|
      {
        "source" => OBSERVED,
        "from_table" => fk.from_table,
        "to_table" => fk.to_table,
        "column" => composite_or_name(fk.column),
        "primary_key" => composite_or_name(fk.primary_key),
        "name" => fk.name,
        "on_delete" => fk.on_delete&.to_s,
        "on_update" => fk.on_update&.to_s
      }
    }.sort_by { |h| [ h["column"], h["to_table"] ] }
  rescue StandardError
    nil
  end

  def foreign_keys_supported?(connection)
    return nil unless connection.respond_to?(:supports_foreign_keys?)
    !!connection.supports_foreign_keys?
  rescue StandardError
    nil
  end

  def table_entry(connection, table)
    {
      "source" => OBSERVED,
      "name" => table,
      "primary_key" => (connection.primary_key(table) rescue nil),
      "columns" => connection.columns(table).map { |c|
        {
          "source" => OBSERVED,
          "name" => c.name,
          "sql_type" => c.sql_type,
          "type" => c.type.to_s,
          "array" => (c.respond_to?(:array) ? !!c.array : false),
          "null" => !!c.null,
          "default" => jsonify(c.default),
          "default_function" => c.default_function
        }
      },
      "indexes" => connection.indexes(table).map { |i|
        {
          "source" => OBSERVED,
          "name" => i.name,
          "columns" => Array(i.columns).map(&:to_s),
          "unique" => !!i.unique,
          "where" => i.where
        }
      }.sort_by { |h| h["name"] },
      "foreign_keys" => foreign_keys_for(connection, table),
      "check_constraints" => check_constraints_for(connection, table)
    }
  end

  # Raw sqlite_master: triggers and views are INVISIBLE to db/schema.rb (the
  # :ruby schema format cannot express them), so they must be read from the
  # database catalog directly.
  def sqlite_master_rows(connection, type)
    return [] unless connection.adapter_name.to_s.downcase.include?("sqlite")

    connection.select_all(
      "SELECT name, tbl_name, sql FROM sqlite_master WHERE type = #{connection.quote(type)} ORDER BY name"
    ).to_a.map { |row|
      {
        "source" => OBSERVED,
        "type" => type,
        "name" => row["name"],
        "table" => row["tbl_name"],
        "sql" => row["sql"]
      }
    }
  end

  def postgres_catalog_rows(connection, type)
    return [] unless connection.adapter_name.to_s.downcase.include?("postgres")

    if type == "trigger"
      sql = <<~SQL
        SELECT t.tgname AS name, c.relname AS table_name,
               pg_get_triggerdef(t.oid, true) AS definition
          FROM pg_trigger t
          JOIN pg_class c ON c.oid = t.tgrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE NOT t.tgisinternal
           AND n.nspname = ANY (current_schemas(false))
         ORDER BY n.nspname, c.relname, t.tgname
      SQL
    else
      sql = <<~SQL
        SELECT c.relname AS name, c.relname AS table_name,
               pg_get_viewdef(c.oid, true) AS definition
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE c.relkind IN ('v', 'm')
           AND n.nspname = ANY (current_schemas(false))
         ORDER BY n.nspname, c.relname
      SQL
    end
    connection.select_all(sql).to_a.map { |row|
      {
        "source" => OBSERVED,
        "type" => type,
        "name" => row["name"],
        "table" => row["table_name"],
        "sql" => row["definition"]
      }
    }
  rescue StandardError
    nil
  end

  def catalog_rows(connection, type)
    adapter = connection.adapter_name.to_s.downcase
    return sqlite_master_rows(connection, type) if adapter.include?("sqlite")
    return postgres_catalog_rows(connection, type) if adapter.include?("postgres")
    []
  end

  # ---------------------------------------------------------------------------
  # storage.json
  # ---------------------------------------------------------------------------

  def storage_payload
    loaded = defined?(::ActiveStorage::Blob) ? true : false
    service = loaded ? (ActiveStorage::Blob.service rescue nil) : nil
    configurations = jsonify((Rails.application.config.active_storage.service_configurations rescue nil) || {})
    root = service_root(service)

    attachments = application_models
                    .select { |k| k.respond_to?(:reflect_on_all_attachments) && k.reflect_on_all_attachments.any? }
                    .sort_by(&:name)
                    .map { |klass|
      {
        "source" => OBSERVED,
        "model" => klass.name,
        "table_name" => klass.table_name,
        "attachments" => attachments_for(klass)
      }
    }

    {
      "source" => OBSERVED,
      "active_storage_loaded" => loaded,
      "service_name" => (service.respond_to?(:name) && service.name ? service.name.to_s : nil),
      "service_class" => (service ? service.class.name : nil),
      # `service_class` answers this only for a reader who knows every Active
      # Storage service class by name -- and MirrorService's name mentions
      # neither the bucket nor the disk hiding behind it. Say it outright:
      # can the converter read these bytes off the local filesystem?
      "service_type" => service_type(service),
      "local_disk" => local_disk_service?(service),
      "mirror" => mirror_entry(service),
      "root" => root,
      # A Disk root inside the app is rewritten to `<rails_root>/...` and is
      # portable; one configured outside it (a mounted volume) stays absolute,
      # because scrubbing it would destroy the only copy of that fact.
      "root_within_rails_root" => (root.nil? ? nil : root.start_with?("<rails_root>")),
      "configured_service" => (Rails.application.config.active_storage.service&.to_s rescue nil),
      "service_configurations" => configurations,
      "tables" => %w[active_storage_blobs active_storage_attachments active_storage_variant_records],
      "models_with_attachments" => attachments
    }
  end

  def service_root(service)
    return nil unless service.respond_to?(:root)
    value = service.root
    value.nil? ? nil : scrub_path(value.to_s)
  rescue StandardError
    nil
  end

  # "ActiveStorage::Service::S3Service" -> "S3". A third-party service class keeps
  # its full name rather than being flattened into something familiar-looking.
  def service_type(service)
    return nil if service.nil?
    name = service.class.name.to_s
    return name unless name.start_with?("ActiveStorage::Service::")
    short = name.sub(/\AActiveStorage::Service::/, "").sub(/Service\z/, "")
    short.empty? ? name : short
  end

  def mirror_service?(service)
    !service.nil? && service.class.name.to_s == "ActiveStorage::Service::MirrorService"
  end

  # true: the bytes are on this machine's filesystem. false: they are not.
  # nil: a service class this exporter does not recognise, which is UNKNOWN --
  # answering "false" would send a converter looking for a bucket that does not
  # exist, and "true" would send it looking for files that are not there.
  def local_disk_service?(service)
    return nil if service.nil?
    name = service.class.name.to_s
    return true if name == "ActiveStorage::Service::DiskService"
    return local_disk_service?(mirror_primary(service)) if mirror_service?(service)
    return false if name.start_with?("ActiveStorage::Service::")
    nil
  end

  def mirror_primary(service)
    service.respond_to?(:primary) ? service.primary : nil
  rescue StandardError
    nil
  end

  # A mirror writes to every leg and reads from the primary, so "where are the
  # bytes" has more than one answer and the primary is the one that matters.
  def mirror_entry(service)
    return nil unless mirror_service?(service)

    mirrors = (service.respond_to?(:mirrors) ? Array(service.mirrors) : []) rescue []
    {
      "source" => OBSERVED,
      "primary" => service_summary(mirror_primary(service)),
      "mirrors" => mirrors.map { |m| service_summary(m) }
    }
  end

  def service_summary(service)
    return nil if service.nil?
    {
      "source" => OBSERVED,
      "service_class" => service.class.name,
      "service_type" => service_type(service),
      "local_disk" => local_disk_service?(service),
      "root" => service_root(service)
    }
  end

  # ---------------------------------------------------------------------------
  # jobs.json
  # ---------------------------------------------------------------------------

  def jobs_payload
    jobs = ActiveJob::Base.descendants.sort_by(&:name).map { |klass|
      {
        "source" => OBSERVED,
        "name" => klass.name,
        "abstract" => klass.name == "ApplicationJob",
        "queue_name" => resolved_queue_name(klass),
        "application_owned" => application_job?(klass),
        "queue_adapter" => klass.queue_adapter.class.name
      }
    }

    {
      "source" => OBSERVED,
      "queue_adapter" => ActiveJob::Base.queue_adapter.class.name,
      "configured_adapter" => Rails.application.config.active_job.queue_adapter&.to_s,
      "count" => jobs.length,
      "jobs" => jobs
    }
  end

  # `queue_as { ... }` stores a Proc, whose `to_s` embeds a heap address and is
  # therefore not reproducible. Instantiate the job to resolve it to a String.
  # Framework namespaces that own their own jobs. Everything else is the
  # application's, namespaced or not: `Admin::DigestJob` is as much a migration
  # concern as `DigestJob`, and excusing it by the `::` in its name meant an
  # application that namespaces its jobs was adjudicated as having none.
  INTERNAL_JOB_NAMESPACES = %w[
    ActiveJob ActiveStorage ActionMailbox ActionMailer ActionCable
    SolidQueue SolidCache SolidCable Turbo
  ].freeze

  def application_job?(klass)
    name = klass.name.to_s
    return false if name.empty?
    return false if name == "ApplicationJob"

    location = begin
      klass.instance_method(:perform).source_location&.first
    rescue StandardError
      nil
    end
    unless location.nil? || location.empty?
      app_root = File.join(Rails.root.to_s, "app") + File::SEPARATOR
      return File.expand_path(location).start_with?(app_root)
    end

    INTERNAL_JOB_NAMESPACES.none? { |ns| name == ns || name.start_with?("#{ns}::") }
  end

  def resolved_queue_name(klass)
    raw = klass.queue_name
    return raw.to_s unless raw.is_a?(Proc)

    (klass.new.queue_name.to_s rescue nil)
  end

  # ---------------------------------------------------------------------------
  # counts.json
  # ---------------------------------------------------------------------------

  # Counts come from `unscoped` -- THIS IS THE POINT. `Club.count` runs through
  # `default_scope { where(archived_at: nil) }` and silently under-reports.
  def counts_payload
    connection = ActiveRecord::Base.connection
    model_by_table = application_models.group_by(&:table_name)

    tables = connection.tables.sort.map { |table|
      # The STI BASE class, not whichever subclass sorts first: `MeetingEvent.count`
      # carries an implicit `WHERE type = 'MeetingEvent'`, which would be reported as
      # rows hidden by a `default_scope` that does not exist.
      candidates = model_by_table[table] || []
      klass = candidates.find { |c| c.descends_from_active_record? } || candidates.min_by(&:name)
      unscoped_count = connection.select_value("SELECT COUNT(*) FROM #{connection.quote_table_name(table)}").to_i
      scoped_count = klass ? (klass.count rescue nil) : nil

      {
        "source" => OBSERVED,
        "table" => table,
        "model" => klass&.name,
        "unscoped_count" => unscoped_count,
        "scoped_count" => scoped_count,
        "hidden_by_default_scope" => (scoped_count.nil? ? nil : unscoped_count - scoped_count)
      }
    }

    { "source" => OBSERVED, "count" => tables.length, "tables" => tables }
  end

  # ---------------------------------------------------------------------------
  # versions.json
  # ---------------------------------------------------------------------------


  # ---------------------------------------------------------------------------
  # auth
  # ---------------------------------------------------------------------------
  #
  # The auth stack decides whether credentials can migrate at all, and two of its
  # properties are invisible in the data: a Devise pepper is mixed into the
  # plaintext before bcrypt, so a peppered digest is byte-indistinguishable from
  # an unpeppered one while verifying differently; and an OmniAuth-only account
  # has no digest to migrate in the first place. Both must be read from the
  # booted configuration, never guessed from a hash.
  #
  # The pepper is a SECRET. Only its presence is ever emitted.

  # Auth models do not always descend from ApplicationRecord (Devise generators
  # historically emitted `ActiveRecord::Base` subclasses), which is why the model
  # walk starts at `ActiveRecord::Base`. `application_models` is that walk.

  AUTH_GEMS = %w[
    devise sorcery clearance authlogic doorkeeper omniauth jwt bcrypt
    argon2 devise-jwt devise_token_auth pundit cancancan action_policy rack-attack
  ].freeze

  def gems_from_lockfile
    lockfile = Rails.root.join("Gemfile.lock")
    return [] unless File.exist?(lockfile)

    # A lockfile resolved for several platforms lists one spec line per platform, so
    # keeping the first would report whichever platform sorts first rather than the one
    # that ran. Split the platform suffix off the version and keep every variant: a
    # native auth gem reported at a platform the source never ran on is a migration
    # decision made off fiction.
    specs = {}
    section = nil
    File.foreach(lockfile) do |raw|
      line = raw.chomp
      case line
      when /\A[A-Z]/ then section = line.strip
      when /\A {4}([a-zA-Z0-9\-_.]+) \(([^)]+)\)\z/
        next unless section == "GEM"
        name = $1
        version, _, platform = $2.partition("-")
        entry = (specs[name] ||= { "version" => version, "platforms" => [] })
        entry["platforms"] << (platform.empty? ? "ruby" : platform)
      end
    end
    specs.sort.map do |name, entry|
      {
        "name" => name,
        "version" => entry["version"],
        "platforms" => entry["platforms"].uniq.sort,
        "source" => OBSERVED
      }
    end
  end

  def devise_entry
    return { "present" => false } unless defined?(::Devise)

    # `Devise.pepper` is a secret. Emit only whether one is configured — a
    # configured pepper makes every stored digest unverifiable by a plain bcrypt
    # check, which is the whole reason this field exists.
    pepper_configured = begin
      ::Devise.pepper.present?
    rescue StandardError
      nil
    end

    {
      "present" => true,
      "version" => (Gem.loaded_specs["devise"]&.version&.to_s rescue nil),
      "pepper_configured" => pepper_configured,
      "pepper_value_emitted" => false,
      "stretches" => (::Devise.stretches rescue nil),
      "encryptor" => (::Devise.encryptor.to_s rescue nil),
      "models" => devise_models
    }
  end

  def devise_models
    application_models.filter_map do |klass|
      modules = (klass.devise_modules rescue nil)
      next if modules.nil? || modules.empty?
      {
        "model" => klass.name,
        "table_name" => (klass.table_name rescue nil),
        "modules" => modules.map(&:to_s).sort,
        "source" => OBSERVED
      }
    end.sort_by { |e| e["model"].to_s }
  end

  def secure_password_models
    application_models.filter_map do |klass|
      # `has_secure_password :foo` installs its methods through an included
      # module, so `instance_methods(false)` does not see them; and Active
      # Record defines attribute methods lazily, so `method_defined?` on the
      # column can be false. Drive off the declared columns instead and confirm
      # the matching reader exists anywhere in the ancestry.
      columns = (klass.attribute_names rescue [])
      attributes = columns.filter_map do |name|
        next unless name.end_with?("_digest")
        prefix = name.sub(/_digest\z/, "")
        reader = prefix == "password" ? "authenticate" : "authenticate_#{prefix}"
        prefix if klass.method_defined?(reader) || klass.method_defined?("authenticate_#{prefix}")
      end
      next if attributes.empty?
      {
        "model" => klass.name,
        "table_name" => (klass.table_name rescue nil),
        "attributes" => attributes.uniq.sort,
        "digest_columns" => columns.select { |c| c.end_with?("_digest") }.sort,
        "source" => OBSERVED
      }
    end.sort_by { |e| e["model"].to_s }
  end

  def omniauth_entry
    return { "present" => false } unless defined?(::OmniAuth)

    providers = begin
      omniauth_middleware_providers
    rescue StandardError
      []
    end

    if providers.empty? && defined?(::Devise)
      providers = (::Devise.omniauth_configs.keys.map(&:to_s).sort rescue [])
    end

    { "present" => true, "providers" => providers, "credentials_emitted" => false }
  end

  # OmniAuth 2 has no global provider registry. Rails retains the configured Builder
  # block on its middleware descriptor, so build that one middleware around an inert
  # Rack endpoint and inspect only the resulting strategy names. No request runs, no
  # provider endpoint is contacted, and client ids/secrets are never read or emitted.
  def omniauth_middleware_providers
    middleware = Rails.application.config.middleware.select { |entry|
      entry.klass.name.to_s == "OmniAuth::Builder"
    }
    providers = []
    middleware.each do |entry|
      builder = entry.build(lambda { |_env| [ 404, {}, [] ] })
      app = builder.respond_to?(:to_app) ? builder.to_app : builder
      256.times do
        break if app.nil?
        if defined?(::OmniAuth::Strategy) && app.is_a?(::OmniAuth::Strategy)
          name = (app.options.name.to_s rescue "")
          providers << name unless name.empty?
        end
        break unless app.instance_variable_defined?(:@app)
        app = app.instance_variable_get(:@app)
      end
    end
    providers.uniq.sort
  end

  def auth_payload
    installed = gems_from_lockfile
    # Keep the whole entry, so auth_gems carries the same {version, platforms}
    # shape as gems. Two different shapes for the same fact is how a consumer
    # ends up reading one of them wrong.
    by_name = installed.each_with_object({}) { |g, h| h[g["name"]] = g }

    {
      "source" => OBSERVED,
      "gems" => installed,
      "auth_gems" => AUTH_GEMS.filter_map { |n|
        next unless by_name.key?(n)
        { "name" => n, "version" => by_name[n]["version"], "platforms" => by_name[n]["platforms"] }
      },
      "devise" => devise_entry,
      "has_secure_password" => secure_password_models,
      "omniauth" => omniauth_entry,
      "doorkeeper" => { "present" => defined?(::Doorkeeper) ? true : false }
    }
  end

  def versions_payload(taken_at)
    lockfile = Rails.root.join("Gemfile.lock")

    {
      "source" => OBSERVED,
      "exporter_version" => VERSION,
      "taken_at" => taken_at,
      "ruby_version" => RUBY_VERSION,
      "ruby_description" => RUBY_DESCRIPTION.sub(/ \[[^\]]*\]\z/, ""),
      "rails_version" => Rails.version,
      "application_class" => Rails.application.class.name,
      "rails_env" => Rails.env.to_s,
      "gemfile_lock_sha256" => (File.exist?(lockfile) ? Digest::SHA256.hexdigest(File.read(lockfile)) : nil),
      "adapter" => ActiveRecord::Base.connection.adapter_name,
      "database_version" => ActiveRecord::Base.connection.database_version.to_s,
      "api_only" => !!Rails.application.config.api_only,
      "schema_format" => (ActiveRecord.schema_format.to_s rescue Rails.application.config.active_record.schema_format.to_s)
    }
  end

  # ---------------------------------------------------------------------------
  # run
  # ---------------------------------------------------------------------------

  def run(argv)
    opts = parse_argv(argv)

    # Reflections, STI subclasses and job descendants only exist once every
    # class has been loaded. Without this the export silently under-reports.
    Rails.application.eager_load!
    Zeitwerk::Loader.eager_load_all if defined?(Zeitwerk::Loader)

    out = File.expand_path(opts[:out])
    FileUtils.mkdir_p(out)

    written = {
      "routes.json"   => routes_payload,
      "models.json"   => models_payload,
      "schema.json"   => schema_payload,
      "storage.json"  => storage_payload,
      "jobs.json"     => jobs_payload,
      "counts.json"   => counts_payload,
      "auth.json"     => auth_payload,
      "versions.json" => versions_payload(opts[:taken_at])
    }

    written.each { |name, payload| write_json(out, name, payload) }

    puts "exported #{written.keys.length} files to #{out}: " \
         "routes=#{written['routes.json']['count']} " \
         "models=#{written['models.json']['count']} " \
         "tables=#{written['schema.json']['tables'].length} " \
         "triggers=#{written['schema.json']['triggers'].length} " \
         "views=#{written['schema.json']['views'].length} " \
         "jobs=#{written['jobs.json']['count']} " \
         "gems=#{written['auth.json']['gems'].length} " \
         "devise=#{written['auth.json']['devise']['present']} " \
         "pepper=#{written['auth.json']['devise']['pepper_configured'].inspect} " \
         "rows=#{written['counts.json']['tables'].sum { |t| t['unscoped_count'] }}"
  end
end

RailsExportSource.run(ARGV)
