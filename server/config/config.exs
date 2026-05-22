# SPDX-License-Identifier: MPL-2.0
#
# Burble server configuration.

import Config

config :burble, BurbleWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: BurbleWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Burble.PubSub,
  live_view: [signing_salt: "burble_lv"]

# Guardian JWT authentication
config :burble, Burble.Auth.Guardian,
  issuer: "burble",
  # Secret key — overridden in prod via GUARDIAN_SECRET or SECRET_KEY_BASE.
  # In dev/test, falls back to a generated value from the config env.
  secret_key: System.get_env("GUARDIAN_SECRET", Base.encode64(:crypto.strong_rand_bytes(48))),
  ttl: {1, :hour},
  allowed_algos: ["HS256"],
  verify_issuer: true

# Deployment topology (monarchic, oligarchic, distributed, serverless)
config :burble, Burble.Topology,
  mode: :monarchic

# VeriSimDB persistent store
config :burble, Burble.Store,
  url: "http://localhost:8093",
  auth: :none,
  timeout: 30_000

# Automated VeriSimDB backups (disaster recovery).
# Disabled by default; enabled per-environment in dev.exs / prod.exs / runtime.exs.
config :burble, Burble.Store.BackupScheduler,
  enabled: false,
  interval_ms: :timer.hours(24),
  retention_count: 14,
  run_on_startup: false

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

# Email delivery
config :burble, Burble.Mailer,
  adapter: Swoosh.Adapters.Local

# Rate limiting
config :hammer,
  backend: {Hammer.Backend.ETS, [expiry_ms: 60_000 * 60, cleanup_interval_ms: 60_000 * 10]}

import_config "#{config_env()}.exs"
