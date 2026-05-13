# SPDX-License-Identifier: PMPL-1.0-or-later

import Config

config :burble, BurbleWeb.Endpoint,
  url: [host: System.get_env("PHX_HOST") || "example.com", port: 443, scheme: "https"],
  force_ssl: [hsts: true]

config :burble, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

config :logger, level: :info

# Swoosh's HTTP API client defaults to Hackney, which is not in deps.
# The mailer uses SMTP via gen_smtp (or the Local adapter when SMTP_HOST is
# unset), so no HTTP API client is needed. dev.exs / test.exs already set
# this; prod.exs was missing it, causing the release to fail at boot with
# "Could not find hackney dependency".
config :swoosh, :api_client, false
