# SPDX-License-Identifier: MPL-2.0

import Config

# VeriSimDB for development — Burble's dedicated instance on port 6078.
# Port allocation: 6077=OPSM, 6078=Burble, 8090/8091=GSA, 8093=Stapeln,
# 8094=007, 8095=Project-M, 8096=work instance.
# Run: podman run -p 6078:8080 -v burble-verisimdb-data:/data cgr.dev/chainguard/wolfi-base
config :burble, Burble.Store,
  url: "http://localhost:6078",
  auth: :none,
  timeout: 30_000

config :burble, BurbleWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 6473],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "dev_only_secret_key_base_that_must_be_replaced_in_production_with_real_secret",
  watchers: []

config :burble, dev_routes: true

config :logger, :console, format: "[$level] $message\n"
config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime

# Use Swoosh local adapter in dev (no hackney needed)
config :swoosh, :api_client, false
config :burble, Burble.Mailer, adapter: Swoosh.Adapters.Local
