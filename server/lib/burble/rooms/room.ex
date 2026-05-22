# SPDX-License-Identifier: MPL-2.0
#
# Burble.Rooms.Room — GenServer managing a single voice room.
#
# Each active room is a separate OTP process, supervised by RoomSupervisor.
# Room processes are created on demand (first join) and terminated after
# a configurable idle timeout (no participants for N seconds).
#
# Responsibilities:
#   - Track participants and their voice state (muted, deafened, speaking)
#   - Enforce room-level policies (join limit, permissions)
#   - Coordinate with the media plane for WebRTC session setup
#   - Broadcast state changes to all participants via PubSub
#   - Persist room config to database on change

defmodule Burble.Rooms.Room do
  @moduledoc """
  GenServer for a single voice room.

  ## Voice states

  Each participant has a voice state:
  - `:connected` — in room, mic active
  - `:muted` — in room, mic off (self-muted)
  - `:deafened` — in room, can't hear or speak
  - `:priority` — priority speaker (others attenuated)

  ## Room modes

  - `:open` — anyone with access can join and speak
  - `:moderated` — only users with speak permission can unmute
  - `:presentation` — one speaker at a time, others listen
  """

  use GenServer, restart: :transient

  require Logger

  alias Burble.Rooms.Participant
  alias Burble.Transport.RTSP

  # Idle timeout: terminate room process after 5 minutes with no participants.
  @idle_timeout_ms 5 * 60 * 1_000

  # Maximum participants per room (overridable in room config).
  @default_max_participants 50

  # ── Types ──

  @type voice_state :: :connected | :muted | :deafened | :priority
  @type room_mode :: :open | :moderated | :presentation

  # Room types that get an RTSP mountpoint for broadcast distribution.
  @rtsp_room_types ["stage", "broadcast"]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          server_id: String.t(),
          type: String.t() | nil,
          mode: room_mode(),
          topology_mode: Burble.Topology.topology_mode(),
          max_participants: non_neg_integer(),
          participants: %{String.t() => Participant.t()},
          rtsp_mountpoint: String.t() | nil,
          created_at: DateTime.t(),
          idle_timer: reference() | nil
        }

  defstruct [
    :id,
    :name,
    :server_id,
    :type,
    :mode,
    :topology_mode,
    :max_participants,
    :participants,
    :rtsp_mountpoint,
    :created_at,
    :idle_timer
  ]

  # ── Client API ──

  @doc "Start a room process and register it in the RoomRegistry."
  def start_link(opts) do
    room_id = Keyword.fetch!(opts, :id)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {Burble.RoomRegistry, room_id}}
    )
  end

  @doc "Join a room. Returns {:ok, room_state} or {:error, reason}."
  def join(room_id, user_id, user_info) do
    call_room(room_id, {:join, user_id, user_info})
  end

  @doc "Leave a room."
  def leave(room_id, user_id) do
    call_room(room_id, {:leave, user_id})
  end

  @doc "Update voice state (mute, deafen, etc.)."
  def set_voice_state(room_id, user_id, state) do
    call_room(room_id, {:set_voice_state, user_id, state})
  end

  @doc "Get current room state (participants, mode, etc.)."
  def get_state(room_id) do
    call_room(room_id, :get_state)
  end

  @doc "Get participant count."
  def participant_count(room_id) do
    call_room(room_id, :participant_count)
  end

  # ── Server Callbacks ──

  @impl true
  def init(opts) do
    room_id = Keyword.fetch!(opts, :id)
    room_type = Keyword.get(opts, :type)

    # Register an RTSP mountpoint for broadcast/stage rooms so the SFU can
    # fan out a single RTP stream to N listeners without N PeerConnections.
    rtsp_mountpoint =
      if room_type in @rtsp_room_types do
        case RTSP.register_mountpoint(room_id, :speaker) do
          {:ok, path} ->
            Logger.info("[Room #{room_id}] RTSP mountpoint created: #{path}")
            path

          {:error, reason} ->
            Logger.warning(
              "[Room #{room_id}] Failed to create RTSP mountpoint: #{inspect(reason)}"
            )
            nil
        end
      end

    room = %__MODULE__{
      id: room_id,
      name: Keyword.get(opts, :name, "Unnamed Room"),
      server_id: Keyword.fetch!(opts, :server_id),
      type: room_type,
      mode: Keyword.get(opts, :mode, :open),
      topology_mode: Keyword.get(opts, :topology_mode, Burble.Topology.mode()),
      max_participants: Keyword.get(opts, :max_participants, @default_max_participants),
      participants: %{},
      rtsp_mountpoint: rtsp_mountpoint,
      created_at: DateTime.utc_now(),
      idle_timer: schedule_idle_check()
    }

    {:ok, room}
  end

  @impl true
  def handle_call({:join, user_id, user_info}, _from, room) do
    cond do
      Map.has_key?(room.participants, user_id) ->
        {:reply, {:error, :already_joined}, room}

      map_size(room.participants) >= room.max_participants ->
        {:reply, {:error, :room_full}, room}

      true ->
        participant = Participant.new(user_id, user_info)
        new_participants = Map.put(room.participants, user_id, participant)
        new_room = %{room | participants: new_participants, idle_timer: cancel_idle(room)}

        broadcast(new_room, {:participant_joined, user_id, participant})
        
        # Voice-first accessibility announcement
        Burble.Accessibility.ScreenReader.announce_join(
          participant.display_name, 
          new_room.name
        )

        {:reply, {:ok, summarise(new_room)}, new_room}
    end
  end

  @impl true
  def handle_call({:leave, user_id}, _from, room) do
    case Map.pop(room.participants, user_id) do
      {nil, _} ->
        {:reply, {:error, :not_in_room}, room}

      {participant, remaining} ->
        new_room = %{room | participants: remaining}
        broadcast(new_room, {:participant_left, user_id})

        # Voice-first accessibility announcement
        Burble.Accessibility.ScreenReader.announce_leave(
          participant.display_name,
          new_room.name
        )

        new_room =
          if map_size(remaining) == 0 do
            %{new_room | idle_timer: schedule_idle_check()}
          else
            new_room
          end

        {:reply, :ok, new_room}
    end
  end

  @impl true
  def handle_call({:set_voice_state, user_id, state}, _from, room) do
    case Map.get(room.participants, user_id) do
      nil ->
        {:reply, {:error, :not_in_room}, room}

      participant ->
        updated = Participant.set_voice_state(participant, state)
        new_participants = Map.put(room.participants, user_id, updated)
        new_room = %{room | participants: new_participants}

        broadcast(new_room, {:voice_state_changed, user_id, state})
        {:reply, :ok, new_room}
    end
  end

  @impl true
  def handle_call(:get_state, _from, room) do
    {:reply, {:ok, summarise(room)}, room}
  end

  @impl true
  def handle_call(:participant_count, _from, room) do
    {:reply, map_size(room.participants), room}
  end

  @impl true
  def handle_cast({:update_topology, new_mode}, room) do
    Logger.info("[Room #{room.id}] Updating topology mode to #{new_mode}")
    {:noreply, %{room | topology_mode: new_mode}}
  end

  @impl true
  def handle_info(:idle_check, room) do
    if map_size(room.participants) == 0 do
      {:stop, :normal, room}
    else
      {:noreply, room}
    end
  end

  @impl true
  def handle_info(_msg, room) do
    {:noreply, room}
  end

  @impl true
  def terminate(_reason, room) do
    # Tear down the RTSP mountpoint when the room process exits (idle timeout,
    # explicit shutdown, or crash). This disconnects all RTSP subscribers and
    # frees the RTP socket allocated for the stream.
    if room.rtsp_mountpoint do
      case RTSP.remove_mountpoint(room.rtsp_mountpoint) do
        :ok ->
          Logger.info("[Room #{room.id}] RTSP mountpoint removed: #{room.rtsp_mountpoint}")

        {:error, reason} ->
          Logger.warning(
            "[Room #{room.id}] Failed to remove RTSP mountpoint #{room.rtsp_mountpoint}: #{inspect(reason)}"
          )
      end
    end

    :ok
  end

  # ── Private ──

  defp call_room(room_id, message) do
    case Registry.lookup(Burble.RoomRegistry, room_id) do
      [{pid, _}] -> GenServer.call(pid, message)
      [] -> {:error, :room_not_found}
    end
  end

  defp broadcast(room, event) do
    Phoenix.PubSub.broadcast(Burble.PubSub, "room:#{room.id}", event)
  end

  defp summarise(room) do
    %{
      id: room.id,
      name: room.name,
      type: room.type,
      mode: room.mode,
      rtsp_mountpoint: room.rtsp_mountpoint,
      participant_count: map_size(room.participants),
      participants:
        room.participants
        |> Enum.map(fn {id, p} -> {id, Participant.summarise(p)} end)
        |> Map.new()
    }
  end

  defp schedule_idle_check do
    Process.send_after(self(), :idle_check, @idle_timeout_ms)
  end

  defp cancel_idle(%{idle_timer: nil} = _room), do: nil

  defp cancel_idle(%{idle_timer: ref} = _room) do
    Process.cancel_timer(ref)
    nil
  end
end
