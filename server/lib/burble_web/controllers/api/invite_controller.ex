# SPDX-License-Identifier: MPL-2.0

defmodule BurbleWeb.API.InviteController do
  use Phoenix.Controller, formats: [:json]

  alias Burble.Auth

  def create(conn, %{"server_id" => server_id} = params) do
    opts = [
      max_uses: Map.get(params, "max_uses", 10),
      expires_in: Map.get(params, "expires_in", 86_400)
    ]

    case Auth.generate_invite_token(server_id, opts) do
      {:ok, invite} -> json(conn, invite)
      {:error, reason} -> conn |> put_status(400) |> json(%{error: reason})
    end
  end

  def accept(conn, %{"token" => token}) do
    case Auth.redeem_invite(token) do
      {:ok, invite} ->
        json(conn, %{status: "accepted", server_id: invite.server_id || invite["server_id"]})

      {:error, :invalid_token} ->
        conn |> put_status(404) |> json(%{error: "invalid_token"})

      {:error, :expired} ->
        conn |> put_status(410) |> json(%{error: "invite_expired"})

      {:error, :exhausted} ->
        conn |> put_status(410) |> json(%{error: "invite_exhausted"})
    end
  end
end
