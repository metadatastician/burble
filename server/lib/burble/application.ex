# SPDX-License-Identifier: PMPL-1.0-or-later
#
# Burble.Application — OTP supervision tree root.
#
# Starts the core services in dependency order:
#   1. Persistent store (VeriSimDB via Burble.Store)
#   2. PubSub (Phoenix.PubSub for room events)
#   3. Presence tracker (who's in which room)
#   4. Room registry (named process per active room)
#   5. Telemetry supervisor (metrics + periodic polling)
#   6. Web endpoint (Phoenix, WebSocket signaling)

defmodule Burble.Application do
  # Logger.info/1 is a macro — needs `require Logger` to expand correctly.
  # Without this, the call at log_hardware_capabilities/0 fails at runtime
  # with `function Logger.info/1 is undefined or private`.
  require Logger

  @moduledoc """
  OTP Application for Burble voice server.

  The supervision tree is structured so that:
  - VeriSimDB store failures don't crash the web endpoint
  - Room processes are isolated (one room crash doesn't affect others)
  - Telemetry is always running for observability
  """

  use Application

  @impl true
  def start(_type, _args) do
    # Create the RateLimiter ETS table at app startup so it persists for the
    # BEAM's lifetime. Doing this in BurbleWeb.Plugs.RateLimiter.init/1 fails
    # because Plug.init/1 runs at COMPILE TIME in production releases, and
    # the table created there dies with the compilation process.
    try do
      :ets.new(:burble_rate_limiter, [:named_table, :public, :set, read_concurrency: true])
      Logger.info("[Burble] RateLimiter ETS table created at app startup")
    rescue
      ArgumentError -> :ok  # Hot-reload case: table already exists.
    end

    children = [
      # Persistent store (VeriSimDB)
      Burble.Store,

      # Periodic VeriSimDB backups (disaster recovery)
      Burble.Store.BackupScheduler,

      # PubSub for real-time events (room join/leave, voice state changes)
      {Phoenix.PubSub, name: Burble.PubSub},

      # Presence tracking (who's in which room, voice state)
      Burble.Presence,

      # Room supervisor — DynamicSupervisor for room processes
      {DynamicSupervisor, name: Burble.RoomSupervisor, strategy: :one_for_one},

      # Room registry — maps room IDs to PIDs
      {Registry, keys: :unique, name: Burble.RoomRegistry},

      # WebRTC peer registry — maps peer IDs to Peer GenServer PIDs
      {Registry, keys: :unique, name: Burble.PeerRegistry},

      # WebRTC peer supervisor — one Peer GenServer per active participant
      {DynamicSupervisor, name: Burble.PeerSupervisor, strategy: :one_for_one},

      # Coprocessor pipeline registry — maps peer IDs to pipeline PIDs
      {Registry, keys: :unique, name: Burble.CoprocessorRegistry},

      # Coprocessor pipeline supervisor — one pipeline per active peer
      {DynamicSupervisor, name: Burble.CoprocessorSupervisor, strategy: :one_for_one},

      # In-memory chat message store (ETS-backed, per-room, ephemeral)
      Burble.Chat.MessageStore,

      # Text channels (NNTPS-backed persistent threaded messages)
      Burble.Text.NNTPSBackend,

      # Media plane — Membrane SFU (WebRTC audio routing)
      Burble.Media.Engine,

      # Telemetry
      Burble.Telemetry,

      # E2EE key rotation scheduler (rotates per-room keys for forward secrecy)
      Burble.Security.KeyRotation,

      # PTP precision timing (clock synchronisation for multi-node playout)
      Burble.Timing.PTP,

      # RTP↔wall-clock correlator — receives sync points from every inbound RTP
      # packet, maintains a 64-point sliding window, and provides rtp_to_wall /
      # wall_to_rtp conversion + PPM drift estimation for Phase 4 playout alignment.
      {Burble.Timing.ClockCorrelator, [name: Burble.Timing.ClockCorrelator, clock_rate: 48_000]},

      # Multi-node playout alignment — tracks per-node clock offsets and drift,
      # enables synchronized playout across Burble instances in the same room.
      {Burble.Timing.Alignment, [name: Burble.Timing.Alignment]},

      # Groove discovery endpoint (message queue for Gossamer/PanLL/etc.)
      # Serves GET /.well-known/groove with Burble capability manifest.
      # Groove connectors verified via Idris2 dependent types (Groove.idr).
      Burble.Groove,

      # Groove health mesh — probes peers every 30s, builds mesh status view.
      # Serves GET /.well-known/groove/mesh for inter-service health monitoring.
      Burble.Groove.HealthMesh,

      # Groove feedback store — receives feedback routed via the groove mesh.
      # Serves POST /.well-known/groove/feedback for feedback-o-tron integration.
      Burble.Groove.Feedback,

      # Blockchain anchoring bridge for Vext chains.
      # The Burble.Verification.Anchor module was intentionally removed (per
      # EXPLAINME.adoc — VeriSimDB and Vext handle internal chain integrity,
      # so external blockchain anchoring is redundant) but this supervisor
      # entry was not removed. Commented out here. Re-introduce only when
      # an actual Anchor module exists.
      # Burble.Verification.Anchor,

      # RTSP transport — serves broadcast/stage rooms and screen-share streams.
      # Listens on TCP port 8554 (RTSP control) and allocates UDP port pairs for
      # RTP media. Degrades gracefully if the port is unavailable.
      Burble.Transport.RTSP,

      # LLM service — QUIC+TLS on 8503, TCP+TLS fallback on 8085
      # Provides real-time LLM query processing with streaming responses
      {Burble.LLM.Supervisor, [port: 8503, fallback_port: 8085]},

      # LMDB playout buffer registry (individual buffers started per-room via DynamicSupervisor)
      # Note: LMDBPlayout instances are started dynamically per room, not here.
      # The RoomSupervisor above handles their lifecycle.

      # Bolt listener — UDP port 7373. Receives magic "incoming call" packets.
      # Degrades gracefully if the port is unavailable (logs warning, no crash).
      Burble.Bolt.Listener,

      # Web endpoint (must be last — depends on PubSub and Presence)
      BurbleWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Burble.Supervisor]
    result = Supervisor.start_link(children, opts)
    log_hardware_capabilities()
    result
  end

  # Log which hardware acceleration paths are active at startup.
  # This makes it immediately visible in logs whether you're getting
  # SIMD audio, WASM isolation, or PTP hardware timing — vs soft fallbacks.
  defp log_hardware_capabilities do
    alias Burble.Coprocessor.{ZigBackend, SNIFBackend}

    zig = if ZigBackend.available?(), do: "ACTIVE (SIMD)", else: "UNAVAILABLE → Elixir fallback"

    snif =
      if SNIFBackend.available?(),
        do: "ACTIVE (WASM/SNIF)",
        else: "UNAVAILABLE → Zig/Elixir fallback"

    # PTP module exposes source/0 (not status/0). Wrapped in try/rescue so a
    # rename of either function does not crash app boot — this is diagnostic
    # output, not a load-bearing call.
    ptp_source =
      try do
        case Burble.Timing.PTP.source() do
          atom when is_atom(atom) -> Atom.to_string(atom)
          {:ok, %{source: s}} when is_atom(s) -> Atom.to_string(s)
          _ -> "unknown"
        end
      rescue
        _ -> "unknown"
      end

    llm =
      if System.get_env("ANTHROPIC_API_KEY") do
        model = System.get_env("ANTHROPIC_MODEL", "claude-sonnet-4-5")
        "ACTIVE (#{model})"
      else
        "DISABLED (ANTHROPIC_API_KEY not set)"
      end

    Logger.info("""
    ┌─ Burble capability report ────────────────────────────────
    │  Zig NIF (SIMD audio/DSP)  : #{zig}
    │  SNIF (WASM crash-isolated) : #{snif}
    │  PTP clock source          : #{ptp_source}
    │  LLM service               : #{llm}
    └────────────────────────────────────────────────────────────
    """)
  end

  @impl true
  def config_change(changed, _new, removed) do
    BurbleWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  @doc """
  Health check for container HEALTHCHECK and monitoring.

  Verifies the supervision tree is running and VeriSimDB is reachable.
  Called via `bin/burble rpc "Burble.Application.health_check()"` from
  the Containerfile HEALTHCHECK directive.

  Returns `:ok` if healthy, raises on failure (non-zero exit for container).
  """
  @spec health_check() :: :ok
  def health_check do
    # Check that the supervision tree is alive.
    case Process.whereis(Burble.Supervisor) do
      nil -> raise "Burble.Supervisor is not running"
      _pid -> :ok
    end

    # Check VeriSimDB connectivity.
    case Burble.Store.health() do
      {:ok, true} -> :ok
      {:ok, false} -> raise "VeriSimDB reports unhealthy"
      {:error, reason} -> raise "VeriSimDB health check failed: #{inspect(reason)}"
    end
  end
end
