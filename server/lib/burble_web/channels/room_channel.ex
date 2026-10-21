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
  - `"e2ee_register_key"` — publish this peer's ephemeral X25519 public key
  - `"e2ee_key_set"` — fetch the room's public keys and epoch
  - `"e2ee_publish_sealed"` — relay a room key sealed to one peer (opaque)
  - `"e2ee_fetch_sealed"` — collect a sealed room key addressed to you
  - `"e2ee_status"` — epoch, peer counts, and `key_custody: "peers"`

  ## Outgoing events

  - `"presence_state"` — initial presence snapshot
  - `"presence_diff"` — presence changes (join/leave)
  - `"voice_state_changed"` — another user's voice state changed
  - `"signal"` — WebRTC signaling from another peer
  - `"text"` — text message from another user
  - `"room_state"` — full room state update
  - `"e2ee_key_set"` — the room's public keys changed (a peer joined or left)
  - `"e2ee_sealed_key"` — a sealed room key was relayed; only the addressee
    can open it

  ## E2EE (ADR-0016, part-way)

  These events implement the *coordination* half of end-to-end encryption: the
  server stores public keys, epochs and opaque sealed blobs and can open none
  of them. The browser half — encrypting frames with WebCrypto and WebRTC
  Encoded Transform — is not written, so a room marked `:e2ee` is still
  protected by DTLS-SRTP alone. See `README.adoc` §*Encryption: what is true
  today*.
  """

  use Phoenix.Channel

  require Logger

  alias Burble.Presence
  alias Burble.Media.E2EE
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

          # EXPERIMENTAL (config :burble, :rtsp_broadcast): for stage/broadcast
          # rooms, revive the server-mediated SFU session so a single RTP
          # stream can be fanned out to RTSP viewers (VLC/ffmpeg/OBS) as well
          # as WebRTC peers. Default-off; no effect on the standard P2P path.
          maybe_start_rtsp_broadcast(room_id, room_state)

          # Start WebRTC peer via Media.Engine (passes self() as channel_pid
          # so the Peer GenServer can send SDP offers and ICE candidates back).
          Burble.Media.Engine.add_peer(room_id, user_id, channel_pid: self())

          # Make the E2EE coordinator aware of the room. Idempotent, and
          # non-fatal if the coordinator is unavailable — the media path must
          # not depend on the key-coordination path being up.
          init_e2ee_room(room_id)

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

  # PubSub participant events from the room process.
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
    Logger.debug("[RoomChannel] Unhandled info: #{inspect(msg)}")
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

    # The Peer GenServer may not be registered yet (or may have died). A bare
    # GenServer.call through a Registry name then exits :noproc, which crashed
    # the channel — killing the client's whole session over one early frame.
    case safe_peer_call(fn -> Burble.Media.Peer.apply_sdp_answer(peer_id, body) end) do
      :ok -> {:noreply, socket}
      {:error, reason} -> {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  @impl true
  def handle_in("ice_candidate", %{"body" => body}, socket) do
    # Client sends ICE candidate.
    peer_id = socket.assigns.user_id

    case safe_peer_call(fn -> Burble.Media.Peer.add_ice_candidate(peer_id, body) end) do
      :ok -> {:noreply, socket}
      {:error, reason} -> {:reply, {:error, %{reason: reason}}, socket}
    end
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
        room_id,
        user_id,
        display_name,
        body,
        %{}
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

  # ── E2EE key coordination (ADR-0016) ──
  #
  # The server relays public keys, epochs and opaque sealed blobs. It cannot
  # open a sealed blob: each is encrypted under a pairwise key that exists only
  # on two peers, and its AAD names the room, epoch and both peer ids. That is
  # why broadcasting a blob to the whole room is safe — every peer other than
  # the addressee receives ciphertext it can neither open nor replay.
  #
  # Keys travel base64-encoded because channel payloads are JSON.

  @impl true
  def handle_in(
        "e2ee_register_key",
        %{"public_key" => encoded, "identity_sig" => identity_sig, "sig_alg" => sig_alg},
        socket
      ) do
    room_id = socket.assigns.room_id
    user_id = socket.assigns.user_id

    with {:ok, public_key} <- decode_public_key(encoded),
         :ok <- verify_e2ee_key_identity_binding(room_id, user_id, public_key, identity_sig, sig_alg),
         {:ok, %{epoch: epoch, peer_count: count}} <-
           safe_e2ee(fn -> E2EE.register_peer_key(room_id, user_id, public_key) end) do
      broadcast!(socket, "e2ee_key_set", %{
        peer_id: user_id,
        epoch: epoch,
        peers: count,
        public_keys: public_key_set(room_id)
      })

      {:reply, {:ok, %{epoch: epoch, peers: count}}, socket}
    else
      {:error, reason} -> {:reply, {:error, %{reason: error_string(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("e2ee_register_key", _params, socket) do
    {:reply, {:error, %{reason: "invalid_public_key_or_identity_proof"}}, socket}
  end

  @impl true
  def handle_in("e2ee_key_set", _params, socket) do
    case safe_e2ee(fn -> E2EE.key_set(socket.assigns.room_id) end) do
      {:ok, %{epoch: epoch, peers: peers}} ->
        keys = Map.new(peers, fn {id, key} -> {id, Base.encode64(key)} end)
        {:reply, {:ok, %{epoch: epoch, public_keys: keys}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: error_string(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("e2ee_publish_sealed", params, socket) do
    room_id = socket.assigns.room_id
    from = socket.assigns.user_id

    with {:ok, to} <- fetch_string(params, "to"),
         {:ok, encoded} <- fetch_string(params, "blob", 1024),
         {:ok, epoch} <- fetch_epoch(params),
         {:ok, blob} <- decode_sealed_blob(encoded),
         :ok <- safe_e2ee(fn -> E2EE.publish_sealed(room_id, from, to, epoch, blob) end) do
      broadcast!(socket, "e2ee_sealed_key", %{
        from: from,
        to: to,
        epoch: epoch,
        blob: encoded
      })

      {:reply, {:ok, %{epoch: epoch}}, socket}
    else
      {:error, reason} -> {:reply, {:error, %{reason: error_string(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("e2ee_fetch_sealed", _params, socket) do
    room_id = socket.assigns.room_id

    case safe_e2ee(fn -> E2EE.sealed_for(room_id, socket.assigns.user_id) end) do
      {:ok, %{epoch: epoch, blob: blob}} ->
        {:reply, {:ok, %{epoch: epoch, blob: Base.encode64(blob)}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: error_string(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("e2ee_status", _params, socket) do
    case safe_e2ee(fn -> E2EE.room_status(socket.assigns.room_id) end) do
      {:ok, status} ->
        {:reply,
         {:ok,
          %{
            epoch: status.epoch,
            peers: status.peers,
            sealed_peers: status.sealed_peers,
            key_custody: Atom.to_string(status.key_custody)
          }}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: error_string(reason)}}, socket}
    end
  end

  @impl true
  def handle_in(event, _params, socket) do
    Logger.warning("[RoomChannel] Unhandled event: #{inspect(event)}")
    {:reply, {:error, %{reason: "unknown_event", event: event}}, socket}
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

      # Drop the peer's public key and bump the epoch so the key it holds can
      # never be current again.
      teardown_e2ee_peer(room_id, user_id)
    end

    :ok
  end

  # ── Private helpers ──

  # EXPERIMENTAL: when config :burble, :rtsp_broadcast is enabled and this is
  # a stage/broadcast room (which owns an RTSP mountpoint), ensure the
  # Media.Engine SFU session exists so its RTP fanout also reaches RTSP
  # viewers. Idempotent — the first joiner creates the session, later joiners
  # no-op ({:error, :session_exists}). No-op entirely on the default P2P path.
  defp maybe_start_rtsp_broadcast(room_id, room_state) do
    if Application.get_env(:burble, :rtsp_broadcast, false) do
      case room_state[:rtsp_mountpoint] do
        mp when is_binary(mp) ->
          _ = Burble.Media.Engine.create_room_session(room_id, rtsp_mountpoint: mp)
          :ok

        _ ->
          :ok
      end
    else
      :ok
    end
  end

  # Register the room with the E2EE coordinator (idempotent, best-effort).
  defp init_e2ee_room(room_id) do
    case safe_e2ee(fn -> E2EE.init_room(room_id) end) do
      {:ok, _} ->
        :ok

      {:error, :room_exists} ->
        :ok

      {:error, reason} ->
        Logger.warning("[RoomChannel] E2EE room init failed for #{room_id}: #{inspect(reason)}")
        :ok
    end
  end

  defp teardown_e2ee_peer(room_id, user_id) do
    _ = safe_e2ee(fn -> E2EE.remove_peer(room_id, user_id) end)
    :ok
  end

  # Call into the E2EE coordinator, tolerating its absence. The coordinator is
  # a coordination service, not a dependency of the call path.
  defp safe_e2ee(fun) do
    fun.()
  catch
    :exit, {:noproc, _} -> {:error, :e2ee_unavailable}
    :exit, {:timeout, _} -> {:error, :e2ee_timeout}
    :exit, reason -> {:error, {:e2ee_exit, reason}}
  end

  @public_key_bytes 32
  @max_sealed_bytes 512

  defp decode_public_key(encoded) when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, <<key::binary-size(@public_key_bytes)>>} -> {:ok, key}
      _ -> {:error, :invalid_public_key}
    end
  end

  defp decode_public_key(_), do: {:error, :invalid_public_key}

  defp decode_sealed_blob(encoded) when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, blob} when byte_size(blob) > 0 and byte_size(blob) <= @max_sealed_bytes -> {:ok, blob}
      _ -> {:error, :invalid_sealed_blob}
    end
  end

  defp decode_sealed_blob(_), do: {:error, :invalid_sealed_blob}

  # Peer ids are short; a base64 sealed blob is not. Both are length-capped,
  # before decoding and again after (see decode_sealed_blob/1).
  defp fetch_string(params, key, max_bytes \\ 128) when is_map(params) do
    case Map.get(params, key) do
      value when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= max_bytes ->
        {:ok, value}

      _ ->
        {:error, :invalid_params}
    end
  end

  defp fetch_epoch(%{"epoch" => epoch}) when is_integer(epoch) and epoch >= 0, do: {:ok, epoch}
  defp fetch_epoch(_), do: {:error, :invalid_epoch}

  defp public_key_set(room_id) do
    case safe_e2ee(fn -> E2EE.key_set(room_id) end) do
      {:ok, %{peers: peers}} -> Map.new(peers, fn {id, key} -> {id, Base.encode64(key)} end)
      {:error, _reason} -> %{}
    end
  end

  defp error_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_string(reason), do: inspect(reason)

  # Call into the per-peer media process, tolerating its absence.
  defp safe_peer_call(fun) do
    case fun.() do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  catch
    :exit, {:noproc, _} -> {:error, :peer_not_ready}
    :exit, {:timeout, _} -> {:error, :peer_timeout}
    :exit, reason -> {:error, {:peer_exit, reason}}
  end

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
