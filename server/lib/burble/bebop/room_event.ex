# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Generated from: priv/schemas/room_event.bop
# DO NOT EDIT — regenerate with `mix bebop.generate`

defmodule Burble.Bebop.RoomEvent do
  @moduledoc """
  Bebop encoder/decoder for the RoomEvent union.

  4 room lifecycle event types — ParticipantJoined, ParticipantLeft,
  VoiceStateChanged, RoomConfigUpdated.
  """

  alias Burble.Bebop.VoiceSignal, as: VS

  # ---------------------------------------------------------------------------
  # Enumerations
  # ---------------------------------------------------------------------------

  def room_type(:voice), do: 1
  def room_type(:stage), do: 2
  def room_type(:broadcast), do: 3
  def room_type(:spatial), do: 4
  def room_type(1), do: :voice
  def room_type(2), do: :stage
  def room_type(3), do: :broadcast
  def room_type(4), do: :spatial

  def leave_reason(:voluntary), do: 0
  def leave_reason(:kicked), do: 1
  def leave_reason(:banned), do: 2
  def leave_reason(:timeout), do: 3
  def leave_reason(:server_shutdown), do: 4
  def leave_reason(0), do: :voluntary
  def leave_reason(1), do: :kicked
  def leave_reason(2), do: :banned
  def leave_reason(3), do: :timeout
  def leave_reason(4), do: :server_shutdown

  def participant_role(:listener), do: 0
  def participant_role(:speaker), do: 1
  def participant_role(:moderator), do: 2
  def participant_role(:owner), do: 3
  def participant_role(0), do: :listener
  def participant_role(1), do: :speaker
  def participant_role(2), do: :moderator
  def participant_role(3), do: :owner

  # ---------------------------------------------------------------------------
  # Struct encoders/decoders
  # ---------------------------------------------------------------------------

  def encode_voice_state(%{muted: muted, deafened: deafened, speaking: speaking, streaming: streaming, mute_type: mute_type}) do
    VS.encode_bool(muted) <> VS.encode_bool(deafened) <> VS.encode_bool(speaking) <> VS.encode_bool(streaming) <> <<mute_type::8>>
  end

  def decode_voice_state(data) do
    {muted, rest} = VS.decode_bool(data)
    {deafened, rest2} = VS.decode_bool(rest)
    {speaking, rest3} = VS.decode_bool(rest2)
    {streaming, rest4} = VS.decode_bool(rest3)
    <<mute_type::8, rest5::binary>> = rest4
    {%{muted: muted, deafened: deafened, speaking: speaking, streaming: streaming, mute_type: mute_type}, rest5}
  end

  def encode_participant(%{user_id: uid, display_name: dn, avatar_url: av, role: role, voice_state: vs}) do
    VS.encode_string(uid) <> VS.encode_string(dn) <> VS.encode_string(av) <> <<participant_role(role)::8>> <> encode_voice_state(vs)
  end

  def decode_participant(data) do
    {user_id, rest} = VS.decode_string(data)
    {display_name, rest2} = VS.decode_string(rest)
    {avatar_url, rest3} = VS.decode_string(rest2)
    <<role::8, rest4::binary>> = rest3
    {voice_state, rest5} = decode_voice_state(rest4)
    {%{user_id: user_id, display_name: display_name, avatar_url: avatar_url,
       role: participant_role(role), voice_state: voice_state}, rest5}
  end

  def encode_room_config(%{room_id: rid, name: name, room_type: rt, max_participants: mp,
                           bitrate: br, e2ee_required: e2ee, recording_active: rec,
                           spatial_audio: spatial, region: region}) do
    VS.encode_string(rid) <> VS.encode_string(name) <> <<room_type(rt)::8>> <>
    <<mp::32-little>> <> <<br::32-little>> <>
    VS.encode_bool(e2ee) <> VS.encode_bool(rec) <> VS.encode_bool(spatial) <>
    VS.encode_string(region)
  end

  def decode_room_config(data) do
    {room_id, rest} = VS.decode_string(data)
    {name, rest2} = VS.decode_string(rest)
    <<rt::8, rest3::binary>> = rest2
    <<mp::32-little, rest4::binary>> = rest3
    <<br::32-little, rest5::binary>> = rest4
    {e2ee, rest6} = VS.decode_bool(rest5)
    {rec, rest7} = VS.decode_bool(rest6)
    {spatial, rest8} = VS.decode_bool(rest7)
    {region, rest9} = VS.decode_string(rest8)
    {%{room_id: room_id, name: name, room_type: room_type(rt), max_participants: mp,
       bitrate: br, e2ee_required: e2ee, recording_active: rec,
       spatial_audio: spatial, region: region}, rest9}
  end

  # ---------------------------------------------------------------------------
  # Message encoders
  # ---------------------------------------------------------------------------

  def encode({:participant_joined, msg}) do
    payload = VS.encode_string(msg.room_id) <> encode_participant(msg.participant) <>
              VS.encode_string(msg.timestamp) <> <<msg.participant_count::32-little>>
    <<1::8, payload::binary>>
  end

  def encode({:participant_left, msg}) do
    payload = VS.encode_string(msg.room_id) <> VS.encode_string(msg.user_id) <>
              <<leave_reason(msg.reason)::8>> <> VS.encode_string(msg.timestamp) <>
              <<msg.participant_count::32-little>>
    <<2::8, payload::binary>>
  end

  def encode({:voice_state_changed, msg}) do
    payload = VS.encode_string(msg.room_id) <> VS.encode_string(msg.user_id) <>
              encode_voice_state(msg.voice_state) <> <<participant_role(msg.role)::8>> <>
              VS.encode_string(msg.timestamp)
    <<3::8, payload::binary>>
  end

  def encode({:room_config_updated, msg}) do
    payload = VS.encode_string(msg.room_id) <> encode_room_config(msg.config) <>
              VS.encode_string(msg.changed_by) <> VS.encode_string(msg.timestamp)
    <<4::8, payload::binary>>
  end

  # ---------------------------------------------------------------------------
  # Union decoder
  # ---------------------------------------------------------------------------

  def decode(<<1::8, payload::binary>>) do
    {room_id, rest} = VS.decode_string(payload)
    {participant, rest2} = decode_participant(rest)
    {timestamp, rest3} = VS.decode_string(rest2)
    <<count::32-little, rest4::binary>> = rest3
    {:participant_joined, %{room_id: room_id, participant: participant,
                            timestamp: timestamp, participant_count: count}, rest4}
  end

  def decode(<<2::8, payload::binary>>) do
    {room_id, rest} = VS.decode_string(payload)
    {user_id, rest2} = VS.decode_string(rest)
    <<reason::8, rest3::binary>> = rest2
    {timestamp, rest4} = VS.decode_string(rest3)
    <<count::32-little, rest5::binary>> = rest4
    {:participant_left, %{room_id: room_id, user_id: user_id, reason: leave_reason(reason),
                          timestamp: timestamp, participant_count: count}, rest5}
  end

  def decode(<<3::8, payload::binary>>) do
    {room_id, rest} = VS.decode_string(payload)
    {user_id, rest2} = VS.decode_string(rest)
    {voice_state, rest3} = decode_voice_state(rest2)
    <<role::8, rest4::binary>> = rest3
    {timestamp, rest5} = VS.decode_string(rest4)
    {:voice_state_changed, %{room_id: room_id, user_id: user_id, voice_state: voice_state,
                              role: participant_role(role), timestamp: timestamp}, rest5}
  end

  def decode(<<4::8, payload::binary>>) do
    {room_id, rest} = VS.decode_string(payload)
    {config, rest2} = decode_room_config(rest)
    {changed_by, rest3} = VS.decode_string(rest2)
    {timestamp, rest4} = VS.decode_string(rest3)
    {:room_config_updated, %{room_id: room_id, config: config,
                              changed_by: changed_by, timestamp: timestamp}, rest4}
  end

  def decode(<<tag::8, _::binary>>) do
    {:error, "Unknown RoomEvent discriminator tag: #{tag}"}
  end
end
