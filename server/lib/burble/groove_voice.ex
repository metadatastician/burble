# SPDX-License-Identifier: MPL-2.0
defmodule Burble.GrooveVoice do
  @moduledoc """
  Room/peer-scoped signaling adapter. It consumes existing identities and room
  membership; it never creates either. Only SDP and ICE are admitted. The
  generic Groove message queue is deliberately not part of this boundary.
  """
  alias Burble.Protocol.VoiceSignal
  @max_frame 16_384

  def max_frame, do: @max_frame

  def authenticate(token) when is_binary(token) and byte_size(token) <= 4096 do
    with {:ok, claims} <- Burble.Auth.Guardian.decode_and_verify(token),
         true <- claims["typ"] in ["access", "guest"],
         {:ok, user} <- Burble.Auth.Guardian.resource_from_claims(claims),
         true <- is_binary(user.id),
         true <- permitted?(user),
         exp when is_integer(exp) <- claims["exp"] do
      {:ok, %{subject: user.id, expires: exp}}
    else
      _ -> {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :unauthorized}
  catch
    :exit, _ -> {:error, :unauthorized}
  end

  def authenticate(_), do: {:error, :unauthorized}

  defp permitted?(user) do
    # Same role templates as RoomChannel; explicit resource permissions can
    # only attenuate this set, never enlarge it. Dynamic room ACLs are not
    # implemented by RoomChannel and are not invented by this adapter.
    role = if Map.get(user, :is_guest, false), do: :guest, else: :member
    template = Burble.Permissions.role_template(role)
    effective = MapSet.intersection(template, MapSet.new(Map.get(user, :permissions, template)))
    Enum.all?([:join_room, :speak], &Burble.Permissions.has_permission?(effective, &1))
  end

  def scope(auth, %{"room_id" => room, "peer_id" => peer}) do
    if valid_id?(room) and valid_id?(peer) and peer != auth.subject do
      {:ok, %{subject: auth.subject, room: room, peer: peer}}
    else
      {:error, :invalid_request}
    end
  end

  def scope(_, _), do: {:error, :invalid_request}

  def valid_id?(value),
    do:
      is_binary(value) and byte_size(value) in 1..128 and
        Regex.match?(~r/\A[A-Za-z0-9_.-]+\z/, value)

  # Unambiguous room + user topic; no room/user delimiter collisions.
  def peer_topic(room, user),
    do:
      "signaling_peer:" <> Base.url_encode64(:erlang.term_to_binary({room, user}), padding: false)

  def decode(bytes) when is_binary(bytes) and byte_size(bytes) in 1..@max_frame do
    case VoiceSignal.decode(bytes) do
      {tag, msg, <<>>} when tag in [:offer, :answer, :ice_candidate] ->
        if valid_text?(msg) and VoiceSignal.encode({tag, msg}) == bytes,
          do: {:ok, tag, msg},
          else: {:error, :invalid_frame}

      _ ->
        {:error, :invalid_frame}
    end
  rescue
    _ -> {:error, :invalid_frame}
  end

  def decode(_), do: {:error, :invalid_frame}

  defp valid_text?(map) when is_map(map), do: Enum.all?(Map.values(map), &valid_text?/1)
  defp valid_text?(text) when is_binary(text), do: String.valid?(text)
  defp valid_text?(value), do: is_integer(value)

  # Full VoiceSignal is the native data plane. The WebSocket retains the
  # existing SdpPayload wrapper for compatibility with deployed clients.
  def payload(tag, msg) when tag in [:offer, :answer] do
    %{
      type: if(tag == :offer, do: "sdp:offer", else: "sdp:answer"),
      from: msg.user_id,
      enc: "bebop",
      mediaType: msg.sdp.media_type,
      sdp_b64: Base.encode64(VoiceSignal.encode_sdp_payload(msg.sdp))
    }
  end

  def payload(:ice_candidate, msg) do
    %{
      type: "ice:candidate",
      from: msg.user_id,
      candidate: %{
        candidate: msg.candidate.candidate,
        sdpMLineIndex: msg.candidate.sdp_m_line_index,
        sdpMid: msg.candidate.sdp_mid,
        usernameFragment: msg.candidate.username_fragment
      }
    }
  end

  # Bridge existing WebSocket messages into scoped native inboxes. Membership
  # is checked in the room process; unscoped legacy routing grants no lease.
  def from_channel(room, user, peer, payload, %{subject: user, expires: expires}) do
    plain = BurbleWeb.SignalingChannel.decode_sdp_body(payload)

    signal =
      case plain do
        %{type: type, sdp: sdp} when type in ["sdp:offer", "sdp:answer"] ->
          {if(type == "sdp:offer", do: :offer, else: :answer),
           %{
             room_id: room,
             user_id: user,
             sdp: %{sdp: sdp, media_type: Map.get(plain, :mediaType, "audio")}
           }}

        %{type: "ice:candidate", candidate: c} when is_map(c) ->
          {:ice_candidate,
           %{
             room_id: room,
             user_id: user,
             candidate: %{
               candidate: Map.get(c, "candidate", ""),
               sdp_m_line_index: Map.get(c, "sdpMLineIndex", 0),
               sdp_mid: Map.get(c, "sdpMid", ""),
               username_fragment: Map.get(c, "usernameFragment", "")
             }
           }}

        _ ->
          nil
      end

    if signal do
      bytes = VoiceSignal.encode(signal)

      with {:ok, _, _} <- decode(bytes) do
        Burble.Rooms.Room.with_voice_members(room, user, peer, fn ->
          if expires > System.system_time(:second) do
            send(
              Burble.Groove,
              {:voice_delivery, room, user, peer, System.unique_integer([:monotonic, :positive]),
               bytes}
            )

            :ok
          else
            {:error, :unauthorized}
          end
        end)
      end
    end
  rescue
    _ -> {:error, :invalid_frame}
  catch
    :exit, _ -> {:error, :forbidden}
  end

  def from_channel(_, _, _, _, _), do: {:error, :unauthorized}
end
