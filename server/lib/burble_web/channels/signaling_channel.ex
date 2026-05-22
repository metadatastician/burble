# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# BurbleWeb.SignalingChannel — dedicated WebRTC signaling channel.
#
# Handles peer-to-peer WebRTC signaling (SDP offers/answers and ICE
# candidates) on a dedicated channel topic separate from the room voice
# channel. Routing is peer-directed: each message carries a "to" field
# identifying the destination peer's socket topic, and the channel
# forwards the payload via Phoenix.PubSub to that peer's socket process.
#
# This channel is Phase 3's extraction of WebRTC signaling out of the
# monolithic RoomChannel so that the two concerns — room state management
# and WebRTC negotiation — can evolve independently.

defmodule BurbleWeb.SignalingChannel do
  @moduledoc """
  Phoenix Channel for dedicated WebRTC signaling.

  ## Topic pattern

  Clients join `"signaling:<room_id>"`, e.g. `"signaling:room-abc123"`.

  ## Authentication

  On join, the channel verifies the `"token"` parameter using
  `Phoenix.Token.verify/4` with a maximum age of 86 400 seconds (24 h).
  The token must have been signed with `BurbleWeb.Endpoint` and the salt
  `"signaling_channel"`.

  If the socket was already authenticated upstream (e.g. via
  `BurbleWeb.UserSocket`), the channel falls back to trusting the
  `:user_id` already assigned to the socket — a token param is then
  optional.

  ## Peer-directed routing

  SDP and ICE messages carry a `"to"` field containing the destination
  peer's user ID. The channel publishes the payload to the PubSub topic
  `"signaling_peer:<peer_id>"`. Each peer's channel process subscribes to
  its own PubSub topic on join and forwards received messages to the
  client via `push/3`.

  ## Events (incoming)

  | Event             | Payload fields                        | Description               |
  |-------------------|---------------------------------------|---------------------------|
  | `sdp:offer`       | `to`, `sdp`                           | Route SDP offer to peer   |
  | `sdp:answer`      | `to`, `sdp`                           | Route SDP answer to peer  |
  | `ice:candidate`   | `to`, `candidate`                     | Route ICE candidate        |
  | `presence:join`   | (empty)                               | Announce join to channel  |
  | `presence:leave`  | (empty)                               | Announce leave to channel |
  | `ping`            | (empty)                               | Health check              |

  ## Events (outgoing)

  | Event   | Payload                   | Description                          |
  |---------|---------------------------|--------------------------------------|
  | `msg`   | arbitrary map             | Forwarded signaling message from peer |

  ## Info messages

  | Message                       | Description                            |
  |-------------------------------|----------------------------------------|
  | `{:signaling_msg, payload}`   | PubSub delivery — pushed to client     |
  """

  use Phoenix.Channel

  require Logger

  # Maximum token age for Phoenix.Token.verify/4 (24 hours).
  @token_max_age 86_400

  # Salt used when signing signaling tokens (must match the generator side).
  @token_salt "signaling_channel"

  # ---------------------------------------------------------------------------
  # Join
  # ---------------------------------------------------------------------------

  @impl true
  def join("signaling:" <> room_id, params, socket) do
    # Determine the effective user_id: trust the socket assign if already set
    # (i.e. the socket was authenticated at the transport level), otherwise
    # verify the Phoenix.Token from the join params.
    with {:ok, user_id} <- resolve_user_id(socket, params) do
      # Subscribe this process to the peer-specific PubSub topic so that
      # peer-directed messages (SDP offers, ICE candidates, etc.) are delivered
      # to this channel process and forwarded to the client via handle_info/2.
      Phoenix.PubSub.subscribe(Burble.PubSub, peer_topic(user_id))

      socket =
        socket
        |> assign(:user_id, user_id)
        |> assign(:room_id, room_id)

      Logger.debug(
        "[SignalingChannel] #{user_id} joined signaling:#{room_id}"
      )

      {:ok, socket}
    else
      {:error, reason} ->
        Logger.warning(
          "[SignalingChannel] Join rejected for room #{room_id}: #{inspect(reason)}"
        )

        {:error, %{reason: "unauthorized"}}
    end
  end

  # ---------------------------------------------------------------------------
  # Incoming events
  # ---------------------------------------------------------------------------

  @doc "Route an SDP offer to the target peer."
  @impl true
  def handle_in("sdp:offer", %{"to" => peer_id, "sdp" => sdp}, socket) do
    route_to_peer(peer_id, %{
      type: "sdp:offer",
      from: socket.assigns.user_id,
      sdp: sdp
    })

    {:noreply, socket}
  end

  @doc "Route an SDP answer to the target peer."
  @impl true
  def handle_in("sdp:answer", %{"to" => peer_id, "sdp" => sdp}, socket) do
    route_to_peer(peer_id, %{
      type: "sdp:answer",
      from: socket.assigns.user_id,
      sdp: sdp
    })

    {:noreply, socket}
  end

  @doc "Route an ICE candidate to the target peer."
  @impl true
  def handle_in("ice:candidate", %{"to" => peer_id, "candidate" => candidate}, socket) do
    route_to_peer(peer_id, %{
      type: "ice:candidate",
      from: socket.assigns.user_id,
      candidate: candidate
    })

    {:noreply, socket}
  end

  @doc "Broadcast a presence:join event to all subscribers of this signaling topic."
  @impl true
  def handle_in("presence:join", _params, socket) do
    broadcast!(socket, "presence:join", %{
      user_id: socket.assigns.user_id
    })

    {:noreply, socket}
  end

  @doc "Broadcast a presence:leave event to all subscribers of this signaling topic."
  @impl true
  def handle_in("presence:leave", _params, socket) do
    broadcast!(socket, "presence:leave", %{
      user_id: socket.assigns.user_id
    })

    {:noreply, socket}
  end

  @doc "Health check — reply immediately with pong."
  @impl true
  def handle_in("ping", _params, socket) do
    {:reply, {:ok, %{"pong" => true}}, socket}
  end

  # Catch-all for unrecognised events — return a structured error rather than
  # crashing with FunctionClauseError.
  @impl true
  def handle_in(event, _params, socket) do
    Logger.warning("[SignalingChannel] Unhandled event: #{inspect(event)}")
    {:reply, {:error, %{reason: "unknown_event", event: event}}, socket}
  end

  # ---------------------------------------------------------------------------
  # Info messages (from PubSub delivery)
  # ---------------------------------------------------------------------------

  @doc """
  Forward a routed signaling message from another peer to the client.

  Received from `Phoenix.PubSub` when another peer calls `route_to_peer/2`
  targeting this socket's user ID.
  """
  @impl true
  def handle_info({:signaling_msg, payload}, socket) do
    push(socket, "msg", payload)
    {:noreply, socket}
  end

  @impl true
  def handle_info(msg, socket) do
    Logger.debug("[SignalingChannel] Unhandled info: #{inspect(msg)}")
    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Resolve the effective user_id for this channel join.
  #
  # Priority:
  # 1. If `:user_id` is already assigned on the socket (transport-level auth),
  #    trust it and skip token verification.
  # 2. Otherwise verify the Phoenix.Token from the join params.
  @spec resolve_user_id(Phoenix.Socket.t(), map()) :: {:ok, String.t()} | {:error, term()}
  defp resolve_user_id(socket, params) do
    case socket.assigns[:user_id] do
      nil ->
        # No transport-level auth — require a Phoenix.Token in params.
        verify_token(params)

      user_id ->
        {:ok, user_id}
    end
  end

  # Verify a Phoenix.Token from the join params map.
  @spec verify_token(map()) :: {:ok, String.t()} | {:error, term()}
  defp verify_token(%{"token" => token}) when is_binary(token) do
    case Phoenix.Token.verify(BurbleWeb.Endpoint, @token_salt, token,
           max_age: @token_max_age
         ) do
      {:ok, user_id} -> {:ok, user_id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_token(_params), do: {:error, :missing_token}

  # Publish a signaling payload to a specific peer's PubSub topic.
  #
  # The recipient peer's channel process is subscribed to its own topic and
  # will receive this as `{:signaling_msg, payload}` in `handle_info/2`.
  @spec route_to_peer(String.t(), map()) :: :ok | {:error, term()}
  defp route_to_peer(peer_id, payload) do
    Phoenix.PubSub.broadcast(Burble.PubSub, peer_topic(peer_id), {:signaling_msg, payload})
  end

  # Build the PubSub topic for a specific peer.
  @spec peer_topic(String.t()) :: String.t()
  defp peer_topic(peer_id), do: "signaling_peer:#{peer_id}"
end
