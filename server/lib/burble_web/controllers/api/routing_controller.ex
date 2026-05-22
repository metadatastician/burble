# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# BurbleWeb.API.RoutingController — Voice channel routing API.
#
# Manages routing modes (broadcast all, broadcast group, private whisper,
# priority speaker) and group membership within voice rooms.

defmodule BurbleWeb.API.RoutingController do
  use Phoenix.Controller, formats: [:json]

  alias Burble.Media.ChannelRouting

  @doc "Set the routing mode for the authenticated user in a room."
  def set_mode(conn, %{"id" => room_id, "mode" => mode_str} = params) do
    user_id = conn.assigns[:current_user_id]

    mode =
      case mode_str do
        "broadcast_all" -> :broadcast_all
        "broadcast_group" -> :broadcast_group
        "private" -> {:private, Map.get(params, "target_id", "")}
        "priority" -> :priority
        _ -> :broadcast_all
      end

    case ChannelRouting.set_mode(room_id, user_id, mode) do
      :ok ->
        json(conn, %{status: "ok", mode: mode_str})

      {:error, reason} ->
        conn
        |> put_status(403)
        |> json(%{error: to_string(reason)})
    end
  end

  @doc "Get the current routing mode for the authenticated user."
  def get_mode(conn, %{"id" => room_id}) do
    user_id = conn.assigns[:current_user_id]
    mode = ChannelRouting.get_mode(room_id, user_id)

    json(conn, %{
      mode: format_mode(mode),
      target_id: case mode do
        {:private, target} -> target
        _ -> nil
      end
    })
  end

  @doc "Create a group within a room."
  def create_group(conn, %{"id" => room_id, "name" => name, "member_ids" => member_ids}) do
    case ChannelRouting.create_group(room_id, name, member_ids) do
      {:ok, group_id} ->
        json(conn, %{status: "ok", group_id: group_id, name: name})

      {:error, reason} ->
        conn
        |> put_status(422)
        |> json(%{error: to_string(reason)})
    end
  end

  @doc "List groups in a room."
  def list_groups(conn, %{"id" => room_id}) do
    groups = ChannelRouting.list_groups(room_id)

    json(conn, %{
      groups:
        Enum.map(groups, fn g ->
          %{id: g.id, name: g.name, members: MapSet.to_list(g.members)}
        end)
    })
  end

  @doc "Join a group."
  def join_group(conn, %{"id" => room_id, "group_id" => group_id}) do
    user_id = conn.assigns[:current_user_id]

    case ChannelRouting.join_group(room_id, user_id, group_id) do
      :ok -> json(conn, %{status: "ok"})
      {:error, reason} -> conn |> put_status(422) |> json(%{error: to_string(reason)})
    end
  end

  @doc "Leave current group."
  def leave_group(conn, %{"id" => room_id}) do
    user_id = conn.assigns[:current_user_id]

    case ChannelRouting.leave_group(room_id, user_id) do
      :ok -> json(conn, %{status: "ok"})
      {:error, reason} -> conn |> put_status(422) |> json(%{error: to_string(reason)})
    end
  end

  defp format_mode(:broadcast_all), do: "broadcast_all"
  defp format_mode(:broadcast_group), do: "broadcast_group"
  defp format_mode({:private, _}), do: "private"
  defp format_mode(:priority), do: "priority"
end
