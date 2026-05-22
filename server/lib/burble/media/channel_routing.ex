# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Burble.Media.ChannelRouting — Voice channel routing modes.
#
# Controls who hears whom in a voice room. Supports four routing modes
# that can be switched per-user at any time (like radio comms tabs):
#
#   Broadcast All  — everyone in the room hears you (default)
#   Broadcast Group — only your team/group hears you
#   Private (1:1)  — only your selected target hears you (whisper)
#   Priority       — you override all other audio (moderator/announcer)
#
# These modes stack with mute/deafen — a muted user in broadcast mode
# is still muted. A deafened user hears nothing regardless of routing.
#
# Groups are defined per-room by the room owner or moderator. In IDApTIK,
# groups map to teams (Jessica's team vs Q's team). In PanLL, groups
# map to panel workgroups.
#
# The SFU (Media.Engine) reads routing state to decide which peers
# receive each participant's audio frames. No frames are sent to
# peers outside the routing scope — this is server-enforced, not
# client-side mixing.

defmodule Burble.Media.ChannelRouting do
  @moduledoc """
  Voice channel routing — controls audio distribution topology per user.

  Four modes available to each participant:
  - `:broadcast_all` — everyone in the room (default)
  - `:broadcast_group` — only your assigned group
  - `:private` — directed to one specific user (whisper)
  - `:priority` — overrides all other audio (requires permission)

  ## Usage

      # Set a user to whisper mode.
      ChannelRouting.set_mode(room_id, user_id, {:private, target_user_id})

      # Get who should receive a user's audio.
      recipients = ChannelRouting.get_recipients(room_id, user_id)

      # Create a group.
      ChannelRouting.create_group(room_id, "alpha-team", [user1, user2, user3])
  """

  use GenServer

  require Logger

  # ---------------------------------------------------------------------------
  # Types
  # ---------------------------------------------------------------------------

  @type routing_mode ::
          :broadcast_all
          | :broadcast_group
          | {:private, String.t()}
          | :priority

  @type group :: %{
          id: String.t(),
          name: String.t(),
          members: MapSet.t(String.t())
        }

  @type room_routing :: %{
          room_id: String.t(),
          # user_id => routing_mode
          modes: %{String.t() => routing_mode()},
          # group_id => group
          groups: %{String.t() => group()},
          # user_id => group_id
          user_groups: %{String.t() => String.t()},
          # user_id => true (users with priority permission)
          priority_users: MapSet.t(String.t())
        }

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, opts ++ [name: __MODULE__])
  end

  @doc """
  Initialise routing state for a room.
  Called when a room is created or first participant joins.
  """
  def init_room(room_id) do
    GenServer.call(__MODULE__, {:init_room, room_id})
  end

  @doc """
  Set the routing mode for a participant.

  ## Modes
    - `:broadcast_all` — everyone hears you.
    - `:broadcast_group` — only your group hears you.
    - `{:private, target_id}` — only target hears you (whisper/DM).
    - `:priority` — you override all audio (requires priority permission).

  Returns `:ok` or `{:error, reason}`.
  """
  def set_mode(room_id, user_id, mode) do
    GenServer.call(__MODULE__, {:set_mode, room_id, user_id, mode})
  end

  @doc """
  Get the current routing mode for a participant.
  """
  def get_mode(room_id, user_id) do
    GenServer.call(__MODULE__, {:get_mode, room_id, user_id})
  end

  @doc """
  Get the list of user_ids that should receive audio from a given sender.
  This is the core function called by Media.Engine when forwarding frames.

  Returns a list of recipient user_ids.
  """
  def get_recipients(room_id, sender_id, all_participants) do
    GenServer.call(__MODULE__, {:get_recipients, room_id, sender_id, all_participants})
  end

  @doc """
  Create a named group within a room.
  Groups are used for team/squad voice channels within a room.
  """
  def create_group(room_id, group_name, member_ids) do
    GenServer.call(__MODULE__, {:create_group, room_id, group_name, member_ids})
  end

  @doc """
  Add a user to a group.
  A user can only be in one group at a time within a room.
  """
  def join_group(room_id, user_id, group_id) do
    GenServer.call(__MODULE__, {:join_group, room_id, user_id, group_id})
  end

  @doc """
  Remove a user from their current group (back to ungrouped).
  """
  def leave_group(room_id, user_id) do
    GenServer.call(__MODULE__, {:leave_group, room_id, user_id})
  end

  @doc """
  List all groups in a room with their members.
  """
  def list_groups(room_id) do
    GenServer.call(__MODULE__, {:list_groups, room_id})
  end

  @doc """
  Grant priority speaker permission to a user.
  Priority speakers can use `:priority` mode to override all other audio.
  """
  def grant_priority(room_id, user_id) do
    GenServer.call(__MODULE__, {:grant_priority, room_id, user_id})
  end

  @doc """
  Revoke priority speaker permission.
  """
  def revoke_priority(room_id, user_id) do
    GenServer.call(__MODULE__, {:revoke_priority, room_id, user_id})
  end

  @doc """
  Clean up routing state when a user leaves a room.
  """
  def user_left(room_id, user_id) do
    GenServer.cast(__MODULE__, {:user_left, room_id, user_id})
  end

  @doc """
  Clean up all routing state for a room.
  """
  def destroy_room(room_id) do
    GenServer.cast(__MODULE__, {:destroy_room, room_id})
  end

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, %{rooms: %{}}}
  end

  @impl true
  def handle_call({:init_room, room_id}, _from, state) do
    room_state = %{
      room_id: room_id,
      modes: %{},
      groups: %{},
      user_groups: %{},
      priority_users: MapSet.new()
    }

    new_state = put_in(state, [:rooms, room_id], room_state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:set_mode, room_id, user_id, mode}, _from, state) do
    case get_in(state, [:rooms, room_id]) do
      nil ->
        {:reply, {:error, :room_not_found}, state}

      room ->
        # Validate mode.
        case validate_mode(mode, user_id, room) do
          :ok ->
            updated_room = put_in(room, [:modes, user_id], mode)
            new_state = put_in(state, [:rooms, room_id], updated_room)

            Logger.info("[ChannelRouting] #{user_id} in #{room_id} → #{inspect(mode)}")
            {:reply, :ok, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:get_mode, room_id, user_id}, _from, state) do
    mode =
      case get_in(state, [:rooms, room_id, :modes, user_id]) do
        nil -> :broadcast_all
        mode -> mode
      end

    {:reply, mode, state}
  end

  @impl true
  def handle_call({:get_recipients, room_id, sender_id, all_participants}, _from, state) do
    recipients =
      case get_in(state, [:rooms, room_id]) do
        nil ->
          # No routing state — default broadcast all (minus sender).
          all_participants -- [sender_id]

        room ->
          mode = Map.get(room.modes, sender_id, :broadcast_all)
          compute_recipients(mode, sender_id, all_participants, room)
      end

    {:reply, recipients, state}
  end

  @impl true
  def handle_call({:create_group, room_id, group_name, member_ids}, _from, state) do
    case get_in(state, [:rooms, room_id]) do
      nil ->
        {:reply, {:error, :room_not_found}, state}

      room ->
        group_id = "group_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

        group = %{
          id: group_id,
          name: group_name,
          members: MapSet.new(member_ids)
        }

        # Assign each member to this group.
        user_groups =
          Enum.reduce(member_ids, room.user_groups, fn uid, acc ->
            Map.put(acc, uid, group_id)
          end)

        updated_room =
          room
          |> put_in([:groups, group_id], group)
          |> Map.put(:user_groups, user_groups)

        new_state = put_in(state, [:rooms, room_id], updated_room)

        Logger.info("[ChannelRouting] Created group '#{group_name}' (#{group_id}) in #{room_id} with #{length(member_ids)} members")
        {:reply, {:ok, group_id}, new_state}
    end
  end

  @impl true
  def handle_call({:join_group, room_id, user_id, group_id}, _from, state) do
    case get_in(state, [:rooms, room_id]) do
      nil ->
        {:reply, {:error, :room_not_found}, state}

      room ->
        case Map.get(room.groups, group_id) do
          nil ->
            {:reply, {:error, :group_not_found}, state}

          group ->
            updated_group = %{group | members: MapSet.put(group.members, user_id)}
            updated_room =
              room
              |> put_in([:groups, group_id], updated_group)
              |> put_in([:user_groups, user_id], group_id)

            new_state = put_in(state, [:rooms, room_id], updated_room)
            {:reply, :ok, new_state}
        end
    end
  end

  @impl true
  def handle_call({:leave_group, room_id, user_id}, _from, state) do
    case get_in(state, [:rooms, room_id]) do
      nil ->
        {:reply, {:error, :room_not_found}, state}

      room ->
        case Map.get(room.user_groups, user_id) do
          nil ->
            {:reply, :ok, state}

          group_id ->
            # Remove from group members.
            group = Map.get(room.groups, group_id)
            updated_group = %{group | members: MapSet.delete(group.members, user_id)}

            updated_room =
              room
              |> put_in([:groups, group_id], updated_group)
              |> Map.update!(:user_groups, &Map.delete(&1, user_id))

            new_state = put_in(state, [:rooms, room_id], updated_room)
            {:reply, :ok, new_state}
        end
    end
  end

  @impl true
  def handle_call({:list_groups, room_id}, _from, state) do
    groups =
      case get_in(state, [:rooms, room_id]) do
        nil -> []
        room -> Map.values(room.groups)
      end

    {:reply, groups, state}
  end

  @impl true
  def handle_call({:grant_priority, room_id, user_id}, _from, state) do
    case get_in(state, [:rooms, room_id]) do
      nil ->
        {:reply, {:error, :room_not_found}, state}

      room ->
        updated = %{room | priority_users: MapSet.put(room.priority_users, user_id)}
        new_state = put_in(state, [:rooms, room_id], updated)
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:revoke_priority, room_id, user_id}, _from, state) do
    case get_in(state, [:rooms, room_id]) do
      nil ->
        {:reply, {:error, :room_not_found}, state}

      room ->
        updated = %{room | priority_users: MapSet.delete(room.priority_users, user_id)}
        new_state = put_in(state, [:rooms, room_id], updated)
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_cast({:user_left, room_id, user_id}, state) do
    case get_in(state, [:rooms, room_id]) do
      nil ->
        {:noreply, state}

      room ->
        updated =
          room
          |> Map.update!(:modes, &Map.delete(&1, user_id))
          |> Map.update!(:user_groups, &Map.delete(&1, user_id))
          |> Map.update!(:priority_users, &MapSet.delete(&1, user_id))
          # Also remove from any group membership.
          |> update_group_membership(user_id)

        new_state = put_in(state, [:rooms, room_id], updated)
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_cast({:destroy_room, room_id}, state) do
    new_state = Map.update!(state, :rooms, &Map.delete(&1, room_id))
    {:noreply, new_state}
  end

  # ---------------------------------------------------------------------------
  # Private — recipient computation
  # ---------------------------------------------------------------------------

  # Compute who receives audio based on the sender's routing mode.
  defp compute_recipients(:broadcast_all, sender_id, all_participants, _room) do
    # Everyone except the sender.
    all_participants -- [sender_id]
  end

  defp compute_recipients(:broadcast_group, sender_id, _all_participants, room) do
    # Only group members (minus sender).
    case Map.get(room.user_groups, sender_id) do
      nil ->
        # Not in a group — nobody hears them in group mode.
        []

      group_id ->
        case Map.get(room.groups, group_id) do
          nil -> []
          group -> MapSet.to_list(group.members) -- [sender_id]
        end
    end
  end

  defp compute_recipients({:private, target_id}, _sender_id, all_participants, _room) do
    # Only the target hears the sender (if they're in the room).
    if target_id in all_participants, do: [target_id], else: []
  end

  defp compute_recipients(:priority, sender_id, all_participants, _room) do
    # Everyone hears the priority speaker (their audio overrides others).
    # The Media.Engine should also attenuate other speakers during priority.
    all_participants -- [sender_id]
  end

  # ---------------------------------------------------------------------------
  # Private — validation
  # ---------------------------------------------------------------------------

  defp validate_mode(:broadcast_all, _user_id, _room), do: :ok
  defp validate_mode(:broadcast_group, _user_id, _room), do: :ok
  defp validate_mode({:private, _target}, _user_id, _room), do: :ok

  defp validate_mode(:priority, user_id, room) do
    if MapSet.member?(room.priority_users, user_id) do
      :ok
    else
      {:error, :priority_not_permitted}
    end
  end

  defp validate_mode(_mode, _user_id, _room), do: {:error, :invalid_mode}

  # Remove user from any group they're in.
  defp update_group_membership(room, user_id) do
    case Map.get(room.user_groups, user_id) do
      nil ->
        room

      group_id ->
        case Map.get(room.groups, group_id) do
          nil ->
            room

          group ->
            updated_group = %{group | members: MapSet.delete(group.members, user_id)}
            put_in(room, [:groups, group_id], updated_group)
        end
    end
  end
end
