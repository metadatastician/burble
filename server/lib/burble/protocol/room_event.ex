# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Generated from: priv/schemas/room_event.bop
# Generator: mix bebop.generate
# DO NOT EDIT — regenerate with `mix bebop.generate`
#
# Bebop wire format: little-endian, length-prefixed strings (uint32 + UTF-8),
# 1-byte union discriminator tag.

defmodule Burble.Protocol.RoomEvent do
  @moduledoc """
  Bebop encoder/decoder for room_event.

  Auto-generated from `priv/schemas/room_event.bop`. Provides `encode/1`
  and `decode/1` for the RoomEvent union type, plus struct encode/decode
  helpers for VoiceState, Participant, and RoomConfig.

  ## Wire format

  Each RoomEvent message is prefixed with a 1-byte discriminator tag:

  | Tag | Variant             | Direction        |
  |-----|---------------------|------------------|
  |  1  | ParticipantJoined   | Server -> Client |
  |  2  | ParticipantLeft     | Server -> Client |
  |  3  | VoiceStateChanged   | Server -> Client |
  |  4  | RoomConfigUpdated   | Server -> Client |
  """

  # Reuse primitive codecs from the VoiceSignal module to avoid duplication.
  alias Burble.Protocol.VoiceSignal, as: VS

  # ---------------------------------------------------------------------------
  # Enum: RoomType
  # ---------------------------------------------------------------------------

  @doc "RoomType enum — Voice (1), Stage (2), Broadcast (3), Spatial (4)."
  def room_type(:voice), do: 1
  def room_type(:stage), do: 2
  def room_type(:broadcast), do: 3
  def room_type(:spatial), do: 4
  def room_type(1), do: :voice
  def room_type(2), do: :stage
  def room_type(3), do: :broadcast
  def room_type(4), do: :spatial

  # ---------------------------------------------------------------------------
  # Enum: LeaveReason
  # ---------------------------------------------------------------------------

  @doc "LeaveReason enum — Voluntary (0), Kicked (1), Banned (2), Timeout (3), ServerShutdown (4)."
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

  # ---------------------------------------------------------------------------
  # Enum: ParticipantRole
  # ---------------------------------------------------------------------------

  @doc "ParticipantRole enum — Listener (0), Speaker (1), Moderator (2), Owner (3)."
  def participant_role(:listener), do: 0
  def participant_role(:speaker), do: 1
  def participant_role(:moderator), do: 2
  def participant_role(:owner), do: 3
  def participant_role(0), do: :listener
  def participant_role(1), do: :speaker
  def participant_role(2), do: :moderator
  def participant_role(3), do: :owner

  # ---------------------------------------------------------------------------
  # Struct: VoiceState
  # ---------------------------------------------------------------------------

  @doc "Encode a VoiceState struct to Bebop binary."
  def encode_voice_state(%{muted: muted, deafened: deafened, speaking: speaking, streaming: streaming, mute_type: mute_type}) do
    VS.encode_bool(muted) <>
      VS.encode_bool(deafened) <>
      VS.encode_bool(speaking) <>
      VS.encode_bool(streaming) <>
      <<mute_type::8>>
  end

  @doc "Decode a VoiceState struct. Returns {voice_state_map, rest}."
  def decode_voice_state(data) do
    {muted, rest1} = VS.decode_bool(data)
    {deafened, rest2} = VS.decode_bool(rest1)
    {speaking, rest3} = VS.decode_bool(rest2)
    {streaming, rest4} = VS.decode_bool(rest3)
    <<mute_type::8, rest5::binary>> = rest4
    {%{muted: muted, deafened: deafened, speaking: speaking, streaming: streaming, mute_type: mute_type}, rest5}
  end

  # ---------------------------------------------------------------------------
  # Struct: Participant
  # ---------------------------------------------------------------------------

  @doc "Encode a Participant struct to Bebop binary."
  def encode_participant(%{user_id: user_id, display_name: display_name, avatar_url: avatar_url, role: role, voice_state: voice_state}) do
    VS.encode_string(user_id) <>
      VS.encode_string(display_name) <>
      VS.encode_string(avatar_url) <>
      <<participant_role(role)::8>> <>
      encode_voice_state(voice_state)
  end

  @doc "Decode a Participant struct. Returns {participant_map, rest}."
  def decode_participant(data) do
    {user_id, rest1} = VS.decode_string(data)
    {display_name, rest2} = VS.decode_string(rest1)
    {avatar_url, rest3} = VS.decode_string(rest2)
    <<role_raw::8, rest4::binary>> = rest3
    role = participant_role(role_raw)
    {voice_state, rest5} = decode_voice_state(rest4)
    {%{user_id: user_id, display_name: display_name, avatar_url: avatar_url,
       role: role, voice_state: voice_state}, rest5}
  end

  # ---------------------------------------------------------------------------
  # Struct: RoomConfig
  # ---------------------------------------------------------------------------

  @doc "Encode a RoomConfig struct to Bebop binary."
  def encode_room_config(%{room_id: room_id, name: name, room_type: rt, max_participants: mp,
                           bitrate: br, e2ee_required: e2ee, recording_active: rec,
                           spatial_audio: spatial, region: region}) do
    VS.encode_string(room_id) <>
      VS.encode_string(name) <>
      <<room_type(rt)::8>> <>
      <<mp::32-little>> <>
      <<br::32-little>> <>
      VS.encode_bool(e2ee) <>
      VS.encode_bool(rec) <>
      VS.encode_bool(spatial) <>
      VS.encode_string(region)
  end

  @doc "Decode a RoomConfig struct. Returns {config_map, rest}."
  def decode_room_config(data) do
    {room_id, rest1} = VS.decode_string(data)
    {name, rest2} = VS.decode_string(rest1)
    <<rt_raw::8, rest3::binary>> = rest2
    <<mp::32-little, rest4::binary>> = rest3
    <<br::32-little, rest5::binary>> = rest4
    {e2ee, rest6} = VS.decode_bool(rest5)
    {rec, rest7} = VS.decode_bool(rest6)
    {spatial, rest8} = VS.decode_bool(rest7)
    {region, rest9} = VS.decode_string(rest8)
    {%{room_id: room_id, name: name, room_type: room_type(rt_raw), max_participants: mp,
       bitrate: br, e2ee_required: e2ee, recording_active: rec,
       spatial_audio: spatial, region: region}, rest9}
  end

  # ---------------------------------------------------------------------------
  # Message: ParticipantJoined (tag 1)
  # ---------------------------------------------------------------------------

  @doc "Encode a ParticipantJoined message to Bebop binary."
  def encode_participant_joined(%{room_id: room_id, participant: participant, timestamp: timestamp, participant_count: count}) do
    VS.encode_string(room_id) <>
      encode_participant(participant) <>
      VS.encode_string(timestamp) <>
      <<count::32-little>>
  end

  @doc "Decode a ParticipantJoined message. Returns {msg_map, rest}."
  def decode_participant_joined(data) do
    {room_id, rest1} = VS.decode_string(data)
    {participant, rest2} = decode_participant(rest1)
    {timestamp, rest3} = VS.decode_string(rest2)
    <<count::32-little, rest4::binary>> = rest3
    {%{room_id: room_id, participant: participant, timestamp: timestamp, participant_count: count}, rest4}
  end

  # ---------------------------------------------------------------------------
  # Message: ParticipantLeft (tag 2)
  # ---------------------------------------------------------------------------

  @doc "Encode a ParticipantLeft message to Bebop binary."
  def encode_participant_left(%{room_id: room_id, user_id: user_id, reason: reason, timestamp: timestamp, participant_count: count}) do
    VS.encode_string(room_id) <>
      VS.encode_string(user_id) <>
      <<leave_reason(reason)::8>> <>
      VS.encode_string(timestamp) <>
      <<count::32-little>>
  end

  @doc "Decode a ParticipantLeft message. Returns {msg_map, rest}."
  def decode_participant_left(data) do
    {room_id, rest1} = VS.decode_string(data)
    {user_id, rest2} = VS.decode_string(rest1)
    <<reason_raw::8, rest3::binary>> = rest2
    {timestamp, rest4} = VS.decode_string(rest3)
    <<count::32-little, rest5::binary>> = rest4
    {%{room_id: room_id, user_id: user_id, reason: leave_reason(reason_raw),
       timestamp: timestamp, participant_count: count}, rest5}
  end

  # ---------------------------------------------------------------------------
  # Message: VoiceStateChanged (tag 3)
  # ---------------------------------------------------------------------------

  @doc "Encode a VoiceStateChanged message to Bebop binary."
  def encode_voice_state_changed(%{room_id: room_id, user_id: user_id, voice_state: voice_state, role: role, timestamp: timestamp}) do
    VS.encode_string(room_id) <>
      VS.encode_string(user_id) <>
      encode_voice_state(voice_state) <>
      <<participant_role(role)::8>> <>
      VS.encode_string(timestamp)
  end

  @doc "Decode a VoiceStateChanged message. Returns {msg_map, rest}."
  def decode_voice_state_changed(data) do
    {room_id, rest1} = VS.decode_string(data)
    {user_id, rest2} = VS.decode_string(rest1)
    {voice_state, rest3} = decode_voice_state(rest2)
    <<role_raw::8, rest4::binary>> = rest3
    {timestamp, rest5} = VS.decode_string(rest4)
    {%{room_id: room_id, user_id: user_id, voice_state: voice_state,
       role: participant_role(role_raw), timestamp: timestamp}, rest5}
  end

  # ---------------------------------------------------------------------------
  # Message: RoomConfigUpdated (tag 4)
  # ---------------------------------------------------------------------------

  @doc "Encode a RoomConfigUpdated message to Bebop binary."
  def encode_room_config_updated(%{room_id: room_id, config: config, changed_by: changed_by, timestamp: timestamp}) do
    VS.encode_string(room_id) <>
      encode_room_config(config) <>
      VS.encode_string(changed_by) <>
      VS.encode_string(timestamp)
  end

  @doc "Decode a RoomConfigUpdated message. Returns {msg_map, rest}."
  def decode_room_config_updated(data) do
    {room_id, rest1} = VS.decode_string(data)
    {config, rest2} = decode_room_config(rest1)
    {changed_by, rest3} = VS.decode_string(rest2)
    {timestamp, rest4} = VS.decode_string(rest3)
    {%{room_id: room_id, config: config, changed_by: changed_by, timestamp: timestamp}, rest4}
  end

  # ---------------------------------------------------------------------------
  # Union: RoomEvent — top-level encode/decode
  # ---------------------------------------------------------------------------

  @doc """
  Encode a RoomEvent union variant to binary with discriminator tag.

  Accepts `{:variant_atom, message_map}` and returns the complete Bebop
  binary including the 1-byte discriminator prefix.
  """
  def encode({:participant_joined, msg}), do: <<1::8, encode_participant_joined(msg)::binary>>
  def encode({:participant_left, msg}), do: <<2::8, encode_participant_left(msg)::binary>>
  def encode({:voice_state_changed, msg}), do: <<3::8, encode_voice_state_changed(msg)::binary>>
  def encode({:room_config_updated, msg}), do: <<4::8, encode_room_config_updated(msg)::binary>>

  def encode({unknown, _msg}) do
    raise ArgumentError, "Unknown RoomEvent variant: #{inspect(unknown)}"
  end

  @doc """
  Decode a RoomEvent union from binary.

  Returns `{:variant_atom, message_map, remaining_binary}` on success,
  or `{:error, reason}` on failure.
  """
  def decode(<<1::8, payload::binary>>) do
    {msg, rest} = decode_participant_joined(payload)
    {:participant_joined, msg, rest}
  end

  def decode(<<2::8, payload::binary>>) do
    {msg, rest} = decode_participant_left(payload)
    {:participant_left, msg, rest}
  end

  def decode(<<3::8, payload::binary>>) do
    {msg, rest} = decode_voice_state_changed(payload)
    {:voice_state_changed, msg, rest}
  end

  def decode(<<4::8, payload::binary>>) do
    {msg, rest} = decode_room_config_updated(payload)
    {:room_config_updated, msg, rest}
  end

  def decode(<<tag::8, _::binary>>) do
    {:error, "Unknown RoomEvent discriminator tag: #{tag}"}
  end

  def decode(<<>>) do
    {:error, "Empty input — no discriminator tag"}
  end
end
