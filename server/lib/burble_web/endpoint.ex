# SPDX-License-Identifier: MPL-2.0
#
# BurbleWeb.Endpoint — Phoenix HTTP/WebSocket endpoint.

defmodule BurbleWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :burble

  @session_options [
    store: :cookie,
    key: "_burble_key",
    signing_salt: "burble_voice",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  socket "/voice", BurbleWeb.UserSocket,
    websocket: [timeout: :infinity],
    longpoll: false

  plug Plug.Static,
    at: "/",
    from: :burble,
    gzip: false,
    only: BurbleWeb.static_paths()

  if code_reloading? do
    plug Phoenix.CodeReloader
  end

  plug Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  # CORS configuration. In production, restrict to the configured origin.
  # Default: allow all origins in dev/test, restrict in prod.
  plug Corsica,
    origins: Application.compile_env(:burble, :cors_origins, "*"),
    allow_headers: ["content-type", "authorization", "accept", "x-requested-with"],
    allow_methods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
    max_age: 600

  # Groove discovery — must be before the router so /.well-known/groove
  # is handled regardless of other pipeline configuration.
  # Enables Gossamer, PanLL, and other groove-aware systems to discover
  # Burble's voice/text capabilities via the Idris2-verified groove protocol.
  plug BurbleWeb.Plugs.GroovePlug

  plug BurbleWeb.Router
end
