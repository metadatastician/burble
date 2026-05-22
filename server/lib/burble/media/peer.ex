# SPDX-License-Identifier: MPL-2.0
#
# Burble.Media.Peer — Per-peer WebRTC PeerConnection manager.
#
# Each participant in a voice room gets their own Peer GenServer that
# owns an ExWebRTC.PeerConnection. The Peer:
#
#   1. Creates a recvonly audio transceiver (receives the peer's mic)
#   2. Creates sendonly audio transceivers (one per other peer in the room)
#   3. Forwards received RTP packets to all other peers' sendonly tracks
#   4. Manages SDP offer/answer negotiation (server is always the offerer)
#   5. Handles ICE candidate exchange
#
# Architecture:
#   Browser <-> RoomChannel <-> Peer GenServer <-> ExWebRTC.PeerConnection
#
# The server always initiates offers. When a new peer joins, ALL existing
# peers renegotiate (add a new sendonly track for the newcomer).

defmodule Burble.Media.Peer do
  @moduledoc """
  Per-peer WebRTC PeerConnection for audio SFU.

  Each peer gets one PeerConnection with:
  - 1 recvonly audio transceiver (their microphone)
  - N-1 sendonly audio transceivers (one per other peer in the room)

  RTP packets from each peer are forwarded to all other peers' sendonly tracks.
  """

  use GenServer, restart: :temporary
  require Logger

  alias ExWebRTC.{PeerConnection, MediaStreamTrack, RTPCodecParameters, SessionDescription, ICECandidate}

  @audio_codecs [
    %RTPCodecParameters{
      payload_type: 111,
      mime_type: "audio/opus",
      clock_rate: 48_000,
      channels: 2
    }
  ]

  # SECURITY FIX: Maximum outbound tracks (peers) before rejecting new
  # additions. Each peer P in a room of N peers creates N-1 sendonly
  # transceivers, so total transceivers across all peers is O(N^2).
  # At 50 peers: 2,450 total transceivers; at 100: 9,900. This cap
  # prevents quadratic resource exhaustion in large rooms.
  @max_outbound_peers 50

  # Warning threshold: log when approaching outbound peer limit.
  @outbound_warn_threshold 40

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc "Start a peer process for a participant."
  def start_link(opts) do
    peer_id = Keyword.fetch!(opts, :peer_id)
    GenServer.start_link(__MODULE__, opts, name: via(peer_id))
  end

  @doc "Apply an SDP answer from the client."
  def apply_sdp_answer(peer_id, answer_sdp) do
    GenServer.call(via(peer_id), {:sdp_answer, answer_sdp})
  end

  @doc "Add an ICE candidate from the client."
  def add_ice_candidate(peer_id, candidate_json) do
    GenServer.call(via(peer_id), {:ice_candidate, candidate_json})
  end

  @doc "Notify this peer that a new peer has joined the room."
  def peer_added(peer_id, new_peer_id) do
    GenServer.cast(via(peer_id), {:peer_added, new_peer_id})
  end

  @doc "Notify this peer that a peer has left the room."
  def peer_removed(peer_id, removed_peer_id) do
    GenServer.cast(via(peer_id), {:peer_removed, removed_peer_id})
  end

  @doc "Forward an RTP packet to this peer's sendonly track for a specific source peer."
  def forward_rtp(peer_id, from_peer_id, packet) do
    GenServer.cast(via(peer_id), {:forward_rtp, from_peer_id, packet})
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    peer_id = Keyword.fetch!(opts, :peer_id)
    room_id = Keyword.fetch!(opts, :room_id)
    channel_pid = Keyword.fetch!(opts, :channel_pid)
    existing_peers = Keyword.get(opts, :existing_peers, [])

    ice_servers = Keyword.get(opts, :ice_servers, Burble.Network.TurnCredentials.ice_servers(peer_id))

    # Create PeerConnection.
    {:ok, pc} = PeerConnection.start_link(
      ice_servers: ice_servers,
      audio_codecs: @audio_codecs,
      video_codecs: []
    )

    # Recvonly transceiver — receives this peer's microphone audio.
    {:ok, recv_tr} = PeerConnection.add_transceiver(pc, :audio, direction: :recvonly)

    # Sendonly transceivers — one per existing peer (to forward their audio to this peer).
    outbound_tracks =
      Map.new(existing_peers, fn existing_id ->
        {track, tr_id} = add_sendonly_track(pc)
        {existing_id, %{track_id: track.id, transceiver_id: tr_id}}
      end)

    state = %{
      peer_id: peer_id,
      room_id: room_id,
      channel_pid: channel_pid,
      pc: pc,
      recv_transceiver: recv_tr,
      recv_track_id: nil,
      outbound_tracks: outbound_tracks,
      pending_peers: [],
      negotiating: false,
      # Pipeline pid for this peer — looked up lazily on first RTP packet.
      # Used to forward RTP timestamps for Phase 4 PTP correlation.
      pipeline_pid: nil
    }

    # Generate initial offer.
    send(self(), :send_offer)

    Logger.info("[Peer] Started for #{peer_id} in room #{room_id} (#{length(existing_peers)} existing peers)")
    {:ok, state}
  end

  @impl true
  def handle_info(:send_offer, state) do
    state = send_offer(state)
    {:noreply, state}
  end

  # ExWebRTC messages from the PeerConnection process.

  @impl true
  def handle_info({:ex_webrtc, pc, {:ice_candidate, candidate}}, %{pc: pc} = state) do
    # Forward ICE candidate to client via channel. channel_pid may be nil in
    # tests; skip in that case (see send_offer/1 comment).
    json = candidate |> ICECandidate.to_json() |> Jason.encode!()
    if is_pid(state.channel_pid) do
      send(state.channel_pid, {:peer_ice_candidate, json})
    end
    {:noreply, state}
  end

  @impl true
  def handle_info({:ex_webrtc, pc, {:connection_state_change, :connected}}, %{pc: pc} = state) do
    Logger.info("[Peer] #{state.peer_id} WebRTC connected")
    # Report connection success to health mesh
    Burble.Groove.HealthMesh.report_peer_status(state.peer_id, :up, %{type: :webrtc, room: state.room_id})
    {:noreply, state}
  end

  @impl true
  def handle_info({:ex_webrtc, pc, {:connection_state_change, :failed}}, %{pc: pc} = state) do
    Logger.warning("[Peer] #{state.peer_id} WebRTC connection failed")
    # Report connection failure to health mesh
    Burble.Groove.HealthMesh.report_peer_status(state.peer_id, :down, %{type: :webrtc, room: state.room_id})
    {:noreply, state}
  end

  @impl true
  def handle_info({:ex_webrtc, pc, {:connection_state_change, new_state}}, %{pc: pc} = state) do
    Logger.debug("[Peer] #{state.peer_id} connection state: #{new_state}")
    # Report intermediate states
    status = case new_state do
      :connecting -> :degraded
      :disconnected -> :down
      _ -> :degraded
    end
    Burble.Groove.HealthMesh.report_peer_status(state.peer_id, status, %{type: :webrtc, room: state.room_id})
    {:noreply, state}
  end

  @impl true
  def handle_info({:ex_webrtc, pc, {:track, track}}, %{pc: pc} = state) do
    # Remote track added — this is the peer's audio input.
    Logger.info("[Peer] #{state.peer_id} remote track: #{track.id}")
    {:noreply, %{state | recv_track_id: track.id}}
  end

  @impl true
  def handle_info({:ex_webrtc, pc, {:rtp, track_id, _rid, packet}}, %{pc: pc} = state) do
    # Received RTP from this peer — forward to all other peers in the room.
    state =
      if track_id == state.recv_track_id do
        Burble.Media.Engine.distribute_rtp(state.room_id, state.peer_id, packet)
        # Propagate RTP timestamp to the pipeline for Phase 4 PTP correlation.
        # Resolve pipeline pid lazily so we don't fail if pipeline hasn't started.
        pipeline_pid = state.pipeline_pid || resolve_pipeline(state.peer_id)

        if pipeline_pid do
          Burble.Coprocessor.Pipeline.record_rtp_timestamp(pipeline_pid, packet.timestamp)
        end

        # Feed the correlator with a simultaneous RTP+wall-clock observation.
        # Prefer the PTP hardware clock; fall back to monotonic time.
        wall_ns =
          case Burble.Coprocessor.ZigBackend.ptp_read_clock() do
            {:ok, ns} -> ns
            {:error, _} -> :erlang.monotonic_time(:nanosecond)
          end

        Burble.Timing.ClockCorrelator.record_sync_point(
          Burble.Timing.ClockCorrelator,
          packet.timestamp,
          wall_ns
        )

        # Propagate local node's observation into the multi-node alignment
        # registry so that other nodes in the same room can compute clock offsets
        # relative to this node (Phase 4 PTP multi-node playout alignment).
        Burble.Timing.Alignment.report_node_sync(node(), packet.timestamp, wall_ns)

        %{state | pipeline_pid: pipeline_pid}
      else
        state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({:ex_webrtc, _pc, _msg}, state) do
    # Catch-all for unhandled PeerConnection messages.
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # SDP answer from client
  # ---------------------------------------------------------------------------

  @impl true
  def handle_call({:sdp_answer, answer_sdp}, _from, %{pc: pc} = state) do
    answer = %SessionDescription{type: :answer, sdp: answer_sdp}

    case PeerConnection.set_remote_description(pc, answer) do
      :ok ->
        # Process any peers that joined while we were negotiating.
        state = %{state | negotiating: false}
        state = process_pending_peers(state)
        {:reply, :ok, state}

      {:error, reason} ->
        Logger.warning("[Peer] #{state.peer_id} SDP answer failed: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  # ---------------------------------------------------------------------------
  # ICE candidate from client
  # ---------------------------------------------------------------------------

  @impl true
  def handle_call({:ice_candidate, candidate_json}, _from, %{pc: pc} = state) do
    case Jason.decode(candidate_json) do
      {:ok, decoded} ->
        candidate = ICECandidate.from_json(decoded)

        case PeerConnection.add_ice_candidate(pc, candidate) do
          :ok -> {:reply, :ok, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:error, _} ->
        {:reply, {:error, :invalid_json}, state}
    end
  end

  # ---------------------------------------------------------------------------
  # Peer added/removed
  # ---------------------------------------------------------------------------

  @impl true
  def handle_cast({:peer_added, new_peer_id}, state) do
    if state.negotiating do
      # Queue — can't renegotiate while waiting for SDP answer.
      {:noreply, %{state | pending_peers: state.pending_peers ++ [new_peer_id]}}
    else
      state = add_outbound_peer(state, new_peer_id)
      state = send_offer(state)
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:peer_removed, removed_peer_id}, state) do
    state = remove_outbound_peer(state, removed_peer_id)

    unless state.negotiating do
      state = send_offer(state)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  # ---------------------------------------------------------------------------
  # RTP forwarding
  # ---------------------------------------------------------------------------

  @impl true
  def handle_cast({:forward_rtp, from_peer_id, packet}, %{pc: pc} = state) do
    case Map.get(state.outbound_tracks, from_peer_id) do
      %{track_id: track_id, transceiver_id: transceiver_id} ->
        # Forward RTP packet through the transceiver's sender
        # In ex_webrtc, we send RTP packets via the transceiver
        case PeerConnection.send_rtp(pc, transceiver_id, packet) do
          :ok -> :ok
          {:error, reason} ->
            Logger.warning("[Peer] #{state.peer_id} failed to forward RTP to #{from_peer_id}: #{reason}")
        end

        # Also send via multipath for line bonding (if available)
        case Burble.Transport.Multipath.send(:voice, {state.peer_id, from_peer_id}, packet) do
          :ok -> :ok
          {:error, mp_reason} ->
            Logger.debug("[Peer] #{state.peer_id} multipath send failed: #{mp_reason}")
        end

      nil ->
        Logger.debug("[Peer] #{state.peer_id} no outbound track for #{from_peer_id}")
    end

    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp via(peer_id) do
    {:via, Registry, {Burble.PeerRegistry, peer_id}}
  end

  # Look up the pipeline GenServer for this peer via the CoprocessorRegistry.
  # Returns the pid if found, nil if not yet started (non-fatal).
  defp resolve_pipeline(peer_id) do
    case Registry.lookup(Burble.CoprocessorRegistry, peer_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp add_sendonly_track(pc) do
    stream_id = MediaStreamTrack.generate_stream_id()
    track = MediaStreamTrack.new(:audio, [stream_id])
    {:ok, tr} = PeerConnection.add_transceiver(pc, track, direction: :sendonly)
    {track, tr.id}
  end

  defp add_outbound_peer(state, new_peer_id) do
    outbound_count = map_size(state.outbound_tracks)

    # SECURITY FIX: Validate room size before adding outbound tracks.
    # Each peer creates N-1 sendonly transceivers, so total transceivers
    # across all peers in a room is O(N^2). Without a cap, a room with
    # hundreds of peers causes quadratic resource growth in WebRTC
    # transceiver objects, SDP size, and RTP forwarding load.
    cond do
      outbound_count >= @max_outbound_peers ->
        Logger.error(
          "[Peer] #{state.peer_id} in room #{state.room_id}: outbound peer " <>
          "limit reached (#{outbound_count}/#{@max_outbound_peers}), " <>
          "rejecting new peer #{new_peer_id}"
        )
        state

      outbound_count >= @outbound_warn_threshold ->
        Logger.warning(
          "[Peer] #{state.peer_id} in room #{state.room_id}: approaching " <>
          "outbound peer limit (#{outbound_count}/#{@max_outbound_peers})"
        )
        {track, tr_id} = add_sendonly_track(state.pc)
        outbound = Map.put(state.outbound_tracks, new_peer_id, %{track_id: track.id, transceiver_id: tr_id})
        %{state | outbound_tracks: outbound}

      true ->
        {track, tr_id} = add_sendonly_track(state.pc)
        outbound = Map.put(state.outbound_tracks, new_peer_id, %{track_id: track.id, transceiver_id: tr_id})
        %{state | outbound_tracks: outbound}
    end
  end

  defp remove_outbound_peer(state, removed_peer_id) do
    case Map.pop(state.outbound_tracks, removed_peer_id) do
      {%{transceiver_id: tr_id}, remaining} ->
        PeerConnection.stop_transceiver(state.pc, tr_id)
        %{state | outbound_tracks: remaining}

      {nil, _} ->
        state
    end
  end

  defp send_offer(%{pc: pc} = state) do
    {:ok, offer} = PeerConnection.create_offer(pc)
    :ok = PeerConnection.set_local_description(pc, offer)

    # Send offer to client via channel. channel_pid may be nil in tests that
    # exercise Media.Engine without a real Phoenix channel; skip silently in
    # that case rather than raising :badarg from :erlang.send(nil, _).
    if is_pid(state.channel_pid) do
      send(state.channel_pid, {:peer_sdp_offer, offer.sdp})
    end

    %{state | negotiating: true}
  end

  defp process_pending_peers(%{pending_peers: []} = state), do: state
  defp process_pending_peers(%{pending_peers: [next | rest]} = state) do
    state = %{state | pending_peers: rest}
    state = add_outbound_peer(state, next)
    send_offer(state)
  end
end
