# SPDX-License-Identifier: MPL-2.0
#
# Burble.Rooms.RoomManager — Creates and finds room processes.
#
# Thin layer over DynamicSupervisor + Registry for room lifecycle.
# Room processes are started on demand and cleaned up via idle timeout.

defmodule Burble.Rooms.RoomManager do
  @moduledoc """
  Manages room process lifecycle.

  Rooms are created on demand (first join) and automatically terminated
  after an idle timeout with no participants.
  """

  alias Burble.Rooms.Room

  @doc "Find or create a room process. Returns {:ok, pid} or {:error, reason}."
  def ensure_room(room_id, opts \\ []) do
    case Registry.lookup(Burble.RoomRegistry, room_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        start_room(room_id, opts)
    end
  end

  @doc "Start a new room process under the RoomSupervisor."
  def start_room(room_id, opts \\ []) do
    child_opts =
      Keyword.merge(opts, id: room_id)
      |> Keyword.put_new(:server_id, "default")
      |> Keyword.put_new(:name, "Room #{room_id}")

    DynamicSupervisor.start_child(
      Burble.RoomSupervisor,
      {Room, child_opts}
    )
  end

  @doc "List all active room IDs."
  def list_active_rooms do
    Registry.select(Burble.RoomRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  @doc "Count active rooms."
  def active_room_count do
    length(list_active_rooms())
  end

  @doc "Join a room (creating it if needed)."
  def join(room_id, user_id, user_info, room_opts \\ []) do
    case ensure_room(room_id, room_opts) do
      {:ok, _pid} -> Room.join(room_id, user_id, user_info)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Create an ad-hoc room for an instant-connect session.

  Generates a unique room ID and starts it under the RoomSupervisor.
  Returns `{:ok, %{id: room_id}}` or `{:error, reason}`.
  """
  def create_adhoc_room(creator_id, creator_name) do
    room_id = Burble.RoomNamer.generate()

    case start_room(room_id, server_id: "default", name: "#{creator_name}'s Room", creator_id: creator_id) do
      {:ok, _pid} -> {:ok, %{id: room_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Join a room by ID with minimal user info (used by InstantConnect).

  Wraps `join/4` with a user_info map built from the user ID and name.
  """
  def join_room(room_id, user_id, user_name) do
    join(room_id, user_id, %{display_name: user_name, is_guest: false})
  end
end
