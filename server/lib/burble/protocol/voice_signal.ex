# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Generated from: priv/schemas/voice_signal.bop
# Generator: mix bebop.generate
# DO NOT EDIT — regenerate with `mix bebop.generate`
#
# Bebop wire format: little-endian, length-prefixed strings (uint32 + UTF-8),
# 1-byte union discriminator tag.

defmodule Burble.Protocol.VoiceSignal do
  @moduledoc """
  Bebop encoder/decoder for voice_signal.

  Auto-generated from `priv/schemas/voice_signal.bop`. Provides `encode/1`
  and `decode/1` for the VoiceSignal union type, plus struct encode/decode
  helpers for Vec3, IceCandidatePayload, and SdpPayload.

  ## Wire format

  Each VoiceSignal message is prefixed with a 1-byte discriminator tag:

  | Tag | Variant        | Direction          |
  |-----|----------------|--------------------|
  |  1  | Join           | Client -> Server   |
  |  2  | Leave          | Client -> Server   |
  |  3  | Mute           | Client -> Server   |
  |  4  | Unmute         | Client -> Server   |
  |  5  | Deafen         | Client -> Server   |
  |  6  | SpeakingStart  | Server -> Client   |
  |  7  | SpeakingStop   | Server -> Client   |
  |  8  | PositionUpdate | Bidirectional      |
  |  9  | Offer          | Client -> Server   |
  | 10  | Answer         | Server -> Client   |
  | 11  | IceCandidate   | Bidirectional      |
  """

  # ---------------------------------------------------------------------------
  # Enum: AudioCodec
  # ---------------------------------------------------------------------------

  @doc "AudioCodec enum — Opus (1) or Lyra (2)."
  def audio_codec(:opus), do: 1
  def audio_codec(:lyra), do: 2
  def audio_codec(1), do: :opus
  def audio_codec(2), do: :lyra

  # ---------------------------------------------------------------------------
  # Enum: MuteState
  # ---------------------------------------------------------------------------

  @doc "MuteState enum — Unmuted (0), SelfMuted (1), ServerMuted (2)."
  def mute_state(:unmuted), do: 0
  def mute_state(:self_muted), do: 1
  def mute_state(:server_muted), do: 2
  def mute_state(0), do: :unmuted
  def mute_state(1), do: :self_muted
  def mute_state(2), do: :server_muted

  # ---------------------------------------------------------------------------
  # Enum: DeafenState
  # ---------------------------------------------------------------------------

  @doc "DeafenState enum — Undeafened (0), SelfDeafened (1), ServerDeafened (2)."
  def deafen_state(:undeafened), do: 0
  def deafen_state(:self_deafened), do: 1
  def deafen_state(:server_deafened), do: 2
  def deafen_state(0), do: :undeafened
  def deafen_state(1), do: :self_deafened
  def deafen_state(2), do: :server_deafened

  # ---------------------------------------------------------------------------
  # Struct: Vec3
  # ---------------------------------------------------------------------------

  @doc "Encode a Vec3 struct (3x float32-LE) to Bebop binary."
  def encode_vec3(%{x: x, y: y, z: z}) do
    <<x::float-little-32, y::float-little-32, z::float-little-32>>
  end

  @doc "Decode a Vec3 struct from Bebop binary. Returns {%{x, y, z}, rest}."
  def decode_vec3(data) do
    <<x::float-little-32, y::float-little-32, z::float-little-32, rest::binary>> = data
    {%{x: x, y: y, z: z}, rest}
  end

  # ---------------------------------------------------------------------------
  # Struct: IceCandidatePayload
  # ---------------------------------------------------------------------------

  @doc "Encode an IceCandidatePayload struct to Bebop binary."
  def encode_ice_candidate_payload(%{candidate: candidate, sdp_m_line_index: sdp_m_line_index, sdp_mid: sdp_mid, username_fragment: username_fragment}) do
    encode_string(candidate) <>
      <<sdp_m_line_index::16-little>> <>
      encode_string(sdp_mid) <>
      encode_string(username_fragment)
  end

  @doc "Decode an IceCandidatePayload struct. Returns {payload_map, rest}."
  def decode_ice_candidate_payload(data) do
    {candidate, rest1} = decode_string(data)
    <<sdp_m_line_index::16-little, rest2::binary>> = rest1
    {sdp_mid, rest3} = decode_string(rest2)
    {username_fragment, rest4} = decode_string(rest3)
    {%{candidate: candidate, sdp_m_line_index: sdp_m_line_index, sdp_mid: sdp_mid, username_fragment: username_fragment}, rest4}
  end

  # ---------------------------------------------------------------------------
  # Struct: SdpPayload
  # ---------------------------------------------------------------------------

  @doc "Encode an SdpPayload struct to Bebop binary."
  def encode_sdp_payload(%{sdp: sdp, media_type: media_type}) do
    encode_string(sdp) <> encode_string(media_type)
  end

  @doc "Decode an SdpPayload struct. Returns {payload_map, rest}."
  def decode_sdp_payload(data) do
    {sdp, rest1} = decode_string(data)
    {media_type, rest2} = decode_string(rest1)
    {%{sdp: sdp, media_type: media_type}, rest2}
  end

  # ---------------------------------------------------------------------------
  # Message: Join (tag 1)
  # ---------------------------------------------------------------------------

  @doc "Encode a Join message to Bebop binary (no discriminator tag)."
  def encode_join(%{room_id: room_id, user_id: user_id, display_name: display_name, codec: codec, self_muted: self_muted, position: position}) do
    encode_string(room_id) <>
      encode_string(user_id) <>
      encode_string(display_name) <>
      <<audio_codec(codec)::8>> <>
      encode_bool(self_muted) <>
      encode_vec3(position)
  end

  @doc "Decode a Join message. Returns {msg_map, rest}."
  def decode_join(data) do
    {room_id, rest1} = decode_string(data)
    {user_id, rest2} = decode_string(rest1)
    {display_name, rest3} = decode_string(rest2)
    <<codec_raw::8, rest4::binary>> = rest3
    codec = audio_codec(codec_raw)
    {self_muted, rest5} = decode_bool(rest4)
    {position, rest6} = decode_vec3(rest5)
    {%{room_id: room_id, user_id: user_id, display_name: display_name,
       codec: codec, self_muted: self_muted, position: position}, rest6}
  end

  # ---------------------------------------------------------------------------
  # Message: Leave (tag 2)
  # ---------------------------------------------------------------------------

  @doc "Encode a Leave message to Bebop binary."
  def encode_leave(%{room_id: room_id, user_id: user_id, reason: reason}) do
    encode_string(room_id) <> encode_string(user_id) <> encode_string(reason)
  end

  @doc "Decode a Leave message. Returns {msg_map, rest}."
  def decode_leave(data) do
    {room_id, rest1} = decode_string(data)
    {user_id, rest2} = decode_string(rest1)
    {reason, rest3} = decode_string(rest2)
    {%{room_id: room_id, user_id: user_id, reason: reason}, rest3}
  end

  # ---------------------------------------------------------------------------
  # Message: Mute (tag 3)
  # ---------------------------------------------------------------------------

  @doc "Encode a Mute message to Bebop binary."
  def encode_mute(%{room_id: room_id, user_id: user_id, state: state}) do
    encode_string(room_id) <> encode_string(user_id) <> <<mute_state(state)::8>>
  end

  @doc "Decode a Mute message. Returns {msg_map, rest}."
  def decode_mute(data) do
    {room_id, rest1} = decode_string(data)
    {user_id, rest2} = decode_string(rest1)
    <<state_raw::8, rest3::binary>> = rest2
    state = mute_state(state_raw)
    {%{room_id: room_id, user_id: user_id, state: state}, rest3}
  end

  # ---------------------------------------------------------------------------
  # Message: Unmute (tag 4)
  # ---------------------------------------------------------------------------

  @doc "Encode an Unmute message to Bebop binary."
  def encode_unmute(%{room_id: room_id, user_id: user_id}) do
    encode_string(room_id) <> encode_string(user_id)
  end

  @doc "Decode an Unmute message. Returns {msg_map, rest}."
  def decode_unmute(data) do
    {room_id, rest1} = decode_string(data)
    {user_id, rest2} = decode_string(rest1)
    {%{room_id: room_id, user_id: user_id}, rest2}
  end

  # ---------------------------------------------------------------------------
  # Message: Deafen (tag 5)
  # ---------------------------------------------------------------------------

  @doc "Encode a Deafen message to Bebop binary."
  def encode_deafen(%{room_id: room_id, user_id: user_id, state: state}) do
    encode_string(room_id) <> encode_string(user_id) <> <<deafen_state(state)::8>>
  end

  @doc "Decode a Deafen message. Returns {msg_map, rest}."
  def decode_deafen(data) do
    {room_id, rest1} = decode_string(data)
    {user_id, rest2} = decode_string(rest1)
    <<state_raw::8, rest3::binary>> = rest2
    state = deafen_state(state_raw)
    {%{room_id: room_id, user_id: user_id, state: state}, rest3}
  end

  # ---------------------------------------------------------------------------
  # Message: SpeakingStart (tag 6)
  # ---------------------------------------------------------------------------

  @doc "Encode a SpeakingStart message to Bebop binary."
  def encode_speaking_start(%{room_id: room_id, user_id: user_id, audio_level: audio_level}) do
    encode_string(room_id) <> encode_string(user_id) <> <<audio_level::float-little-32>>
  end

  @doc "Decode a SpeakingStart message. Returns {msg_map, rest}."
  def decode_speaking_start(data) do
    {room_id, rest1} = decode_string(data)
    {user_id, rest2} = decode_string(rest1)
    <<audio_level::float-little-32, rest3::binary>> = rest2
    {%{room_id: room_id, user_id: user_id, audio_level: audio_level}, rest3}
  end

  # ---------------------------------------------------------------------------
  # Message: SpeakingStop (tag 7)
  # ---------------------------------------------------------------------------

  @doc "Encode a SpeakingStop message to Bebop binary."
  def encode_speaking_stop(%{room_id: room_id, user_id: user_id}) do
    encode_string(room_id) <> encode_string(user_id)
  end

  @doc "Decode a SpeakingStop message. Returns {msg_map, rest}."
  def decode_speaking_stop(data) do
    {room_id, rest1} = decode_string(data)
    {user_id, rest2} = decode_string(rest1)
    {%{room_id: room_id, user_id: user_id}, rest2}
  end

  # ---------------------------------------------------------------------------
  # Message: PositionUpdate (tag 8)
  # ---------------------------------------------------------------------------

  @doc "Encode a PositionUpdate message to Bebop binary."
  def encode_position_update(%{room_id: room_id, user_id: user_id, position: position, orientation: orientation}) do
    encode_string(room_id) <> encode_string(user_id) <> encode_vec3(position) <> <<orientation::float-little-32>>
  end

  @doc "Decode a PositionUpdate message. Returns {msg_map, rest}."
  def decode_position_update(data) do
    {room_id, rest1} = decode_string(data)
    {user_id, rest2} = decode_string(rest1)
    {position, rest3} = decode_vec3(rest2)
    <<orientation::float-little-32, rest4::binary>> = rest3
    {%{room_id: room_id, user_id: user_id, position: position, orientation: orientation}, rest4}
  end

  # ---------------------------------------------------------------------------
  # Message: Offer (tag 9)
  # ---------------------------------------------------------------------------

  @doc "Encode an Offer message to Bebop binary."
  def encode_offer(%{room_id: room_id, user_id: user_id, sdp: sdp}) do
    encode_string(room_id) <> encode_string(user_id) <> encode_sdp_payload(sdp)
  end

  @doc "Decode an Offer message. Returns {msg_map, rest}."
  def decode_offer(data) do
    {room_id, rest1} = decode_string(data)
    {user_id, rest2} = decode_string(rest1)
    {sdp, rest3} = decode_sdp_payload(rest2)
    {%{room_id: room_id, user_id: user_id, sdp: sdp}, rest3}
  end

  # ---------------------------------------------------------------------------
  # Message: Answer (tag 10)
  # ---------------------------------------------------------------------------

  @doc "Encode an Answer message to Bebop binary."
  def encode_answer(%{room_id: room_id, user_id: user_id, sdp: sdp}) do
    encode_string(room_id) <> encode_string(user_id) <> encode_sdp_payload(sdp)
  end

  @doc "Decode an Answer message. Returns {msg_map, rest}."
  def decode_answer(data) do
    {room_id, rest1} = decode_string(data)
    {user_id, rest2} = decode_string(rest1)
    {sdp, rest3} = decode_sdp_payload(rest2)
    {%{room_id: room_id, user_id: user_id, sdp: sdp}, rest3}
  end

  # ---------------------------------------------------------------------------
  # Message: IceCandidate (tag 11)
  # ---------------------------------------------------------------------------

  @doc "Encode an IceCandidate message to Bebop binary."
  def encode_ice_candidate(%{room_id: room_id, user_id: user_id, candidate: candidate}) do
    encode_string(room_id) <> encode_string(user_id) <> encode_ice_candidate_payload(candidate)
  end

  @doc "Decode an IceCandidate message. Returns {msg_map, rest}."
  def decode_ice_candidate(data) do
    {room_id, rest1} = decode_string(data)
    {user_id, rest2} = decode_string(rest1)
    {candidate, rest3} = decode_ice_candidate_payload(rest2)
    {%{room_id: room_id, user_id: user_id, candidate: candidate}, rest3}
  end

  # ---------------------------------------------------------------------------
  # Union: VoiceSignal — top-level encode/decode
  # ---------------------------------------------------------------------------

  @doc """
  Encode a VoiceSignal union variant to binary with discriminator tag.

  Accepts `{:variant_atom, message_map}` and returns the complete Bebop
  binary including the 1-byte discriminator prefix.
  """
  def encode({:join, msg}), do: <<1::8, encode_join(msg)::binary>>
  def encode({:leave, msg}), do: <<2::8, encode_leave(msg)::binary>>
  def encode({:mute, msg}), do: <<3::8, encode_mute(msg)::binary>>
  def encode({:unmute, msg}), do: <<4::8, encode_unmute(msg)::binary>>
  def encode({:deafen, msg}), do: <<5::8, encode_deafen(msg)::binary>>
  def encode({:speaking_start, msg}), do: <<6::8, encode_speaking_start(msg)::binary>>
  def encode({:speaking_stop, msg}), do: <<7::8, encode_speaking_stop(msg)::binary>>
  def encode({:position_update, msg}), do: <<8::8, encode_position_update(msg)::binary>>
  def encode({:offer, msg}), do: <<9::8, encode_offer(msg)::binary>>
  def encode({:answer, msg}), do: <<10::8, encode_answer(msg)::binary>>
  def encode({:ice_candidate, msg}), do: <<11::8, encode_ice_candidate(msg)::binary>>

  def encode({unknown, _msg}) do
    raise ArgumentError, "Unknown VoiceSignal variant: #{inspect(unknown)}"
  end

  @doc """
  Decode a VoiceSignal union from binary.

  Returns `{:variant_atom, message_map, remaining_binary}` on success,
  or `{:error, reason}` on failure.
  """
  def decode(<<1::8, payload::binary>>) do
    {msg, rest} = decode_join(payload)
    {:join, msg, rest}
  end

  def decode(<<2::8, payload::binary>>) do
    {msg, rest} = decode_leave(payload)
    {:leave, msg, rest}
  end

  def decode(<<3::8, payload::binary>>) do
    {msg, rest} = decode_mute(payload)
    {:mute, msg, rest}
  end

  def decode(<<4::8, payload::binary>>) do
    {msg, rest} = decode_unmute(payload)
    {:unmute, msg, rest}
  end

  def decode(<<5::8, payload::binary>>) do
    {msg, rest} = decode_deafen(payload)
    {:deafen, msg, rest}
  end

  def decode(<<6::8, payload::binary>>) do
    {msg, rest} = decode_speaking_start(payload)
    {:speaking_start, msg, rest}
  end

  def decode(<<7::8, payload::binary>>) do
    {msg, rest} = decode_speaking_stop(payload)
    {:speaking_stop, msg, rest}
  end

  def decode(<<8::8, payload::binary>>) do
    {msg, rest} = decode_position_update(payload)
    {:position_update, msg, rest}
  end

  def decode(<<9::8, payload::binary>>) do
    {msg, rest} = decode_offer(payload)
    {:offer, msg, rest}
  end

  def decode(<<10::8, payload::binary>>) do
    {msg, rest} = decode_answer(payload)
    {:answer, msg, rest}
  end

  def decode(<<11::8, payload::binary>>) do
    {msg, rest} = decode_ice_candidate(payload)
    {:ice_candidate, msg, rest}
  end

  def decode(<<tag::8, _::binary>>) do
    {:error, "Unknown VoiceSignal discriminator tag: #{tag}"}
  end

  def decode(<<>>) do
    {:error, "Empty input — no discriminator tag"}
  end

  # ---------------------------------------------------------------------------
  # Primitive codecs (Bebop wire format)
  # ---------------------------------------------------------------------------

  @doc "Encode a Bebop string: uint32-LE length prefix followed by UTF-8 bytes."
  def encode_string(str) when is_binary(str) do
    len = byte_size(str)
    <<len::32-little, str::binary>>
  end

  @doc "Decode a Bebop string. Returns {string, remaining_binary}."
  def decode_string(<<len::32-little, str::binary-size(len), rest::binary>>) do
    {str, rest}
  end

  def decode_string(data), do: {"", data}

  @doc "Encode a boolean as a single byte (0 or 1)."
  def encode_bool(true), do: <<1::8>>
  def encode_bool(false), do: <<0::8>>

  @doc "Decode a boolean from a single byte."
  def decode_bool(<<1::8, rest::binary>>), do: {true, rest}
  def decode_bool(<<0::8, rest::binary>>), do: {false, rest}
  def decode_bool(<<_::8, rest::binary>>), do: {false, rest}
end
