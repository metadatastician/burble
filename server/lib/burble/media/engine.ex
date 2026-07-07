# SPDX-License-Identifier: MPL-2.0
#
# Burble.Media.Engine — session registry for the ex_webrtc-based SFU.
#
# The media plane is isolated from the control plane. This module
# tracks one media session per active voice room; the actual WebRTC
# peer connections (ICE/DTLS/RTP) live in Burble.Media.Peer (ex_webrtc).
#
# Architecture:
#   Control plane (rooms, auth, permissions) runs in the main OTP app.
#   Media plane (audio routing, mixing, recording) runs here.
#   They communicate via PubSub events, not direct calls.
#
# Privacy layers (applied in order):
#   Layer 0: SFU — peers never connect directly, only to server
#   Layer 1: TURN-only — no ICE host/srflx candidates, IP hidden
#   Layer 2: E2EE — Insertable Streams, server forwards opaque frames
#   Layer 3: WebTransport — QUIC upgrade when supported (future)
#   Layer 4: MoQ — Media over QUIC migration (future, when spec stabilises)
#
# Codec: Opus (mandatory), 48kHz, mono for voice, stereo for music mode.
# Bitrate: 24-64 kbps adaptive (voice), 96-128 kbps (music mode).

defmodule Burble.Media.Engine do
  @moduledoc """
  Session registry for Burble's ex_webrtc-based Selective Forwarding Unit (SFU).

  Manages one media session per active voice room and fans RTP out between
  peers. Per-peer WebRTC connections are `Burble.Media.Peer` processes
  (`ExWebRTC.PeerConnection`). All audio is forwarded (not mixed) to
  preserve E2EE capability.

  ## SFU vs MCU

  We use SFU (Selective Forwarding Unit), not MCU (Multipoint Control Unit):
  - SFU forwards encrypted packets without decoding — enables E2EE
  - MCU would need to decode, mix, re-encode — breaks E2EE
  - SFU scales better (no server-side transcoding)
  - Trade-off: clients do N-1 decodes instead of 1, but modern devices handle this easily for voice
  """

  use GenServer

  require Logger

  # ── Types ──

  @type room_id :: String.t()
  @type peer_id :: String.t()

  @type media_config :: %{
          codec: :opus,
          sample_rate: 48_000,
          channels: 1 | 2,
          bitrate_kbps: 24..128,
          dtx: boolean(),
          fec: boolean()
        }

  @type privacy_mode :: :standard | :turn_only | :e2ee | :maximum

  # ── Client API ──

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Create a media session for a room.

  Registers a media session that tracks the WebRTC peers
  (`Burble.Media.Peer` processes) for the room.
  """
  def create_room_session(room_id, opts \\ []) do
    GenServer.call(__MODULE__, {:create_session, room_id, opts})
  end

  @doc """
  Destroy a media session when a room closes.
  """
  def destroy_room_session(room_id) do
    GenServer.call(__MODULE__, {:destroy_session, room_id})
  end

  @doc """
  Add a peer to a room's media session.

  Returns WebRTC signaling data (SDP offer) for the client.
  The offer is privacy-hardened based on the room's privacy mode.
  """
  def add_peer(room_id, peer_id, opts \\ []) do
    GenServer.call(__MODULE__, {:add_peer, room_id, peer_id, opts})
  end

  @doc """
  Remove a peer from a room's media session.
  """
  def remove_peer(room_id, peer_id) do
    GenServer.call(__MODULE__, {:remove_peer, room_id, peer_id})
  end

  @doc """
  Handle an incoming WebRTC signaling message (SDP answer, ICE candidate).
  """
  def handle_signal(room_id, peer_id, signal) do
    GenServer.call(__MODULE__, {:signal, room_id, peer_id, signal})
  end

  @doc """
  Set per-peer audio properties (mute relay, volume scaling).
  """
  def set_peer_audio(room_id, peer_id, audio_opts) do
    GenServer.call(__MODULE__, {:set_audio, room_id, peer_id, audio_opts})
  end

  @doc """
  Get media health metrics for a room.
  """
  def get_room_health(room_id) do
    GenServer.call(__MODULE__, {:health, room_id})
  end

  @doc """
  Distribute an RTP packet from one peer to all other peers in the room.

  Called by Peer GenServers when they receive audio from their client.
  The Engine looks up the room, finds all other peers, and forwards
  the packet to each one's sendonly track.
  """
  def distribute_rtp(room_id, from_peer_id, packet) do
    GenServer.cast(__MODULE__, {:distribute_rtp, room_id, from_peer_id, packet})
  end

  # ── Server Callbacks ──

  @impl true
  def init(_opts) do
    state = %{
      # room_id => %{peers, config, privacy_mode, created_at}
      sessions: %{},
      # Global media config defaults
      default_config: default_media_config(),
      # Privacy mode (can be overridden per room)
      default_privacy: :turn_only
    }

    Logger.info("[Burble.Media.Engine] Started — SFU mode, TURN-only default")
    {:ok, state}
  end

  @impl true
  def handle_call({:create_session, room_id, opts}, _from, state) do
    if Map.has_key?(state.sessions, room_id) do
      {:reply, {:error, :session_exists}, state}
    else
      privacy_mode = Keyword.get(opts, :privacy, state.default_privacy)
      config = Keyword.get(opts, :config, state.default_config)

      session = %{
        room_id: room_id,
        peers: %{},
        config: config,
        privacy_mode: privacy_mode,
        created_at: DateTime.utc_now()
      }

      new_sessions = Map.put(state.sessions, room_id, session)
      Logger.info("[Media] Session created: #{room_id} (privacy: #{privacy_mode})")

      {:reply, {:ok, room_id}, %{state | sessions: new_sessions}}
    end
  end

  @impl true
  def handle_call({:destroy_session, room_id}, _from, state) do
    case Map.pop(state.sessions, room_id) do
      {nil, _} ->
        {:reply, {:error, :no_session}, state}

      {_session, remaining} ->
        Logger.info("[Media] Session destroyed: #{room_id}")
        {:reply, :ok, %{state | sessions: remaining}}
    end
  end

  @impl true
  def handle_call({:add_peer, room_id, peer_id, opts}, _from, state) do
    case Map.get(state.sessions, room_id) do
      nil ->
        {:reply, {:error, :no_session}, state}

      session ->
        e2ee_enabled = session.privacy_mode in [:e2ee, :maximum]
        e2ee_key = if e2ee_enabled, do: Keyword.get(opts, :e2ee_key), else: nil
        channel_pid = Keyword.get(opts, :channel_pid)

        peer = %{
          id: peer_id,
          joined_at: DateTime.utc_now(),
          muted: Keyword.get(opts, :muted, false),
          e2ee_enabled: e2ee_enabled
        }

        # Start WebRTC Peer GenServer for this participant.
        existing_peer_ids = Map.keys(session.peers)
        peer_opts = [
          peer_id: peer_id,
          room_id: room_id,
          channel_pid: channel_pid,
          existing_peers: existing_peer_ids,
          ice_servers: ice_servers_for_mode(session.privacy_mode)
        ]

        # Defensive: a DynamicSupervisor that has hit max_restarts intensity
        # exits :shutdown, which would propagate out of GenServer.call and
        # bring Burble.Media.Engine down. Catch :exit here so a sibling
        # supervisor's death cannot topple the engine. The session state is
        # still updated below so callers see consistent {:ok, offer} return
        # values whether or not the Peer process started.
        peer_start_result =
          try do
            DynamicSupervisor.start_child(
              Burble.PeerSupervisor,
              {Burble.Media.Peer, peer_opts}
            )
          catch
            :exit, reason -> {:error, {:peer_supervisor_unavailable, reason}}
          end

        case peer_start_result do
          {:ok, _pid} ->
            Logger.info("[Media] Peer process started for #{peer_id}")

          {:error, reason} ->
            Logger.warning("[Media] Peer process failed for #{peer_id}: #{inspect(reason)}")
        end

        # Notify all existing peers about the new participant.
        Enum.each(existing_peer_ids, fn existing_id ->
          Burble.Media.Peer.peer_added(existing_id, peer_id)
        end)

        # Start coprocessor pipeline for this peer.
        pipeline_opts = [
          peer_id: peer_id,
          e2ee_key: e2ee_key,
          config: %{
            sample_rate: session.config.sample_rate,
            channels: session.config.channels,
            bitrate: session.config.bitrate_kbps * 1000,
            noise_gate_db: -40.0,
            echo_cancel_taps: 128,
            e2ee_enabled: e2ee_enabled,
            neural_denoise: true
          }
        ]

        pipeline_start_result =
          try do
            DynamicSupervisor.start_child(
              Burble.CoprocessorSupervisor,
              {Burble.Coprocessor.Pipeline, pipeline_opts}
            )
          catch
            :exit, reason -> {:error, {:coprocessor_supervisor_unavailable, reason}}
          end

        case pipeline_start_result do
          {:ok, _pid} ->
            Logger.info("[Media] Pipeline started for peer #{peer_id}")

          {:error, reason} ->
            Logger.warning("[Media] Pipeline failed for peer #{peer_id}: #{inspect(reason)}")
        end

        updated_session = %{session | peers: Map.put(session.peers, peer_id, peer)}
        new_sessions = Map.put(state.sessions, room_id, updated_session)

        # Generate privacy-hardened SDP offer
        offer = generate_offer(session.privacy_mode, session.config)

        Logger.info("[Media] Peer added: #{peer_id} → #{room_id}")
        {:reply, {:ok, offer}, %{state | sessions: new_sessions}}
    end
  end

  @impl true
  def handle_call({:remove_peer, room_id, peer_id}, _from, state) do
    case Map.get(state.sessions, room_id) do
      nil ->
        {:reply, {:error, :no_session}, state}

      session ->
        # Stop the WebRTC Peer GenServer.
        case Registry.lookup(Burble.PeerRegistry, peer_id) do
          [{pid, _}] -> GenServer.stop(pid, :normal)
          _ -> :ok
        end

        # Notify remaining peers.
        remaining_ids = session.peers |> Map.delete(peer_id) |> Map.keys()
        Enum.each(remaining_ids, fn other_id ->
          Burble.Media.Peer.peer_removed(other_id, peer_id)
        end)

        # Stop the coprocessor pipeline.
        case Registry.lookup(Burble.CoprocessorRegistry, peer_id) do
          [{pid, _}] -> Burble.Coprocessor.Pipeline.stop(pid)
          _ -> :ok
        end

        updated_session = %{session | peers: Map.delete(session.peers, peer_id)}
        new_sessions = Map.put(state.sessions, room_id, updated_session)
        Logger.info("[Media] Peer removed: #{peer_id} ← #{room_id}")
        {:reply, :ok, %{state | sessions: new_sessions}}
    end
  end

  @impl true
  def handle_call({:signal, room_id, peer_id, signal}, _from, state) do
    case Map.get(state.sessions, room_id) do
      nil ->
        {:reply, {:error, :no_session}, state}

      session ->
        if Map.has_key?(session.peers, peer_id) do
          # Route signaling to the Peer GenServer which owns the
          # ExWebRTC PeerConnection for this participant.
          result =
            case signal do
              %{"type" => "answer", "sdp" => sdp} ->
                Burble.Media.Peer.apply_sdp_answer(peer_id, sdp)

              %{"candidate" => _} ->
                candidate_json = Jason.encode!(signal)
                Burble.Media.Peer.add_ice_candidate(peer_id, candidate_json)

              _ ->
                Logger.warning("[Media] Unknown signal type from #{peer_id}: #{inspect(signal)}")
                {:error, :unknown_signal}
            end

          {:reply, {:ok, result}, state}
        else
          {:reply, {:error, :peer_not_found}, state}
        end
    end
  end

  @impl true
  def handle_call({:set_audio, room_id, peer_id, audio_opts}, _from, state) do
    case get_in(state, [:sessions, room_id, :peers, peer_id]) do
      nil ->
        {:reply, {:error, :peer_not_found}, state}

      peer ->
        updated_peer = Map.merge(peer, Map.new(audio_opts))

        new_state =
          put_in(state, [:sessions, room_id, :peers, peer_id], updated_peer)

        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:health, room_id}, _from, state) do
    case Map.get(state.sessions, room_id) do
      nil ->
        {:reply, {:error, :no_session}, state}

      session ->
        health = %{
          room_id: room_id,
          peer_count: map_size(session.peers),
          privacy_mode: session.privacy_mode,
          uptime_seconds: DateTime.diff(DateTime.utc_now(), session.created_at),
          codec: session.config.codec,
          bitrate: session.config.bitrate_kbps
        }

        {:reply, {:ok, health}, state}
    end
  end

  # ── Private ──

  defp default_media_config do
    %{
      codec: :opus,
      sample_rate: 48_000,
      channels: 1,
      bitrate_kbps: 32,
      dtx: true,
      fec: true
    }
  end

  @doc false
  def generate_offer(privacy_mode, config) do
    # Real SDP offers are created per-peer by Burble.Media.Peer (ex_webrtc);
    # this returns the session-level negotiation parameters only.
    # Privacy hardening is applied via Burble.Media.Privacy.
    offer = %{
      type: :offer,
      privacy_mode: privacy_mode,
      codec: config.codec,
      ice_policy: ice_policy(privacy_mode),
      e2ee: privacy_mode in [:e2ee, :maximum],
      # Real SDP is generated per-peer by Burble.Media.Peer (ex_webrtc)
      sdp: nil,
      # CSP headers for WebRTC connections.
      csp_headers: Burble.Media.Privacy.csp_headers(privacy_mode)
    }

    offer
  end

  # SECURITY FIX: Maximum mailbox size before RTP distribution backs off.
  # Without this check, a sustained high RTP packet rate (e.g., many rooms
  # with many peers) can cause the Engine's mailbox to grow unboundedly,
  # leading to OOM. When the mailbox exceeds this threshold, log a warning
  # and skip distribution for this packet to allow the mailbox to drain.
  @max_mailbox_size 5_000

  # SECURITY FIX: Warn threshold for mailbox growth (80% of max).
  @mailbox_warn_threshold trunc(@max_mailbox_size * 0.8)

  @impl true
  def handle_cast({:distribute_rtp, room_id, from_peer_id, packet}, state) do
    # SECURITY FIX: Monitor mailbox size before doing fanout work. If the
    # mailbox has grown too large, skip this distribution round to let
    # the GenServer drain its queue. This is a backpressure mechanism
    # that prevents OOM from sustained high RTP traffic.
    {:message_queue_len, mailbox_len} = Process.info(self(), :message_queue_len)

    cond do
      mailbox_len > @max_mailbox_size ->
        # Critical: mailbox is too large. Drop this packet to relieve pressure.
        Logger.error(
          "[Engine] Mailbox overflow (#{mailbox_len} > #{@max_mailbox_size}), " <>
          "dropping RTP distribution for room #{room_id}"
        )

      mailbox_len > @mailbox_warn_threshold ->
        # Warning: approaching limit. Still forward, but log.
        Logger.warning(
          "[Engine] Mailbox high (#{mailbox_len}/#{@max_mailbox_size}), " <>
          "room #{room_id} — consider load shedding"
        )
        distribute_to_peers(state, room_id, from_peer_id, packet)

      true ->
        distribute_to_peers(state, room_id, from_peer_id, packet)
    end

    {:noreply, state}
  end

  # SECURITY FIX: Handle auto-unmute timer messages from the moderation
  # system. This replaces the old Task.start-per-mute pattern, which
  # spawned and held one BEAM process per timed mute for the full duration.
  # Process.send_after is lightweight (no process held) and the unmute
  # logic runs in the existing Engine GenServer process.
  @impl true
  def handle_info({:auto_unmute, user_id, room_id}, state) do
    case Map.get(state.sessions, room_id) do
      nil ->
        # Room no longer exists; nothing to unmute.
        Logger.debug("[Engine] Auto-unmute: room #{room_id} no longer exists")

      _session ->
        # Unmute the peer and broadcast the event.
        __MODULE__.set_peer_audio(room_id, user_id, muted: false)

        Phoenix.PubSub.broadcast(
          Burble.PubSub,
          "room:#{room_id}",
          {:moderation, :unmuted, %{target_id: user_id, reason: "Timeout expired"}}
        )

        Logger.info("[Engine] Auto-unmute fired for #{user_id} in #{room_id}")
    end

    {:noreply, state}
  end

  # Forward an RTP packet to all peers in a room except the sender.
  # Extracted as a helper for the distribute_rtp handler to keep the
  # mailbox-monitoring logic readable.
  @spec distribute_to_peers(map(), String.t(), String.t(), binary()) :: :ok
  defp distribute_to_peers(state, room_id, from_peer_id, packet) do
    case Map.get(state.sessions, room_id) do
      nil ->
        :ok

      session ->
        session.peers
        |> Map.keys()
        |> Enum.reject(fn id -> id == from_peer_id end)
        |> Enum.each(fn peer_id ->
          Burble.Media.Peer.forward_rtp(peer_id, from_peer_id, packet)
        end)
    end
  end

  defp ice_policy(:standard), do: :all
  defp ice_policy(:turn_only), do: :relay
  defp ice_policy(:e2ee), do: :relay
  defp ice_policy(:maximum), do: :relay

  # ICE servers for each privacy mode.
  defp ice_servers_for_mode(:standard) do
    [%{urls: "stun:stun.l.google.com:19302"}]
  end
  defp ice_servers_for_mode(:turn_only) do
    turn_config()
  end
  defp ice_servers_for_mode(:e2ee) do
    turn_config()
  end
  defp ice_servers_for_mode(:maximum) do
    turn_config()
  end

  defp turn_config do
    # TURN server for relay-only modes.
    # In production, set BURBLE_TURN_URL, BURBLE_TURN_USER, BURBLE_TURN_PASS.
    url = System.get_env("BURBLE_TURN_URL") || "turn:localhost:3478"
    user = System.get_env("BURBLE_TURN_USER") || "burble"
    pass = System.get_env("BURBLE_TURN_PASS") || "burble_turn_secret"

    [
      %{urls: url, username: user, credential: pass},
      %{urls: "stun:stun.l.google.com:19302"}
    ]
  end
end
