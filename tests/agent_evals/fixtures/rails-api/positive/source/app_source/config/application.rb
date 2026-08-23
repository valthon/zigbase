require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
require "action_mailbox/engine"
require "action_text/engine"
require "action_view/railtie"
require "action_cable/engine"
# require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module BookclubApi
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Only loads a smaller set of middleware suitable for API only apps.
    # Middleware like session, flash, cookies can be added back manually.
    # Skip views, helpers and assets when generating a new resource.
    config.api_only = true

    # ------------------------------------------------------------------
    # FIXTURE DETERMINISM
    # ------------------------------------------------------------------
    # This application is a *synthetic migration-test fixture*. Everything
    # below is deliberately hard-coded so that a fresh `db:migrate db:seed`
    # produces byte-identical artifacts on every machine.
    #
    # These are OBVIOUSLY-SYNTHETIC TEST VALUES. They are not secrets, they
    # protect nothing, and they must never be reused by a real application.
    # ------------------------------------------------------------------

    # Fixed secret_key_base (normally per-environment + kept out of git).
    config.secret_key_base = "0" * 64

    # Fixed Active Record encryption key set (normally in credentials).
    config.active_record.encryption.primary_key = "fixture_primary_key_0000000000000000"
    config.active_record.encryption.deterministic_key = "fixture_deterministic_key_00000000000"
    config.active_record.encryption.key_derivation_salt = "fixture_key_derivation_salt_000000000"
    config.active_record.encryption.support_unencrypted_data = false

    # `:inline` runs enqueued jobs synchronously inside the request, so the
    # rows a job writes are already committed by the time the HTTP response
    # is returned and are therefore visible in the frozen database.
    # A PRODUCTION deployment would use a real adapter (:solid_queue,
    # :sidekiq, ...) and the job side effects would be asynchronous.
    config.active_job.queue_adapter = :inline

    # Deterministic ordering for the fixture: never depend on insertion order.
    config.active_record.default_timezone = :utc
    config.time_zone = "UTC"
  end
end
