# SPDX-License-Identifier: MPL-2.0

import Config

# VeriSimDB for tests — use a separate port or test instance if available.
config :burble, Burble.Store,
  url: "http://localhost:8081",
  auth: :none,
  timeout: 10_000,
  # CI/test: VeriSimDB is not running. Start the Store in degraded offline
  # mode rather than refusing to boot — refusing collapses the whole
  # supervision tree and fails every app-dependent test (root cause of the
  # dead Elixir gate, burble#39). Production leaves offline_ok unset (false)
  # so a missing DB stays fail-fast.
  offline_ok: true

config :burble, BurbleWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test_only_secret_key_base_for_testing_purposes_only_do_not_use_in_production",
  server: false

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
config :bcrypt_elixir, :log_rounds, 1

# Swoosh: disable real email in test
config :swoosh, :api_client, false
config :burble, Burble.Mailer, adapter: Swoosh.Adapters.Test
