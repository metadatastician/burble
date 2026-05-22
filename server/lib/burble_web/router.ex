# SPDX-License-Identifier: MPL-2.0
#
# BurbleWeb.Router — HTTP routing for the Burble API.

defmodule BurbleWeb.Router do
  use Phoenix.Router, helpers: false

  import Plug.Conn
  import Phoenix.Controller
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {BurbleWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug BurbleWeb.Plugs.InputSanitizer
    plug BurbleWeb.Plugs.RateLimiter
  end

  # JSON-only pipeline without rate limiting (health checks, monitoring).
  pipeline :accepts_json do
    plug :accepts, ["json"]
  end

  pipeline :authenticated_api do
    plug :accepts, ["json"]
    plug BurbleWeb.Plugs.InputSanitizer
    plug Burble.Auth.GuardianPipeline
  end

  # Health check endpoint — unauthenticated, no rate limiting.
  # Used by container HEALTHCHECK, load balancers, and admin panel.
  scope "/api/v1", BurbleWeb.API do
    pipe_through [:accepts_json]

    get "/health", HealthController, :check
  end

  # Public API routes (no auth required).
  scope "/api/v1", BurbleWeb.API do
    pipe_through :api

    # Auth (public — issues tokens)
    post "/auth/register", AuthController, :register
    post "/auth/login", AuthController, :login
    post "/auth/guest", AuthController, :guest
    post "/auth/magic-link", AuthController, :magic_link
    post "/auth/refresh", AuthController, :refresh

    # Invite acceptance (public — uses invite token, not auth token)
    post "/invites/:token/accept", InviteController, :accept

    # Setup wizard (public — first-time configuration)
    get "/setup/check", SetupController, :check
    post "/setup/audio-devices", SetupController, :audio_devices
    post "/setup/test-microphone", SetupController, :test_microphone
    post "/setup/test-speakers", SetupController, :test_speakers
    post "/setup/complete", SetupController, :complete

    # Diagnostics (public — self-test before joining voice)
    get "/diagnostics/self-test", DiagnosticsController, :self_test
    get "/diagnostics/self-test/:mode", DiagnosticsController, :self_test

    # LLM status (public — checks if provider is configured)
    get "/llm/status", LLMController, :status

    # RTSP transport status (public — operator/monitoring endpoint)
    get "/rtsp/status", RTSPController, :status

    # Instant connect — join via link/QR/code (public, no auth required)
    get "/join/:code", InstantConnectController, :lookup
    post "/join/:code", InstantConnectController, :redeem
  end

  # Authenticated API routes (require valid JWT).
  scope "/api/v1", BurbleWeb.API do
    pipe_through :authenticated_api

    delete "/auth/logout", AuthController, :logout

    # Servers
    get "/servers", ServerController, :index
    post "/servers", ServerController, :create
    get "/servers/:id", ServerController, :show

    # Rooms
    get "/servers/:server_id/rooms", RoomController, :index
    post "/servers/:server_id/rooms", RoomController, :create
    get "/rooms/:id", RoomController, :show
    get "/rooms/:id/participants", RoomController, :participants

    # Voice routing (broadcast all / group / private / priority)
    put "/rooms/:id/routing/mode", RoutingController, :set_mode
    get "/rooms/:id/routing/mode", RoutingController, :get_mode
    post "/rooms/:id/routing/groups", RoutingController, :create_group
    get "/rooms/:id/routing/groups", RoutingController, :list_groups
    post "/rooms/:id/routing/groups/:group_id/join", RoutingController, :join_group
    delete "/rooms/:id/routing/groups/leave", RoutingController, :leave_group

    # Text messages
    get "/rooms/:id/messages", MessageController, :index
    post "/rooms/:id/messages", MessageController, :create

    # Moderation
    post "/rooms/:id/kick", ModerationController, :kick
    post "/rooms/:id/mute", ModerationController, :mute
    post "/rooms/:id/move", ModerationController, :move
    post "/servers/:id/ban", ModerationController, :ban

    # LLM queries (authenticated — either side of the P2P bridge can call)
    post "/llm/query", LLMController, :query
    post "/llm/stream", LLMController, :stream

    # Invites (creation requires auth)
    post "/servers/:server_id/invites", InviteController, :create
  end

  # LiveDashboard for operators (dev + prod with auth)
  if Application.compile_env(:burble, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser
      live_dashboard "/dashboard", metrics: Burble.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  # Serve the MVP web client at root
  scope "/", BurbleWeb do
    pipe_through :browser
    get "/", PageController, :index
  end

  @doc false
  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt index.html)
end

defmodule BurbleWeb do
  @moduledoc false

  def static_paths, do: BurbleWeb.Router.static_paths()
end
