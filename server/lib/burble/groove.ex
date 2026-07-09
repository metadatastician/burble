# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Burble.Groove — Gossamer Groove endpoint for capability discovery.
#
# Exposes Burble's voice/text capabilities via the groove discovery protocol.
# Any groove-aware system (Gossamer, PanLL, GSA, AmbientOps, etc.) can discover
# Burble by probing GET /.well-known/groove on port 6473.
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
#   GET  /.well-known/groove              — Capability manifest (JSON)
#   POST /.well-known/groove/message      — Receive message from consumer
#   GET  /.well-known/groove/recv         — Pending messages for consumer
#   POST /.well-known/groove/connect      — Establish connection (spec 4.2; optional lease, SPEC v0.3)
#   POST /.well-known/groove/disconnect   — Tear down connection (spec 4.5)
#   GET  /.well-known/groove/heartbeat    — Heartbeat keepalive (spec 4.3; ?handle= refreshes leases)
#   GET  /.well-known/groove/status       — Current connection states
#   GET  /.well-known/groove/attestations — Attestation hash chain, newest-last (SPEC v0.3)
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

  # Canonical capability manifest. The static file at the repo root
  # (.well-known/groove/manifest.json) is GENERATED from this attribute —
  # regenerate it with `mix burble.groove.manifest` after any change here.
  # CI asserts byte-identity (Burble.GrooveTest).
  #
  # requires_auth reconciliation (ground truth: endpoint.ex + router.ex):
  # the /voice socket (BurbleWeb.UserSocket.connect/3) admits guest
  # connections without a token, so voice/text/presence remain
  # requires_auth: false. spatial_audio and recording stay true
  # (channel-level / Guardian-gated API surfaces).
  @manifest %{
    groove_version: "1",
    service_id: "burble",
    service_version: "1.0.0",
    mode: "active",
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
      voice_ws: "ws://localhost:6473/voice",
      channel_ws: "ws://localhost:6473/socket/websocket",
      api: "http://localhost:6473/api/v1",
      health: "http://localhost:6473/api/v1/health"
    },
    health: "/api/v1/health",
    applicability: ["individual", "team", "massive-open"]
  }

  # Maximum queue depth to prevent memory exhaustion.
  @max_queue_depth 1000

  # Maximum attestation chain length — oldest records rotate out past this.
  @max_attestation_depth 1000

  # Heartbeat timeout: 3 missed heartbeats at 5s interval = 15s (per spec section 4.3).
  @heartbeat_timeout_ms 15_000

  # Default interval between :check_heartbeats sweeps. Tests stretch this via
  # the :groove_sweep_interval_ms app env and send the sweep message directly.
  @sweep_interval_ms 5_000

  # Hard leases tolerate this many consecutive missed TTL windows before
  # degrading through the soft-expiry path (groove-protocol SPEC v0.3).
  @lease_max_missed_windows 3

  # Genesis link for the attestation hash chain. Matches the estate hash-chain
  # convention (all-zeros digest, cf. Burble.Verification.Vext genesis hash)
  # carrying the same "sha256:" prefix as every other record hash.
  @genesis_hash "sha256:" <> String.duplicate("0", 64)

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

  The manifest MAY carry a `"lease"` (groove-protocol SPEC v0.3):
  `%{"mode" => "soft" | "hard", "ttl_ms" => pos_integer}`. Soft leases expire
  at TTL absent any refresh; hard leases are refreshed by heartbeats and only
  expire after #{@lease_max_missed_windows} consecutive missed TTL windows.
  Expiry leaves zero provider-side residue (connection state and the peer's
  queued messages are wiped) and is attested as `"groove:lease-expired"`.

  Returns `{:ok, session_id}` (no lease — legacy behaviour unchanged),
  `{:ok, session_id, accepted_lease}` (lease requested), or
  `{:error, reason}` on rejection.
  """
  @spec connect(map()) ::
          {:ok, String.t()} | {:ok, String.t(), map()} | {:error, String.t()}
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

  Resets the heartbeat timeout timer. For leased connections the refresh
  also moves lease expiry to now + ttl_ms and clears the missed-window
  count — an actively refreshed connection is never reaped.
  Returns `:ok` if the session exists.
  """
  @spec heartbeat(String.t()) :: :ok | {:error, :not_found | :soft_lease}
  def heartbeat(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:heartbeat, session_id})
  end

  @doc """
  Return the attestation chain, newest-last.

  Records are emitted on connect, disconnect, and lease expiry. Each record
  carries `hash` (`"sha256:" <> hex` over the Jason encoding of the record
  without its own `hash` field) and `prev_hash` linking to the previous
  record; the first record links to the all-zeros genesis hash.
  """
  @spec attestations() :: [map()]
  def attestations do
    GenServer.call(__MODULE__, :attestations)
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
    # Schedule periodic heartbeat/lease sweeps. The test env stretches the
    # interval (config :burble, :groove_sweep_interval_ms) so tests can send
    # :check_heartbeats directly and observe deterministic sweeps.
    sweep_interval = Application.get_env(:burble, :groove_sweep_interval_ms, @sweep_interval_ms)
    :timer.send_interval(sweep_interval, :check_heartbeats)

    {:ok,
     %{
       queue: :queue.new(),
       depth: 0,
       # Connections: %{session_id => %{peer_id, state, connected_at, last_heartbeat,
       #   manifest, lease, lease_expires_at, missed_windows, ...}}
       connections: %{},
       # Attestation chain, newest-first internally (reversed on read).
       attestations: []
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
  def handle_call(:pop, _from, %{queue: q} = state) do
    messages = :queue.to_list(q)
    {:reply, messages, %{state | queue: :queue.new(), depth: 0}}
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
      case parse_lease(Map.get(peer_manifest, "lease")) do
        {:error, reason} ->
          Logger.info("[Groove] Rejected connection from #{peer_id}: #{reason}")
          {:reply, {:error, reason}, state}

        {:ok, lease} ->
          session_id = generate_session_id()
          now = System.system_time(:millisecond)

          conn_info = %{
            peer_id: peer_id,
            state: :connected,
            connected_at: now,
            last_heartbeat: now,
            matched_capabilities: matched_capabilities,
            manifest: peer_manifest,
            # Lease (SPEC v0.3): nil for legacy (no-lease) connections.
            lease: lease,
            lease_expires_at: if(lease, do: now + lease.ttl_ms, else: nil),
            missed_windows: 0,
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

          new_state =
            %{state | connections: new_connections}
            |> record_attestation("groove:connect", peer_id, matched_capabilities)

          reply = if lease, do: {:ok, session_id, lease}, else: {:ok, session_id}
          {:reply, reply, new_state}
      end
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

        new_state =
          %{state | connections: remaining}
          |> record_attestation(
            "groove:disconnect",
            conn_info.peer_id,
            conn_info.matched_capabilities
          )

        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:heartbeat, session_id}, _from, state) do
    case Map.get(state.connections, session_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      conn_info ->
        now = System.system_time(:millisecond)

        updated =
          %{conn_info | last_heartbeat: now, state: :active}
          |> refresh_lease(now)

        new_connections = Map.put(state.connections, session_id, updated)
        reply =
          case conn_info.lease do
            %{mode: "soft"} -> {:error, :soft_lease}
            _ -> :ok
          end

        {:reply, reply, %{state | connections: new_connections}}
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
           matched_capabilities: info.matched_capabilities,
           lease: info.lease,
           lease_expires_at: info.lease_expires_at,
           missed_windows: info.missed_windows
         }}
      end)

    {:reply, status, state}
  end

  @impl true
  def handle_call(:attestations, _from, state) do
    {:reply, Enum.reverse(state.attestations), state}
  end

  # --- Heartbeat / Lease Monitoring ---

  @impl true
  def handle_info(:check_heartbeats, state) do
    now = System.system_time(:millisecond)

    new_state =
      Enum.reduce(state.connections, state, fn {session_id, info}, acc ->
        sweep_connection(acc, session_id, info, now)
      end)

    {:noreply, new_state}
  end

  # Catch-all for unexpected messages.
  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Sweep: one connection per pass (SPEC v0.3 leases + legacy heartbeats) ---

  # Soft lease: absent any refresh, expire at TTL. Expiry leaves zero
  # provider-side residue (connection removed + queued messages wiped) and is
  # attested with residue: 0.
  defp sweep_connection(state, session_id, %{lease: %{mode: "soft"}} = info, now) do
    if now > info.lease_expires_at do
      expire_lease(state, session_id, info)
    else
      state
    end
  end

  # Hard lease: heartbeats refresh expiry (see refresh_lease/2). Each
  # unrefreshed TTL window advances expiry by one TTL and marks the
  # connection degraded; @lease_max_missed_windows consecutive missed
  # windows degrade through the same soft-expiry path. A connection being
  # actively refreshed is never reaped.
  defp sweep_connection(state, session_id, %{lease: %{mode: "hard"}} = info, now) do
    # Whole missed TTL windows since the lease last expired, measured from
    # wall time (SPEC §4.6): sweep cadence must not stretch or shrink the
    # degradation clock (a 5s sweep over a 1s TTL previously counted one
    # window per sweep pass instead of five).
    missed =
      if now <= info.lease_expires_at,
        do: 0,
        else: div(now - info.lease_expires_at, info.lease.ttl_ms) + 1

    cond do
      missed == 0 ->
        state

      missed >= @lease_max_missed_windows ->
        expire_lease(state, session_id, info)

      true ->
        Logger.warning(
          "[Groove] Peer #{info.peer_id} (session=#{session_id}) missed hard-lease window " <>
            "#{missed}/#{@lease_max_missed_windows}"
        )

        updated = %{
          info
          | state: :degraded,
            missed_windows: missed
        }

        %{state | connections: Map.put(state.connections, session_id, updated)}
    end
  end

  # Legacy (no-lease) connections keep the original heartbeat behaviour.
  defp sweep_connection(state, session_id, info, now) do
    elapsed = now - info.last_heartbeat

    cond do
      # Timed out — transition to DISCONNECTED and remove.
      elapsed > @heartbeat_timeout_ms and info.state == :degraded ->
        Logger.warning(
          "[Groove] Peer #{info.peer_id} (session=#{session_id}) timed out, removing"
        )

        %{state | connections: Map.delete(state.connections, session_id)}

      # Missed heartbeats — transition to DEGRADED.
      elapsed > @heartbeat_timeout_ms ->
        Logger.warning(
          "[Groove] Peer #{info.peer_id} (session=#{session_id}) degraded (no heartbeat for #{elapsed}ms)"
        )

        %{state | connections: Map.put(state.connections, session_id, %{info | state: :degraded})}

      true ->
        state
    end
  end

  # Expire a leased connection: remove the connection state, wipe the peer's
  # queued messages (zero provider-side residue), and attest the expiry.
  defp expire_lease(state, session_id, info) do
    {remaining_queue, remaining_depth} =
      wipe_peer_messages(state.queue, session_id, info.peer_id)

    :telemetry.execute(
      [:burble, :groove, :lease_expired],
      %{count: 1},
      %{peer_id: info.peer_id, session_id: session_id, mode: info.lease.mode}
    )

    Logger.warning(
      "[Groove] Lease expired: #{info.peer_id} (session=#{session_id}, mode=#{info.lease.mode}) — " <>
        "connection and queued messages wiped"
    )

    %{
      state
      | connections: Map.delete(state.connections, session_id),
        queue: remaining_queue,
        depth: remaining_depth
    }
    |> record_attestation(
      "groove:lease-expired",
      info.peer_id,
      info.matched_capabilities,
      %{residue: 0}
    )
  end

  # --- Helpers ---

  # Parse the optional "lease" field from a connect body (SPEC v0.3).
  # Absent lease -> {:ok, nil}: legacy behaviour unchanged.
  defp parse_lease(nil), do: {:ok, nil}

  defp parse_lease(%{"mode" => mode, "ttl_ms" => ttl_ms})
       when mode in ["soft", "hard"] and is_integer(ttl_ms) and ttl_ms > 0 do
    {:ok, %{mode: mode, ttl_ms: ttl_ms}}
  end

  defp parse_lease(_other), do: {:error, "invalid lease"}

  # A refresh resets the lease window: expiry moves to now + ttl_ms and the
  # missed-window count returns to zero, so an actively refreshed connection
  # is never reaped by the sweep.
  defp refresh_lease(%{lease: nil} = conn_info, _now), do: conn_info

  # A soft lease MUST be allowed to expire (SPEC §4.6): a heartbeat updates
  # liveness bookkeeping but never extends the lease.
  defp refresh_lease(%{lease: %{mode: "soft"}} = conn_info, _now), do: conn_info

  defp refresh_lease(%{lease: lease} = conn_info, now) do
    %{conn_info | lease_expires_at: now + lease.ttl_ms, missed_windows: 0}
  end

  # Drop every queued message attributable to the expiring peer. Messages are
  # attributed via their "session_id"/"handle"/"from" fields (string or atom
  # keys) matching the expiring session id or peer id.
  defp wipe_peer_messages(queue, session_id, peer_id) do
    kept =
      queue
      |> :queue.to_list()
      |> Enum.reject(&message_from_peer?(&1, session_id, peer_id))

    {:queue.from_list(kept), length(kept)}
  end

  defp message_from_peer?(message, session_id, peer_id) when is_map(message) do
    Enum.any?(
      [:session_id, "session_id", :handle, "handle", :from, "from"],
      fn key -> Map.get(message, key) in [session_id, peer_id] end
    )
  end

  defp message_from_peer?(_message, _session_id, _peer_id), do: false

  # Append a record to the attestation chain (cap @max_attestation_depth,
  # oldest rotated out first). hash covers the Jason encoding of the record
  # without its own :hash field; prev_hash links to the previous record, and
  # the first record links to the all-zeros genesis hash.
  defp record_attestation(state, event, consumer, capabilities, extra \\ %{}) do
    prev_hash =
      case state.attestations do
        [%{hash: hash} | _rest] -> hash
        [] -> @genesis_hash
      end

    record =
      Map.merge(
        %{
          event: event,
          provider: %{id: @manifest.service_id, version: @manifest.service_version},
          consumer: consumer,
          capabilities: capabilities,
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
          prev_hash: prev_hash
        },
        extra
      )

    hash =
      "sha256:" <>
        Base.encode16(:crypto.hash(:sha256, Jason.encode!(record)), case: :lower)

    record = Map.put(record, :hash, hash)

    %{state | attestations: Enum.take([record | state.attestations], @max_attestation_depth)}
  end

  # Generate a unique session ID (hex-encoded random bytes).
  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.hex_encode32(case: :lower, padding: false)
  end
end
