# SPDX-License-Identifier: MPL-2.0
#
# BurbleWeb.UserSocket — WebSocket entry point for voice signaling.
#
# Clients connect here and then join room channels for voice comms.
# Authentication happens at connect time via Guardian JWT verification.

defmodule BurbleWeb.UserSocket do
  use Phoenix.Socket

  alias Burble.Auth.Guardian

  channel "room:*", BurbleWeb.RoomChannel
  channel "signaling:*", BurbleWeb.SignalingChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case Guardian.decode_and_verify(token) do
      {:ok, claims} ->
        case Guardian.resource_from_claims(claims) do
          {:ok, user} ->
            socket =
              socket
              |> assign(:user_id, user.id || user[:id])
              |> assign(:display_name, user.display_name || user[:display_name] || "User")
              |> assign(:is_guest, Map.get(user, :is_guest, false))

            {:ok, socket}

          {:error, _} ->
            :error
        end

      {:error, _reason} ->
        :error
    end
  end

  # Guest connection (no token required if server policy allows).
  def connect(%{"guest" => "true", "display_name" => name}, socket, _connect_info) do
    {:ok, guest} = Burble.Auth.create_guest_session(name)

    socket =
      socket
      |> assign(:user_id, guest.id)
      |> assign(:display_name, guest.display_name)
      |> assign(:is_guest, true)

    {:ok, socket}
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.user_id}"
end
