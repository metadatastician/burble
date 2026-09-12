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
      Phoenix.PubSub.subscribe(Burble.PubSub, peer_topic(room_id, user_id))

      socket =
        socket
        |> assign(:user_id, user_id)
        |> assign(:room_id, room_id)
        |> assign(:bebop_delivery, params["wire_format"] == "bebop")

      Logger.debug("[SignalingChannel] #{user_id} joined signaling:#{room_id}")

      {:ok, socket}
    else
      {:error, reason} ->
        Logger.warning("[SignalingChannel] Join rejected for room #{room_id}: #{inspect(reason)}")

        {:error, %{reason: "unauthorized"}}
    end
  end

  # ---------------------------------------------------------------------------
  # Incoming events
  # ---------------------------------------------------------------------------

  @doc "Route an SDP offer to the target peer."
  @impl true
  def handle_in("sdp:offer", %{"to" => peer_id, "sdp" => sdp} = params, socket) do
    route_sdp("sdp:offer", peer_id, sdp, params, socket)
  end

  @impl true
  def handle_in("sdp:answer", %{"to" => peer_id, "sdp" => sdp} = params, socket) do
    route_sdp("sdp:answer", peer_id, sdp, params, socket)
  end

  @impl true
  def handle_in("ice:candidate", %{"to" => peer_id, "candidate" => candidate}, socket) do
    route_to_peer(socket, peer_id, %{
      type: "ice:candidate",
      from: socket.assigns.user_id,
      candidate: candidate
    })

    {:noreply, socket}
  end

  @impl true
  def handle_in("presence:join", _params, socket) do
    broadcast!(socket, "presence:join", %{
      user_id: socket.assigns.user_id
    })

    {:noreply, socket}
  end

  @impl true
  def handle_in("presence:leave", _params, socket) do
    broadcast!(socket, "presence:leave", %{
      user_id: socket.assigns.user_id
    })

    {:noreply, socket}
  end

  @impl true
  def handle_in("ping", _params, socket) do
    {:reply, {:ok, %{pong: true}}, socket}
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
    delivered = if socket.assigns[:bebop_delivery], do: payload, else: decode_sdp_body(payload)
    push(socket, "msg", delivered)
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
    case Phoenix.Token.verify(BurbleWeb.Endpoint, @token_salt, token, max_age: @token_max_age) do
      {:ok, user_id} -> {:ok, user_id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_token(_params), do: {:error, :missing_token}

  # Publish a signaling payload to a specific peer's PubSub topic.
  #
  # The recipient peer's channel process is subscribed to its own topic and
  # will receive this as `{:signaling_msg, payload}` in `handle_info/2`.
  @spec route_to_peer(Phoenix.Socket.t(), String.t(), map()) :: :ok | {:error, term()}
  defp route_to_peer(socket, peer_id, payload) do
    room_id = socket.assigns.room_id

    Phoenix.PubSub.broadcast(
      Burble.PubSub,
      peer_topic(room_id, peer_id),
      {:signaling_msg, payload}
    )

    Burble.GrooveVoice.from_channel(
      room_id,
      payload.from,
      peer_id,
      payload,
      socket.assigns[:voice_auth]
    )

    :ok
  end

  # ---------------------------------------------------------------------------
  # SDP routing — JSON today, Bebop when enabled (spline ADR-0005 criterion (a))
  # ---------------------------------------------------------------------------
  #
  # The SDP body is carried either as a plain string (JSON plane, the default)
  # or as a base64-wrapped Bebop `SdpPayload` (binary plane). The wire encoding
  # is chosen per message and always ANNOUNCED in the payload (`enc: "bebop" |
  # "json"`), so a receiver never has to guess — this is what lets the two
  # planes coexist during migration and what a second consumer (gossamer)
  # keys off.
  #
  # `:bebop` is the DEFAULT since 2026-08-04 (criterion (a); its gate,
  # criterion (b), is satisfied by gossamer's decoder). Opt out with
  # `config :burble, :signaling_wire_format, :json`. Encoding failures fall
  # back to JSON rather than dropping the message: a signalling plane that
  # loses an offer is worse than one that sends it in the older format.
  @spec route_sdp(String.t(), String.t(), String.t(), map(), Phoenix.Socket.t()) ::
          {:noreply, Phoenix.Socket.t()}
  defp route_sdp(type, peer_id, sdp, params, socket) do
    media_type = Map.get(params, "mediaType", "audio")

    payload =
      %{type: type, from: socket.assigns.user_id}
      |> Map.merge(encode_sdp_body(sdp, media_type, type))

    route_to_peer(socket, peer_id, payload)
    {:noreply, socket}
  end

  # Returns the encoding-specific half of the payload, plus telemetry.
  @spec encode_sdp_body(String.t(), String.t(), String.t()) :: map()
  defp encode_sdp_body(sdp, media_type, type) do
    case wire_format() do
      :bebop ->
        try do
          bin =
            Burble.Protocol.VoiceSignal.encode_sdp_payload(%{sdp: sdp, media_type: media_type})

          :telemetry.execute(
            [:burble, :signaling, :encode],
            %{bytes: byte_size(bin)},
            %{format: :bebop, type: type}
          )

          %{enc: "bebop", sdp_b64: Base.encode64(bin), mediaType: media_type}
        rescue
          error ->
            Logger.warning(
              "[SignalingChannel] Bebop encode failed (#{inspect(error)}); falling back to JSON"
            )

            :telemetry.execute(
              [:burble, :signaling, :encode],
              %{bytes: byte_size(sdp)},
              %{format: :json_fallback, type: type}
            )

            %{enc: "json", sdp: sdp, mediaType: media_type}
        end

      _json ->
        :telemetry.execute(
          [:burble, :signaling, :encode],
          %{bytes: byte_size(sdp)},
          %{format: :json, type: type}
        )

        %{enc: "json", sdp: sdp, mediaType: media_type}
    end
  end

  @doc """
  The signalling wire format in force: `:json` (default) or `:bebop`.

  Public so tests and operators can assert which plane is live without
  reaching into application config directly.
  """
  @spec wire_format() :: :json | :bebop
  def wire_format, do: Application.get_env(:burble, :signaling_wire_format, :bebop)

  @doc """
  Normalise a routed signalling payload back to a plain `:sdp` string.

  Bebop-encoded payloads (`enc: "bebop"`) are decoded and the base64 field
  dropped, so existing clients see the same shape they always have. This is
  what keeps the binary plane transparent to the browser client while the
  migration is in flight. Unknown or malformed encodings are passed through
  untouched rather than raising — a signalling channel must not crash a call
  over a payload it does not recognise.
  """
  @spec decode_sdp_body(map()) :: map()
  def decode_sdp_body(%{enc: "bebop", sdp_b64: b64} = payload) do
    with {:ok, bin} <- Base.decode64(b64),
         {%{sdp: sdp} = decoded, <<>>} <- Burble.Protocol.VoiceSignal.decode_sdp_payload(bin),
         true <- lossless?(decoded, bin) do
      payload |> Map.drop([:sdp_b64]) |> Map.put(:sdp, sdp) |> Map.put(:enc, "json")
    else
      _ ->
        Logger.warning("[SignalingChannel] Bebop decode failed; forwarding payload as-is")
        payload
    end
  rescue
    error ->
      Logger.warning("[SignalingChannel] Bebop decode raised #{inspect(error)}; forwarding as-is")
      payload
  end

  def decode_sdp_body(payload), do: payload

  # Round-trip integrity check — defense in depth.
  #
  # Since 2026-08-04 the generated decoders are STRICT (they raise
  # Burble.BebopDecodeError on truncated/malformed input; the rescue above
  # turns that into forward-as-is), so this re-encode comparison is a second,
  # independent line. It stays because it also catches decode/encode asymmetry
  # bugs the field-level checks cannot see. Historical context: before the
  # strictness change, a buffer declaring a uint32-LE string length far beyond
  # its own size decoded to "" instead of failing (measured 2026-07-28 — a
  # truncated frame would otherwise arrive as
  # a valid-looking EMPTY SDP offer, which is worse than an obvious error).
  # Re-encoding the decoded value must reproduce the original bytes exactly;
  # anything lossy is rejected and the payload forwarded untouched.
  @spec lossless?(map(), binary()) :: boolean()
  defp lossless?(decoded, original_bin) do
    Burble.Protocol.VoiceSignal.encode_sdp_payload(decoded) == original_bin
  rescue
    _ -> false
  end

  # Build the PubSub topic for a specific peer.
  defp peer_topic(room_id, peer_id), do: Burble.GrooveVoice.peer_topic(room_id, peer_id)
end
