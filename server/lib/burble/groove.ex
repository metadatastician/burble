# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Burble.Groove — Gossamer Groove endpoint for capability discovery.
#
# Exposes Burble's voice/text capabilities via the groove discovery protocol.
# Any groove-aware system (Gossamer, PanLL, GSA, AmbientOps, etc.) can discover
# Burble by probing GET /.well-known/groove on port 4020.
#
# Works standalone — Burble functions perfectly without any groove consumer.
# When a consumer connects, additional features light up (panel embedding,
# workspace voice, admin alerts, etc.).
#
# The groove connector types are formally verified in Gossamer's Groove.idr:
# - CapabilityType proves what we offer is well-typed
# - IsSubset proves consumers can only connect if we satisfy their needs
# - GrooveHandle is linear: consumers MUST disconnect (no dangling grooves)
#
# Groove Protocol:
#   GET  /.well-known/groove            — Capability manifest (JSON)
#   POST /.well-known/groove/message    — Receive message from consumer
#   GET  /.well-known/groove/recv       — Pending messages for consumer
#   POST /.well-known/groove/connect    — Establish connection (spec 4.2)
#   POST /.well-known/groove/disconnect — Tear down connection (spec 4.5)
#   GET  /.well-known/groove/heartbeat  — Heartbeat keepalive (spec 4.3)
#   GET  /.well-known/groove/status     — Current connection states
#
# Integration Patterns:
#   Gossamer  → Voice panel in webview shell (spatial audio, PTT, presence)
#   PanLL     → Workspace voice layer (VoiceTag, operator commands, panel events)
#   GSA       → Voice alerts for server health (TTS, escalation, team channels)
#   AmbientOps → Escalation voice (Ward→ER→OR department channels)
#   RPA Elysium → Bot failure voice alerts (EventBus notification backend)
#   IDApTIK   → In-game co-op voice (Jessica↔Q spatial audio)
#   Vext      → Message integrity (hash chain verification on text channels)

defmodule Burble.Groove do
  @moduledoc """
  Manages the groove message queue and manifest for Burble.

  Started as part of the Burble supervision tree. Maintains an in-memory
  queue of messages from groove consumers (Gossamer, PanLL, etc.) and
  provides the static capability manifest.
  """

  use GenServer

  require Logger

  # --- Connection Lifecycle States ---
  #
  # DISCOVERED -> NEGOTIATING -> CONNECTED -> ACTIVE -> DISCONNECTING -> DISCONNECTED
  #                  |                          |
  #               REJECTED                   DEGRADED -> RECONNECTING -> ACTIVE
  #
  # See: standards/groove-protocol/spec/SPEC.adoc section 4.

  @type connection_state ::
          :discovered
          | :negotiating
          | :connected
          | :active
          | :degraded
          | :reconnecting
          | :disconnecting
          | :disconnected
          | :rejected

  @manifest %{
    groove_version: "1",
    service_id: "burble",
    service_version: "1.0.0",
    capabilities: %{
      voice: %{
        type: "voice",
        description: "WebRTC voice channels with Opus codec, noise suppression, echo cancellation",
        protocol: "webrtc",
        endpoint: "/voice",
        requires_auth: false,
        panel_compatible: true
      },
      text: %{
        type: "text",
        description: "Real-time text messaging in rooms via Phoenix Channels",
        protocol: "websocket",
        endpoint: "/socket/websocket",
        requires_auth: false,
        panel_compatible: true
      },
      presence: %{
        type: "presence",
        description: "User presence and speaking indicators via Phoenix Presence",
        protocol: "websocket",
        endpoint: "/socket/websocket",
        requires_auth: false,
        panel_compatible: true
      },
      spatial_audio: %{
        type: "spatial-audio",
        description: "Positional audio for game integration (x, y, z coordinates)",
        protocol: "webrtc",
        endpoint: "/voice",
        requires_auth: true,
        panel_compatible: false
      },
      recording: %{
        type: "recording",
        description: "Server-side voice recording with consent tracking via Avow",
        protocol: "http",
        endpoint: "/api/v1/recordings",
        requires_auth: true,
        panel_compatible: true
      },
      tts: %{
        type: "tts",
        description: "Text-to-speech synthesis for voice alerts and notifications",
        protocol: "http",
        endpoint: "/api/v1/tts",
        requires_auth: false,
        panel_compatible: false
      },
      stt: %{
        type: "stt",
        description: "Speech-to-text transcription for voice commands and VoiceTag",
        protocol: "http",
        endpoint: "/api/v1/stt",
        requires_auth: false,
        panel_compatible: false
      }
    },
    consumes: ["integrity", "octad-storage", "scanning"],
    endpoints: %{
      voice_ws: "ws://localhost:4020/voice",
      channel_ws: "ws://localhost:4020/socket/websocket",
      api: "http://localhost:4020/api/v1",
      health: "http://localhost:4020/api/v1/health"
    },
    health: "/api/v1/health",
    applicability: ["individual", "team", "massive-open"]
  }

  # Maximum queue depth to prevent memory exhaustion.
  @max_queue_depth 1000

  # Heartbeat timeout: 3 missed heartbeats at 5s interval = 15s (per spec section 4.3).
  @heartbeat_timeout_ms 15_000

  # --- Client API ---

  @doc "Start the groove GenServer."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Return the groove capability manifest as a map."
  def manifest, do: @manifest

  @doc "Return the manifest as JSON."
  def manifest_json do
    Jason.encode!(@manifest)
  end

  @doc "Enqueue a message from a groove consumer."
  def push_message(message) when is_map(message) do
    GenServer.call(__MODULE__, {:push, message})
  end

  @doc "Drain all pending messages for groove consumers."
  def pop_messages do
    GenServer.call(__MODULE__, :pop)
  end

  @doc "Get current queue depth."
  def queue_depth do
    GenServer.call(__MODULE__, :depth)
  end

  # --- Connection Lifecycle API ---

  @doc """
  Handle a connect request from a groove consumer.

  Accepts the peer's manifest, checks structural compatibility, and returns
  a session ID if compatible. Transitions the connection through:
  DISCOVERED -> NEGOTIATING -> CONNECTED.

  Returns `{:ok, session_id}` on success or `{:error, reason}` on rejection.
  """
  @spec connect(map()) :: {:ok, String.t()} | {:error, String.t()}
  def connect(peer_manifest) when is_map(peer_manifest) do
    GenServer.call(__MODULE__, {:connect, peer_manifest})
  end

  @doc """
  Handle a disconnect request from a groove consumer.

  Consumes the session handle and transitions to DISCONNECTED.
  Returns `:ok` on success or `{:error, :not_found}` if the session does not exist.
  """
  @spec disconnect(String.t()) :: :ok | {:error, :not_found}
  def disconnect(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:disconnect, session_id})
  end

  @doc """
  Record a heartbeat from a connected peer.

  Resets the heartbeat timeout timer. Returns `:ok` if the session exists.
  """
  @spec heartbeat(String.t()) :: :ok | {:error, :not_found}
  def heartbeat(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:heartbeat, session_id})
  end

  @doc """
  Return the current status of all groove connections.

  Returns a map of session_id => connection info (peer_id, state, connected_at,
  last_heartbeat, capabilities).
  """
  @spec connection_status() :: map()
  def connection_status do
    GenServer.call(__MODULE__, :connection_status)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    # Schedule periodic heartbeat checks.
    :timer.send_interval(5_000, :check_heartbeats)

    {:ok,
     %{
       queue: :queue.new(),
       depth: 0,
       # Connections: %{session_id => %{peer_id, state, connected_at, last_heartbeat, manifest}}
       connections: %{}
     }}
  end

  @impl true
  def handle_call({:push, message}, _from, %{queue: q, depth: d} = state) do
    if d >= @max_queue_depth do
      # Drop oldest message to make room.
      {_dropped, q2} = :queue.out(q)
      {:reply, :ok, %{state | queue: :queue.in(message, q2)}}
    else
      {:reply, :ok, %{state | queue: :queue.in(message, q), depth: d + 1}}
    end
  end

  @impl true
  def handle_call(:pop, _from, %{queue: q}) do
    messages = :queue.to_list(q)
    {:reply, messages, %{queue: :queue.new(), depth: 0}}
  end

  @impl true
  def handle_call(:depth, _from, %{depth: d} = state) do
    {:reply, d, state}
  end

  @impl true
  def handle_call({:connect, peer_manifest}, _from, state) do
    peer_id = Map.get(peer_manifest, "service_id", "unknown")

    # Check structural compatibility: the peer must consume at least one
    # capability that we offer. This is a simplified runtime check — the
    # full compile-time proof lives in Groove.idr (Idris2 ABI layer).
    peer_consumes = Map.get(peer_manifest, "consumes", [])
    our_offer_ids = Map.keys(@manifest.capabilities) |> Enum.map(&Atom.to_string/1)

    matched_capabilities =
      Enum.filter(peer_consumes, fn cap ->
        cap in our_offer_ids
      end)

    if matched_capabilities == [] and peer_consumes != [] do
      Logger.info("[Groove] Rejected connection from #{peer_id}: no capability match")
      {:reply, {:error, "no matching capabilities"}, state}
    else
      session_id = generate_session_id()
      now = System.system_time(:millisecond)

      conn_info = %{
        peer_id: peer_id,
        state: :connected,
        connected_at: now,
        last_heartbeat: now,
        matched_capabilities: matched_capabilities,
        manifest: peer_manifest,
        messages_sent: 0,
        messages_received: 0,
        errors: 0
      }

      new_connections = Map.put(state.connections, session_id, conn_info)

      :telemetry.execute(
        [:burble, :groove, :connect],
        %{count: 1},
        %{peer_id: peer_id, session_id: session_id}
      )

      Logger.info(
        "[Groove] Connected: #{peer_id} (session=#{session_id}, capabilities=#{inspect(matched_capabilities)})"
      )

      {:reply, {:ok, session_id}, %{state | connections: new_connections}}
    end
  end

  @impl true
  def handle_call({:disconnect, session_id}, _from, state) do
    case Map.pop(state.connections, session_id) do
      {nil, _connections} ->
        {:reply, {:error, :not_found}, state}

      {conn_info, remaining} ->
        :telemetry.execute(
          [:burble, :groove, :disconnect],
          %{duration_ms: System.system_time(:millisecond) - conn_info.connected_at},
          %{peer_id: conn_info.peer_id, session_id: session_id}
        )

        Logger.info(
          "[Groove] Disconnected: #{conn_info.peer_id} (session=#{session_id})"
        )

        {:reply, :ok, %{state | connections: remaining}}
    end
  end

  @impl true
  def handle_call({:heartbeat, session_id}, _from, state) do
    case Map.get(state.connections, session_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      conn_info ->
        now = System.system_time(:millisecond)
        updated = %{conn_info | last_heartbeat: now, state: :active}
        new_connections = Map.put(state.connections, session_id, updated)
        {:reply, :ok, %{state | connections: new_connections}}
    end
  end

  @impl true
  def handle_call(:connection_status, _from, state) do
    status =
      Map.new(state.connections, fn {session_id, info} ->
        {session_id,
         %{
           peer_id: info.peer_id,
           state: info.state,
           connected_at: info.connected_at,
           last_heartbeat: info.last_heartbeat,
           matched_capabilities: info.matched_capabilities
         }}
      end)

    {:reply, status, state}
  end

  # --- Heartbeat Monitoring ---

  @impl true
  def handle_info(:check_heartbeats, state) do
    now = System.system_time(:millisecond)

    updated_connections =
      Enum.reduce(state.connections, %{}, fn {session_id, info}, acc ->
        elapsed = now - info.last_heartbeat

        cond do
          # Timed out — transition to DISCONNECTED and remove.
          elapsed > @heartbeat_timeout_ms and info.state == :degraded ->
            Logger.warning(
              "[Groove] Peer #{info.peer_id} (session=#{session_id}) timed out, removing"
            )

            acc

          # Missed heartbeats — transition to DEGRADED.
          elapsed > @heartbeat_timeout_ms ->
            Logger.warning(
              "[Groove] Peer #{info.peer_id} (session=#{session_id}) degraded (no heartbeat for #{elapsed}ms)"
            )

            Map.put(acc, session_id, %{info | state: :degraded})

          true ->
            Map.put(acc, session_id, info)
        end
      end)

    {:noreply, %{state | connections: updated_connections}}
  end

  # Catch-all for unexpected messages.
  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Helpers ---

  # Generate a unique session ID (hex-encoded random bytes).
  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.hex_encode32(case: :lower, padding: false)
  end
end
