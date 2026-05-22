# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# BurbleWeb.API.InstantConnectController — Link/QR/code instant voice join.

defmodule BurbleWeb.API.InstantConnectController do
  use Phoenix.Controller, formats: [:json]

  alias Burble.Rooms.InstantConnect

  @doc "Look up a connect token by code. Returns token info if valid."
  def lookup(conn, %{"code" => code}) do
    case InstantConnect.lookup(code) do
      {:ok, token} ->
        json(conn, %{
          code: token.code,
          creator_name: token.creator_name,
          group_invite: token.group_invite,
          requires_confirmation: token.requires_confirmation,
          expires_at: DateTime.to_iso8601(token.expires_at),
          uses: token.uses,
          max_uses: token.max_uses
        })

      {:error, reason} ->
        conn
        |> put_status(if(reason == :not_found, do: 404, else: 410))
        |> json(%{error: to_string(reason)})
    end
  end

  @doc "Redeem a connect token — join the voice session."
  def redeem(conn, %{"code" => code} = params) do
    user_id = Map.get(params, "user_id", "guest_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower))
    user_name = Map.get(params, "display_name", "Guest")

    case InstantConnect.redeem(code, user_id, user_name) do
      {:ok, room_id} ->
        json(conn, %{status: "connected", room_id: room_id})

      {:pending, _token} ->
        conn
        |> put_status(202)
        |> json(%{status: "pending_confirmation", message: "Waiting for host to confirm"})

      {:error, reason} ->
        status = case reason do
          :not_found -> 404
          :expired -> 410
          :exhausted -> 410
          _ -> 422
        end

        conn
        |> put_status(status)
        |> json(%{error: to_string(reason)})
    end
  end
end
