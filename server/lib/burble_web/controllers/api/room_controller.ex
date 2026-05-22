# SPDX-License-Identifier: MPL-2.0

defmodule BurbleWeb.API.RoomController do
  use Phoenix.Controller, formats: [:json]

  alias Burble.Rooms.{Room, RoomManager}

  def index(conn, %{"server_id" => _server_id}) do
    rooms = RoomManager.list_active_rooms()
    |> Enum.map(fn room_id ->
      case Room.get_state(room_id) do
        {:ok, state} -> state
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)

    json(conn, %{rooms: rooms})
  end

  alias Burble.RoomNamer

  def create(conn, %{"server_id" => server_id} = params) do
    # Use word-based room name if not provided
    room_id = Map.get(params, "room_id")
    
    # Generate secure word-based room name if needed
    room_id = 
      cond do
        room_id && RoomNamer.valid_room_name?(room_id) -> room_id
        room_id -> conn |> put_status(400) |> json(%{error: "Invalid room name format"}) |> halt()
        true -> RoomNamer.generate_room_name()
      end
    
    name = Map.get(params, "name", "Room #{room_id}")

    case RoomManager.start_room(room_id, server_id: server_id, name: name) do
      {:ok, _pid} -> json(conn, %{room_id: room_id, name: name})
      {:error, reason} -> conn |> put_status(400) |> json(%{error: inspect(reason)})
    end
  end

  def show(conn, %{"id" => room_id}) do
    case Room.get_state(room_id) do
      {:ok, state} -> json(conn, state)
      {:error, _} -> conn |> put_status(404) |> json(%{error: "room_not_found"})
    end
  end

  def participants(conn, %{"id" => room_id}) do
    case Room.get_state(room_id) do
      {:ok, %{participants: p}} -> json(conn, %{participants: p})
      {:error, _} -> conn |> put_status(404) |> json(%{error: "room_not_found"})
    end
  end

  # Generate a v4 UUID via proven (formally verified) or stdlib fallback.
  defp generate_uuid do
    Burble.Safety.ProvenBridge.uuid_v4()
  end
end
