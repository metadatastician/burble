# SPDX-License-Identifier: MPL-2.0
#
# Runtime configuration — loaded at boot, reads environment variables.

import Config

if System.get_env("PHX_SERVER") do
  config :burble, BurbleWeb.Endpoint, server: true
end

# STUN/TURN — read at startup so TurnCredentials works in all environments.
# Set TURN_SECRET (required for TURN), TURN_REALM, STUN_URL, TURN_URL, TURNS_URL.
config :burble,
  stun_url: System.get_env("STUN_URL", "stun:stun.l.google.com:19302"),
  turn_url: System.get_env("TURN_URL"),
  turns_url: System.get_env("TURNS_URL"),
  turn_secret: System.get_env("TURN_SECRET")

# SNIF configuration - path to WASM modules
snif_path = 
  System.get_env("BURBLE_SNIF_PATH") ||
  Path.join([:code.priv_dir(:burble), "snif", "burble_fft.wasm"])

config :burble, :snif_path, snif_path

# EXPERIMENTAL RTSP broadcast egress — runtime switch (see config.exs).
# BURBLE_RTSP_BROADCAST=true turns it on without recompiling.
if System.get_env("BURBLE_RTSP_BROADCAST") in ["1", "true", "TRUE", "yes"] do
  config :burble, :rtsp_broadcast, true
end

# Bolt SPA authentication secret — runtime override (see config.exs).
# When set, every bolt must carry a valid HMAC/timestamp/nonce tag.
if secret = System.get_env("BURBLE_BOLT_SECRET") do
  config :burble, :bolt_secret, secret
end

if config_env() == :prod do
  verisimdb_url =
    System.get_env("VERISIMDB_URL") ||
      raise """
      environment variable VERISIMDB_URL is missing.
      For example: https://verisimdb:8080
      """

  verisimdb_auth =
    case System.get_env("VERISIMDB_API_KEY") do
      nil -> :none
      key -> {:api_key, key}
    end

  config :burble, Burble.Store,
    url: verisimdb_url,
    auth: verisimdb_auth,
    timeout: String.to_integer(System.get_env("VERISIMDB_TIMEOUT") || "30000")

  # Automated VeriSimDB backups — opt-in via BURBLE_BACKUPS_ENABLED=true.
  # BURBLE_BACKUP_DIR should point at a mounted volume in the deployment.
  backups_enabled = System.get_env("BURBLE_BACKUPS_ENABLED") == "true"

  if backups_enabled do
    config :burble, Burble.Store.BackupScheduler,
      enabled: true,
      interval_ms:
        :timer.hours(String.to_integer(System.get_env("BURBLE_BACKUP_INTERVAL_HOURS") || "24")),
      dir: System.get_env("BURBLE_BACKUP_DIR") || "/var/backups/burble",
      retention_count: String.to_integer(System.get_env("BURBLE_BACKUP_RETENTION") || "14"),
      run_on_startup: System.get_env("BURBLE_BACKUP_RUN_ON_STARTUP") == "true"
  end

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      Generate one with: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "6473")

  config :burble, BurbleWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  # LLM service configuration
  config :burble, :llm,
    enabled: true,
    primary_port: String.to_integer(System.get_env("LLM_PORT") || "8503"),
    fallback_port: String.to_integer(System.get_env("LLM_FALLBACK_PORT") || "8085"),
    # Anthropic Claude API — set ANTHROPIC_API_KEY to enable server-side LLM.
    anthropic_model: System.get_env("ANTHROPIC_MODEL") || "claude-sonnet-4-6",
    anthropic_max_tokens: String.to_integer(System.get_env("ANTHROPIC_MAX_TOKENS") || "4096"),
    ipv6_preference: true,
    tls: [
      certfile: "priv/ssl/cert.pem",
      keyfile: "priv/ssl/key.pem",
      cacertfile: "priv/ssl/cacert.pem"
    ]

  # Guardian JWT secret — use SECRET_KEY_BASE if GUARDIAN_SECRET not set.
  guardian_secret = System.get_env("GUARDIAN_SECRET") || secret_key_base

  config :burble, Burble.Auth.Guardian,
    secret_key: guardian_secret

  # Topology mode (override for production clusters).
  topology = System.get_env("BURBLE_TOPOLOGY") || "monarchic"

  config :burble, Burble.Topology,
    mode: String.to_existing_atom(topology)

  # Base URL for magic link emails and invite links.
  base_url = System.get_env("BURBLE_BASE_URL") || "https://#{host}"

  # CORS: compile-time default is "*" (set in endpoint.ex via Application.compile_env).
  # Setting cors_origins here at runtime is inconsistent with the compile_env read
  # and Phoenix's validate_compile_env check refuses to boot. Until endpoint.ex
  # is updated to use `Application.get_env` instead of `compile_env` (Burble
  # Phase 1 work), cors_origins stays at the compile-time default. The
  # BURBLE_CORS_ORIGINS env var is honoured by reading at boot below but only
  # used for documentation; the value is not applied.
  _cors_origins_env = System.get_env("BURBLE_CORS_ORIGINS")

  config :burble,
    base_url: base_url

  # SMTP configuration for magic link email delivery.
  # All four SMTP_* variables must be set for production email sending.
  # If not set, falls back to Swoosh.Adapters.Local (emails logged, not sent).
  smtp_host = System.get_env("SMTP_HOST")

  if smtp_host do
    smtp_port = String.to_integer(System.get_env("SMTP_PORT") || "587")
    smtp_user = System.get_env("SMTP_USER") || raise "SMTP_USER required when SMTP_HOST is set"
    smtp_pass = System.get_env("SMTP_PASS") || raise "SMTP_PASS required when SMTP_HOST is set"

    config :burble, Burble.Mailer,
      adapter: Swoosh.Adapters.SMTP,
      relay: smtp_host,
      port: smtp_port,
      username: smtp_user,
      password: smtp_pass,
      ssl: smtp_port == 465,
      tls: :if_available,
      auth: :always,
      retries: 2,
      no_mx_lookups: false
  end
end
