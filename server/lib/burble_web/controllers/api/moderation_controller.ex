# SPDX-License-Identifier: MPL-2.0
#
# BurbleWeb.API.ModerationController — REST API for moderation actions.
#
# Provides HTTP endpoints for kick, ban, mute, and move operations.
# All actions require authentication and appropriate permissions.
# Every action is audit-logged via Burble.Audit.
#
# Author: Jonathan D.A. Jewell

defmodule BurbleWeb.API.ModerationController do
  @moduledoc """
  REST API controller for moderation actions.

  ## Endpoints

  - `POST /api/v1/rooms/:id/kick` — Kick a user from a room
  - `POST /api/v1/servers/:id/ban` — Ban a user from a server
  - `POST /api/v1/rooms/:id/mute` — Server-mute a user in a room
  - `POST /api/v1/rooms/:id/move` — Move a user to another room

  All endpoints require a valid JWT and the caller must hold the
  relevant moderation permission.
  """

  use Phoenix.Controller, formats: [:json]

  alias Burble.Moderation
  alias Burble.Permissions

  @doc """
  Kick a user from a room.

  ## Request body

  ```json
  {
    "user_id": "target_user_id",
    "reason": "Disruptive behaviour"
  }
  ```
  """
  def kick(conn, %{"id" => room_id} = params) do
    actor_id = conn.assigns[:user_id]
    target_id = Map.get(params, "user_id")
    reason = Map.get(params, "reason", "No reason given")
    actor_perms = get_actor_permissions(conn)

    if is_nil(target_id) do
      conn |> put_status(400) |> json(%{error: "user_id is required"})
    else
      case Moderation.kick(actor_id, target_id, room_id, reason, actor_perms) do
        :ok ->
          json(conn, %{status: "ok", action: "kick", target_id: target_id, room_id: room_id})

        {:error, :insufficient_permissions} ->
          conn |> put_status(403) |> json(%{error: "insufficient_permissions"})

        {:error, :user_not_found} ->
          conn |> put_status(404) |> json(%{error: "user_not_found"})

        {:error, :room_not_found} ->
          conn |> put_status(404) |> json(%{error: "room_not_found"})

        {:error, reason} ->
          conn |> put_status(400) |> json(%{error: inspect(reason)})
      end
    end
  end

  @doc """
  Ban a user from a server.

  ## Request body

  ```json
  {
    "user_id": "target_user_id",
    "reason": "Repeated violations",
    "duration": 86400  // optional, seconds. null = permanent
  }
  ```
  """
  def ban(conn, %{"id" => server_id} = params) do
    actor_id = conn.assigns[:user_id]
    target_id = Map.get(params, "user_id")
    reason = Map.get(params, "reason", "No reason given")
    duration = Map.get(params, "duration")
    actor_perms = get_actor_permissions(conn)

    if is_nil(target_id) do
      conn |> put_status(400) |> json(%{error: "user_id is required"})
    else
      case Moderation.ban(actor_id, target_id, server_id, reason, duration, actor_perms) do
        {:ok, ban_record} ->
          json(conn, %{
            status: "ok",
            action: "ban",
            target_id: target_id,
            server_id: server_id,
            expires_at:
              if(ban_record.expires_at,
                do: DateTime.to_iso8601(ban_record.expires_at),
                else: nil
              )
          })

        {:error, :insufficient_permissions} ->
          conn |> put_status(403) |> json(%{error: "insufficient_permissions"})

        {:error, reason} ->
          conn |> put_status(400) |> json(%{error: inspect(reason)})
      end
    end
  end

  @doc """
  Server-mute a user in a room.

  ## Request body

  ```json
  {
    "user_id": "target_user_id",
    "duration": 300  // optional, seconds. null = indefinite
  }
  ```
  """
  def mute(conn, %{"id" => room_id} = params) do
    actor_id = conn.assigns[:user_id]
    target_id = Map.get(params, "user_id")
    duration = Map.get(params, "duration")
    actor_perms = get_actor_permissions(conn)

    if is_nil(target_id) do
      conn |> put_status(400) |> json(%{error: "user_id is required"})
    else
      case Moderation.mute(actor_id, target_id, room_id, duration, actor_perms) do
        {:ok, _mute_record} ->
          json(conn, %{
            status: "ok",
            action: "mute",
            target_id: target_id,
            room_id: room_id,
            duration: duration
          })

        {:error, :insufficient_permissions} ->
          conn |> put_status(403) |> json(%{error: "insufficient_permissions"})

        {:error, :user_not_found} ->
          conn |> put_status(404) |> json(%{error: "user_not_found"})

        {:error, :room_not_found} ->
          conn |> put_status(404) |> json(%{error: "room_not_found"})

        {:error, reason} ->
          conn |> put_status(400) |> json(%{error: inspect(reason)})
      end
    end
  end

  @doc """
  Move a user from one room to another.

  ## Request body

  ```json
  {
    "user_id": "target_user_id",
    "to_room_id": "destination_room_id"
  }
  ```
  """
  def move(conn, %{"id" => from_room_id} = params) do
    actor_id = conn.assigns[:user_id]
    target_id = Map.get(params, "user_id")
    to_room_id = Map.get(params, "to_room_id")
    actor_perms = get_actor_permissions(conn)

    cond do
      is_nil(target_id) ->
        conn |> put_status(400) |> json(%{error: "user_id is required"})

      is_nil(to_room_id) ->
        conn |> put_status(400) |> json(%{error: "to_room_id is required"})

      true ->
        case Moderation.move(actor_id, target_id, from_room_id, to_room_id, actor_perms) do
          :ok ->
            json(conn, %{
              status: "ok",
              action: "move",
              target_id: target_id,
              from_room_id: from_room_id,
              to_room_id: to_room_id
            })

          {:error, :insufficient_permissions} ->
            conn |> put_status(403) |> json(%{error: "insufficient_permissions"})

          {:error, :user_not_found} ->
            conn |> put_status(404) |> json(%{error: "user_not_found"})

          {:error, :room_not_found} ->
            conn |> put_status(404) |> json(%{error: "room_not_found"})

          {:error, reason} ->
            conn |> put_status(400) |> json(%{error: inspect(reason)})
        end
    end
  end

  # ── Private helpers ──

  # Get the actor's permission set from the connection assigns.
  # Falls back to member permissions for authenticated users.
  @doc false
  defp get_actor_permissions(conn) do
    if conn.assigns[:is_guest] do
      Permissions.role_template(:guest)
    else
      # In production, look up the user's role in the server context.
      # For now, authenticated non-guest users get member permissions.
      # Moderation requires explicit moderator/admin role assignment.
      role = conn.assigns[:role] || :member
      Permissions.role_template(role)
    end
  end
end
