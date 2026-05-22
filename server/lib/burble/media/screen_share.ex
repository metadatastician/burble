# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Burble.Media.ScreenShare — Screen sharing via WebRTC SFU relay.
#
# Architecture:
#   - Client calls getDisplayMedia to capture screen/window/tab.
#   - The captured MediaStream is sent to the Burble SFU as a separate
#     WebRTC track (video), distinct from the voice audio track.
#   - The SFU forwards the screen share stream to all other peers in
#     the room (same relay model as voice, different media type).
#
# Constraints:
#   - One active screen share per room at a time.
#   - First-come basis: the first peer to start sharing gets the slot.
#   - Moderators can take over (force-stop the current share and start theirs).
#   - Resolution capped at 1080p, 15fps default (configurable per room).
#   - Start/stop via Phoenix channel messages ("screen_share:start", "screen_share:stop").
#
# Privacy:
#   - Screen share follows the same privacy mode as voice (TURN-only, E2EE, etc.).
#   - In E2EE mode, the video frames are encrypted via Insertable Streams
#     before being sent — the SFU forwards opaque encrypted frames.

defmodule Burble.Media.ScreenShare do
  @moduledoc """
  Manages screen sharing state for Burble voice rooms.

  One active screen share per room. The SFU relays the video stream
  to all peers. Moderators can force-take the screen share slot.

  ## Channel Messages

  Incoming (client → server):
    - `"screen_share:start"` — Request to start sharing.
    - `"screen_share:stop"`  — Stop current share.
    - `"screen_share:signal"` — WebRTC signaling for the screen share track.

  Outgoing (server → client):
    - `"screen_share:started"` — Broadcast: sharing began (includes sharer peer_id).
    - `"screen_share:stopped"` — Broadcast: sharing ended.
    - `"screen_share:offer"`   — SDP offer for screen share track.
    - `"screen_share:error"`   — Error message (e.g. slot taken).
  """

  use GenServer

  require Logger

  # ── Types ──

  @typedoc "Default screen share video constraints."
  @type video_constraints :: %{
          max_width: pos_integer(),
          max_height: pos_integer(),
          max_framerate: pos_integer()
        }

  @typedoc "Per-room screen share state."
  @type share_state :: %{
          sharer_peer_id: String.t(),
          started_at: DateTime.t(),
          constraints: video_constraints()
        }

  @typedoc "Internal GenServer state: maps room_id to active share."
  @type state :: %{
          shares: %{String.t() => share_state()},
          default_constraints: video_constraints()
        }

  # ── Default Configuration ──

  @default_constraints %{
    max_width: 1920,
    max_height: 1080,
    max_framerate: 15
  }

  # ── Client API ──

  @doc "Start the ScreenShare manager."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Start screen sharing in a room.

  Returns `{:ok, constraints}` if the slot is available or the requester
  is a moderator taking over. Returns `{:error, :slot_taken}` if another
  peer is already sharing and the requester lacks moderator privileges.

  ## Parameters

    - `room_id` — The room to share in.
    - `peer_id` — The peer requesting to share.
    - `opts` — Keyword list:
      - `:is_moderator` (boolean) — Whether the peer is a moderator.
      - `:constraints` (map) — Override default video constraints.
  """
  def start_share(room_id, peer_id, opts \\ []) do
    GenServer.call(__MODULE__, {:start_share, room_id, peer_id, opts})
  end

  @doc """
  Stop screen sharing in a room.

  Only the current sharer or a moderator can stop the share.
  Returns `:ok` on success, `{:error, reason}` on failure.
  """
  def stop_share(room_id, peer_id, opts \\ []) do
    GenServer.call(__MODULE__, {:stop_share, room_id, peer_id, opts})
  end

  @doc """
  Get the current screen share state for a room.

  Returns `{:ok, share_state}` if active, `{:error, :no_share}` otherwise.
  """
  def get_share(room_id) do
    GenServer.call(__MODULE__, {:get_share, room_id})
  end

  @doc """
  Handle WebRTC signaling for the screen share track.

  Forwards the signal through the media engine for the screen share
  PeerConnection (separate from voice).
  """
  def handle_signal(room_id, peer_id, signal) do
    GenServer.call(__MODULE__, {:signal, room_id, peer_id, signal})
  end

  @doc """
  Clean up screen share state when a peer disconnects.

  Called by the room/presence system when a peer leaves. If the
  departing peer was the active sharer, the share is stopped and
  a `screen_share:stopped` event is broadcast.
  """
  def peer_disconnected(room_id, peer_id) do
    GenServer.cast(__MODULE__, {:peer_disconnected, room_id, peer_id})
  end

  @doc """
  Clean up all screen share state when a room is destroyed.
  """
  def room_destroyed(room_id) do
    GenServer.cast(__MODULE__, {:room_destroyed, room_id})
  end

  # ── Server Callbacks ──

  @impl true
  def init(_opts) do
    state = %{
      shares: %{},
      default_constraints: @default_constraints
    }

    Logger.info("[Burble.Media.ScreenShare] Started — 1 share per room, 1080p/15fps default")
    {:ok, state}
  end

  @impl true
  def handle_call({:start_share, room_id, peer_id, opts}, _from, state) do
    is_moderator = Keyword.get(opts, :is_moderator, false)
    constraints = Keyword.get(opts, :constraints, state.default_constraints)

    # Merge with defaults to ensure all fields are present.
    merged_constraints = Map.merge(state.default_constraints, constraints)

    # Cap at 1080p regardless of what the client requests.
    capped_constraints = cap_constraints(merged_constraints)

    case Map.get(state.shares, room_id) do
      nil ->
        # Slot is free — grant it.
        share = %{
          sharer_peer_id: peer_id,
          started_at: DateTime.utc_now(),
          constraints: capped_constraints
        }

        new_state = %{state | shares: Map.put(state.shares, room_id, share)}

        # Broadcast to the room that screen sharing started.
        Phoenix.PubSub.broadcast(
          Burble.PubSub,
          "room:#{room_id}",
          {:screen_share_started, peer_id, capped_constraints}
        )

        Logger.info("[ScreenShare] Started: peer=#{peer_id} room=#{room_id}")
        {:reply, {:ok, capped_constraints}, new_state}

      %{sharer_peer_id: current_sharer} when current_sharer == peer_id ->
        # Already sharing — return current constraints (idempotent).
        {:reply, {:ok, capped_constraints}, state}

      %{sharer_peer_id: current_sharer} when is_moderator ->
        # Moderator takeover — stop current share, start new one.
        Logger.info(
          "[ScreenShare] Moderator takeover: #{peer_id} replacing #{current_sharer} in room=#{room_id}"
        )

        # Notify the displaced sharer.
        Phoenix.PubSub.broadcast(
          Burble.PubSub,
          "room:#{room_id}",
          {:screen_share_stopped, current_sharer, :moderator_takeover}
        )

        share = %{
          sharer_peer_id: peer_id,
          started_at: DateTime.utc_now(),
          constraints: capped_constraints
        }

        new_state = %{state | shares: Map.put(state.shares, room_id, share)}

        Phoenix.PubSub.broadcast(
          Burble.PubSub,
          "room:#{room_id}",
          {:screen_share_started, peer_id, capped_constraints}
        )

        {:reply, {:ok, capped_constraints}, new_state}

      _existing ->
        # Slot taken and requester is not a moderator.
        {:reply, {:error, :slot_taken}, state}
    end
  end

  @impl true
  def handle_call({:stop_share, room_id, peer_id, opts}, _from, state) do
    is_moderator = Keyword.get(opts, :is_moderator, false)

    case Map.get(state.shares, room_id) do
      nil ->
        {:reply, {:error, :no_share}, state}

      %{sharer_peer_id: sharer} when sharer == peer_id or is_moderator ->
        # Authorised stop (own share or moderator).
        new_state = %{state | shares: Map.delete(state.shares, room_id)}

        Phoenix.PubSub.broadcast(
          Burble.PubSub,
          "room:#{room_id}",
          {:screen_share_stopped, sharer, :stopped}
        )

        Logger.info("[ScreenShare] Stopped: peer=#{sharer} room=#{room_id}")
        {:reply, :ok, new_state}

      _other ->
        {:reply, {:error, :not_authorised}, state}
    end
  end

  @impl true
  def handle_call({:get_share, room_id}, _from, state) do
    case Map.get(state.shares, room_id) do
      nil -> {:reply, {:error, :no_share}, state}
      share -> {:reply, {:ok, share}, state}
    end
  end

  @impl true
  def handle_call({:signal, room_id, peer_id, signal}, _from, state) do
    # Forward to the media engine for WebRTC negotiation on the screen share track.
    # In production, this creates/manages a separate PeerConnection for video.
    case Map.get(state.shares, room_id) do
      nil ->
        {:reply, {:error, :no_share}, state}

      %{sharer_peer_id: sharer} when sharer == peer_id ->
        # Sharer sending their video track signaling.
        Burble.Media.Engine.handle_signal(room_id, peer_id, Map.put(signal, :type, :screen_share))
        {:reply, {:ok, :forwarded}, state}

      _other ->
        # Viewer receiving the screen share stream — forward signaling.
        Burble.Media.Engine.handle_signal(room_id, peer_id, Map.put(signal, :type, :screen_share_view))
        {:reply, {:ok, :forwarded}, state}
    end
  end

  @impl true
  def handle_cast({:peer_disconnected, room_id, peer_id}, state) do
    case Map.get(state.shares, room_id) do
      %{sharer_peer_id: ^peer_id} ->
        # The sharer left — clean up.
        new_state = %{state | shares: Map.delete(state.shares, room_id)}

        Phoenix.PubSub.broadcast(
          Burble.PubSub,
          "room:#{room_id}",
          {:screen_share_stopped, peer_id, :peer_disconnected}
        )

        Logger.info("[ScreenShare] Auto-stopped: peer=#{peer_id} disconnected from room=#{room_id}")
        {:noreply, new_state}

      _other ->
        # The disconnected peer wasn't the sharer — no action.
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:room_destroyed, room_id}, state) do
    new_state = %{state | shares: Map.delete(state.shares, room_id)}
    Logger.info("[ScreenShare] Cleaned up state for destroyed room=#{room_id}")
    {:noreply, new_state}
  end

  # ── Private ──

  # Cap resolution to 1080p and framerate to a reasonable maximum.
  # This prevents clients from requesting 4K+ which would saturate bandwidth.
  defp cap_constraints(constraints) do
    %{
      max_width: min(constraints.max_width, 1920),
      max_height: min(constraints.max_height, 1080),
      max_framerate: min(constraints.max_framerate, 30)
    }
  end
end
