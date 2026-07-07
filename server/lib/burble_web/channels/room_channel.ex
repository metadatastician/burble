# SPDX-License-Identifier: MPL-2.0
#
# BurbleWeb.RoomChannel — WebSocket channel for voice room signaling.
#
# Handles:
#   - Room join/leave lifecycle (with Avow consent attestation)
#   - Voice state changes (mute, deafen, priority)
#   - WebRTC signaling (offer/answer/ICE candidate exchange)
#   - Presence tracking (who's in the room)
#   - Text messages (stored via NNTPSBackend)
#   - Permission enforcement via Burble.Permissions
#
# This is the signaling plane — actual audio flows via WebRTC peer
# connections negotiated through this channel.

defmodule BurbleWeb.RoomChannel do
  @moduledoc """
  Phoenix Channel for voice room signaling.

  ## Topics

  Clients join `"room:<room_id>"` to participate in a voice room.

  ## Incoming events

  - `"voice_state"` — update own voice state (mute/deafen/etc.)
  - `"signal"` — WebRTC signaling (offer, answer, ice_candidate)
  - `"text"` — send a text message in the room
  - `"whisper"` — direct audio to a specific user

  ## Outgoing events

  - `"presence_state"` — initial presence snapshot
  - `"presence_diff"` — presence changes (join/leave)
  - `"voice_state_changed"` — another user's voice state changed
  - `"signal"` — WebRTC signaling from another peer
  - `"text"` — text message from another user
  - `"room_state"` — full room state update
  """

  use Phoenix.Channel

  alias Burble.Presence
  alias Burble.Rooms.RoomManager
  alias Burble.Permissions
  alias Burble.Verification.Avow
  alias Burble.Audit

  @impl true
  def join("room:" <> room_id, params, socket) do
    user_id = socket.assigns[:user_id]
    display_name = Map.get(params, "display_name", socket.assigns[:display_name] || "Guest")

    # Check join permission.
    role_perms = get_user_permissions(socket)

    if not Permissions.has_permission?(role_perms, :join_room) do
      {:error, %{reason: "insufficient_permissions"}}
    else
      case RoomManager.join(room_id, user_id, %{display_name: display_name}) do
        {:ok, room_state} ->
          # Avow consent attestation for the join.
          Avow.attest_join(user_id, room_id, :direct_join)

          # Start WebRTC peer via Media.Engine (passes self() as channel_pid
          # so the Peer GenServer can send SDP offers and ICE candidates back).
          Burble.Media.Engine.add_peer(room_id, user_id, channel_pid: self())

          # Audit log.
          Audit.log(:room_join, user_id, %{room_id: room_id})

          send(self(), :after_join)

          socket =
            socket
            |> assign(:room_id, room_id)
            |> assign(:display_name, display_name)

          # Send ICE server config to the browser so it uses TURN credentials
          # when creating its RTCPeerConnection (critical for symmetric NAT users).
          ice_servers = Burble.Network.TurnCredentials.ice_servers(user_id)
          room_state_with_ice = Map.put(room_state, :ice_servers, ice_servers)

          {:ok, room_state_with_ice, socket}

        {:error, reason} ->
          {:error, %{reason: reason}}
      end
    end
  end

  @impl true
  def join(topic, _params, _socket) do
    {:error, %{reason: "invalid_topic", topic: topic}}
  end

  # Messages from the Peer GenServer — relay to client.
  @impl true
  def handle_info({:peer_sdp_offer, sdp}, socket) do
    push(socket, "sdp_offer", %{body: sdp})
    {:noreply, socket}
  end

  @impl true
  def handle_info({:peer_ice_candidate, candidate_json}, socket) do
    push(socket, "ice_candidate", %{body: candidate_json})
    {:noreply, socket}
  end

  @impl true
  def handle_info(:after_join, socket) do
    # Track presence with voice state metadata.
    {:ok, _} =
      Presence.track(socket, socket.assigns.user_id, %{
        display_name: socket.assigns.display_name,
        voice_state: "connected",
        joined_at: System.system_time(:second)
      })

    # Push current presence state to the joining user.
    push(socket, "presence_state", Presence.list(socket))

    {:noreply, socket}
  end

  # ── Voice state ──

  @impl true
  def handle_in("voice_state", %{"state" => state}, socket)
      when state in ["connected", "muted", "deafened"] do
    room_id = socket.assigns.room_id
    user_id = socket.assigns.user_id

    # Check speak permission for unmuting.
    role_perms = get_user_permissions(socket)

    if state == "connected" and not Permissions.has_permission?(role_perms, :speak) do
      {:reply, {:error, %{reason: "no_speak_permission"}}, socket}
    else
      state_atom = String.to_existing_atom(state)
      Burble.Rooms.Room.set_voice_state(room_id, user_id, state_atom)

      # Update presence metadata.
      Presence.update(socket, user_id, fn meta ->
        Map.put(meta, :voice_state, state)
      end)

      broadcast!(socket, "voice_state_changed", %{
        user_id: user_id,
        voice_state: state
      })

      {:noreply, socket}
    end
  end

  # ── WebRTC signaling (server-mediated SFU) ──

  @impl true
  def handle_in("sdp_answer", %{"body" => body}, socket) do
    # Client sends SDP answer in response to server's offer.
    peer_id = socket.assigns.user_id
    Burble.Media.Peer.apply_sdp_answer(peer_id, body)
    {:noreply, socket}
  end

  @impl true
  def handle_in("ice_candidate", %{"body" => body}, socket) do
    # Client sends ICE candidate.
    peer_id = socket.assigns.user_id
    Burble.Media.Peer.add_ice_candidate(peer_id, body)
    {:noreply, socket}
  end

  # Legacy P2P signaling (kept for fallback/serverless mode).
  @impl true
  def handle_in("signal", %{"to" => target_id, "type" => type, "payload" => payload}, socket) do
    broadcast!(socket, "signal", %{
      from: socket.assigns.user_id,
      to: target_id,
      type: type,
      payload: payload
    })

    {:noreply, socket}
  end

  # ── Text messages (stored via NNTPSBackend) ──

  @impl true
  def handle_in("text", %{"body" => body}, socket)
      when byte_size(body) > 0 and byte_size(body) <= 2000 do
    user_id = socket.assigns.user_id
    room_id = socket.assigns.room_id
    display_name = socket.assigns.display_name

    # Check text permission.
    role_perms = get_user_permissions(socket)

    if Permissions.has_permission?(role_perms, :text) do
      # Store in NNTPSBackend for persistence and threading.
      Burble.Text.NNTPSBackend.post_message(
        room_id, user_id, display_name, body, %{}
      )

      broadcast!(socket, "text", %{
        user_id: user_id,
        display_name: display_name,
        body: body,
        sent_at: DateTime.utc_now() |> DateTime.to_iso8601()
      })

      {:noreply, socket}
    else
      {:reply, {:error, %{reason: "no_text_permission"}}, socket}
    end
  end

  # ── Real-time text messaging (MessageStore-backed) ──
  #
  # These events use the "text:" namespace and are separate from the legacy
  # "text" event (which routes through NNTPSBackend for NNTP threading).
  #
  # text:send   — broadcast a new message to all room participants
  # text:typing — broadcast a transient typing indicator (throttled)
  # text:history — fetch recent messages from the in-memory store

  @typing_throttle_ms 2_000

  @impl true
  def handle_in("text:send", %{"body" => body}, socket)
      when is_binary(body) and byte_size(body) > 0 and byte_size(body) <= 4096 do
    user_id = socket.assigns.user_id
    room_id = socket.assigns.room_id

    role_perms = get_user_permissions(socket)

    if Permissions.has_permission?(role_perms, :text) do
      id = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
      timestamp = DateTime.utc_now()

      msg = %{
        id: id,
        from: user_id,
        body: body,
        timestamp: timestamp
      }

      Burble.Chat.MessageStore.store_message(room_id, msg)

      broadcast!(socket, "text:new", %{
        id: id,
        from: user_id,
        body: body,
        timestamp: DateTime.to_iso8601(timestamp)
      })

      {:reply, {:ok, %{id: id}}, socket}
    else
      {:reply, {:error, %{reason: "no_text_permission"}}, socket}
    end
  end

  @impl true
  def handle_in("text:send", _params, socket) do
    {:reply, {:error, %{reason: "invalid_text_payload"}}, socket}
  end

  @impl true
  def handle_in("text:typing", _params, socket) do
    user_id = socket.assigns.user_id
    now = System.monotonic_time(:millisecond)
    # nil sentinel, NOT 0: monotonic time is typically NEGATIVE on the BEAM,
    # so `now - 0 >= throttle` was never true and the first (and every)
    # typing indicator was silently swallowed.
    last_typing = socket.assigns[:last_typing_broadcast_ms]

    if is_nil(last_typing) or now - last_typing >= @typing_throttle_ms do
      broadcast_from!(socket, "text:typing", %{from: user_id})
      socket = assign(socket, :last_typing_broadcast_ms, now)
      {:noreply, socket}
    else
      # Throttled — ignore
      {:noreply, socket}
    end
  end

  @impl true
  def handle_in("text:history", %{"limit" => limit_raw}, socket)
      when is_integer(limit_raw) and limit_raw > 0 do
    room_id = socket.assigns.room_id
    limit = min(limit_raw, 200)

    messages =
      Burble.Chat.MessageStore.get_messages(room_id, limit)
      |> Enum.map(fn msg ->
        %{
          id: msg.id,
          from: msg.from,
          body: msg.body,
          timestamp: DateTime.to_iso8601(msg.timestamp)
        }
      end)

    {:reply, {:ok, %{messages: messages}}, socket}
  end

  @impl true
  def handle_in("text:history", _params, socket) do
    {:reply, {:error, %{reason: "invalid_history_params"}}, socket}
  end

  # ── Whisper (directed audio) ──

  @impl true
  def handle_in("whisper", %{"to" => target_id}, socket) do
    role_perms = get_user_permissions(socket)

    if Permissions.has_permission?(role_perms, :whisper) do
      broadcast!(socket, "whisper", %{
        from: socket.assigns.user_id,
        to: target_id
      })

      {:noreply, socket}
    else
      {:reply, {:error, %{reason: "no_whisper_permission"}}, socket}
    end
  end

  # ── Catch-all for unmatched text messages ──
  # Prevents FunctionClauseError crashes when clients send malformed or
  # unrecognised events. Returns a structured error so the client knows
  # the event was rejected.

  @impl true
  def handle_in("text", _params, socket) do
    {:reply, {:error, %{reason: "invalid_text_payload"}}, socket}
  end

  @impl true
  def handle_in(event, _params, socket) do
    require Logger
    Logger.warning("[RoomChannel] Unhandled event: #{inspect(event)}")
    {:reply, {:error, %{reason: "unknown_event", event: event}}, socket}
  end

  # ── PubSub events from other processes ──
  # Handle participant join/leave notifications broadcast via PubSub
  # so the channel does not crash on unexpected info messages.

  @impl true
  def handle_info({:participant_joined, user_id, meta}, socket) do
    push(socket, "participant_joined", %{user_id: user_id, meta: meta})
    {:noreply, socket}
  end

  @impl true
  def handle_info({:participant_left, user_id}, socket) do
    push(socket, "participant_left", %{user_id: user_id})
    {:noreply, socket}
  end

  @impl true
  def handle_info(msg, socket) do
    require Logger
    Logger.debug("[RoomChannel] Unhandled info: #{inspect(msg)}")
    {:noreply, socket}
  end

  # ── Cleanup ──

  @impl true
  def terminate(_reason, socket) do
    room_id = socket.assigns[:room_id]
    user_id = socket.assigns[:user_id]

    if room_id && user_id do
      # Avow consent attestation for the leave.
      Avow.attest_leave(user_id, room_id, :voluntary)

      # Audit log.
      Audit.log(:room_leave, user_id, %{room_id: room_id})

      Burble.Rooms.Room.leave(room_id, user_id)
    end

    :ok
  end

  # ── Private helpers ──

  # Get the user's effective permissions based on their role.
  # For now, assign based on is_guest flag. Full role-based permissions
  # will use server config stored in VeriSimDB.
  defp get_user_permissions(socket) do
    if socket.assigns[:is_guest] do
      Permissions.role_template(:guest)
    else
      Permissions.role_template(:member)
    end
  end
end
