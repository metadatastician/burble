# SPDX-License-Identifier: MPL-2.0
#
# BurbleWeb.UserSocket — WebSocket entry point for voice signaling.
#
# Clients connect here and then join room channels for voice comms.
# Authentication happens at connect time via Guardian JWT verification.

defmodule BurbleWeb.UserSocket do
  use Phoenix.Socket

  alias Burble.Auth.Guardian

  channel("room:*", BurbleWeb.RoomChannel)
  channel("signaling:*", BurbleWeb.SignalingChannel)
  channel("game:*", BurbleWeb.GameChannel)

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
              |> assign(:voice_auth, voice_auth(token))

            {:ok, socket}

          {:error, _} ->
            :error
        end

      {:error, _reason} ->
        :error
    end
  end

  # Guest connection (no token required if server policy allows).
  #
  # Guests are unauthenticated, so the name is attacker-controlled and was
  # previously passed through unbounded (an 8 MiB display_name became room
  # presence metadata, repeated per join). Clamp it, and fall back to "Guest"
  # rather than rejecting — a bad name should not stop someone joining.
  @max_display_name 64

  def connect(%{"guest" => "true", "display_name" => name}, socket, _connect_info) do
    name = sanitise_display_name(name)
    {:ok, guest} = Burble.Auth.create_guest_session(name)

    socket =
      socket
      |> assign(:user_id, guest.id)
      |> assign(:display_name, guest.display_name)
      |> assign(:is_guest, true)

    {:ok, socket}
  end

  def connect(_params, _socket, _connect_info), do: :error

  # Existing socket behavior is unchanged; the new scoped adapter only admits
  # existing access/guest identities with current voice permissions. Refresh
  # tokens and legacy unauthenticated guests gain no scoped bridge authority.
  defp voice_auth(token) do
    case Burble.GrooveVoice.authenticate(token) do
      {:ok, auth} -> auth
      _ -> nil
    end
  end

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.user_id}"

  # Trim, drop control characters, and bound the length. Returns "Guest" for
  # anything that is not a non-empty binary.
  defp sanitise_display_name(name) when is_binary(name) do
    cleaned =
      name
      |> String.replace(~r/[[:cntrl:]]/u, "")
      |> String.trim()
      |> String.slice(0, @max_display_name)

    if cleaned == "", do: "Guest", else: cleaned
  end

  defp sanitise_display_name(_), do: "Guest"
end
