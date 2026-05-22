# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Generated from: priv/schemas/voice_signal.bop
# DO NOT EDIT — regenerate with `mix bebop.generate`
#
# Bebop wire format: little-endian, length-prefixed strings (uint32 + UTF-8),
# 1-byte union discriminator tag.

defmodule Burble.Bebop.VoiceSignal do
  @moduledoc """
  Bebop encoder/decoder for the VoiceSignal union.

  All 11 voice signaling message types — Join, Leave, Mute, Unmute, Deafen,
  SpeakingStart, SpeakingStop, PositionUpdate, Offer, Answer, IceCandidate.
  """

  # ---------------------------------------------------------------------------
  # Enumerations
  # ---------------------------------------------------------------------------

  @doc "AudioCodec enum — Opus (1) or Lyra (2)."
  def audio_codec(:opus), do: 1
  def audio_codec(:lyra), do: 2
  def audio_codec(1), do: :opus
  def audio_codec(2), do: :lyra

  @doc "MuteState enum."
  def mute_state(:unmuted), do: 0
  def mute_state(:self_muted), do: 1
  def mute_state(:server_muted), do: 2
  def mute_state(0), do: :unmuted
  def mute_state(1), do: :self_muted
  def mute_state(2), do: :server_muted

  @doc "DeafenState enum."
  def deafen_state(:undeafened), do: 0
  def deafen_state(:self_deafened), do: 1
  def deafen_state(:server_deafened), do: 2
  def deafen_state(0), do: :undeafened
  def deafen_state(1), do: :self_deafened
  def deafen_state(2), do: :server_deafened

  # ---------------------------------------------------------------------------
  # Struct encoders/decoders
  # ---------------------------------------------------------------------------

  @doc "Encode a Vec3 struct to binary."
  def encode_vec3(%{x: x, y: y, z: z}) do
    <<x::float-little-32, y::float-little-32, z::float-little-32>>
  end

  @doc "Decode a Vec3 struct from binary."
  def decode_vec3(<<x::float-little-32, y::float-little-32, z::float-little-32, rest::binary>>) do
    {%{x: x, y: y, z: z}, rest}
  end

  @doc "Encode an IceCandidatePayload struct."
  def encode_ice_candidate_payload(%{candidate: candidate, sdp_m_line_index: idx, sdp_mid: mid, username_fragment: frag}) do
    encode_string(candidate) <> <<idx::16-little>> <> encode_string(mid) <> encode_string(frag)
  end

  @doc "Decode an IceCandidatePayload struct."
  def decode_ice_candidate_payload(data) do
    {candidate, rest} = decode_string(data)
    <<idx::16-little, rest2::binary>> = rest
    {mid, rest3} = decode_string(rest2)
    {frag, rest4} = decode_string(rest3)
    {%{candidate: candidate, sdp_m_line_index: idx, sdp_mid: mid, username_fragment: frag}, rest4}
  end

  @doc "Encode an SdpPayload struct."
  def encode_sdp_payload(%{sdp: sdp, media_type: media_type}) do
    encode_string(sdp) <> encode_string(media_type)
  end

  @doc "Decode an SdpPayload struct."
  def decode_sdp_payload(data) do
    {sdp, rest} = decode_string(data)
    {media_type, rest2} = decode_string(rest)
    {%{sdp: sdp, media_type: media_type}, rest2}
  end

  # ---------------------------------------------------------------------------
  # Message encoders — each prepends the union discriminator tag
  # ---------------------------------------------------------------------------

  @doc "Encode a VoiceSignal union variant to binary with discriminator tag."
  def encode({:join, msg}) do
    payload =
      encode_string(msg.room_id) <>
      encode_string(msg.user_id) <>
      encode_string(msg.display_name) <>
      <<audio_codec(msg.codec)::8>> <>
      encode_bool(msg.self_muted) <>
      encode_vec3(msg.position)
    <<1::8, payload::binary>>
  end

  def encode({:leave, msg}) do
    payload = encode_string(msg.room_id) <> encode_string(msg.user_id) <> encode_string(msg.reason)
    <<2::8, payload::binary>>
  end

  def encode({:mute, msg}) do
    payload = encode_string(msg.room_id) <> encode_string(msg.user_id) <> <<mute_state(msg.state)::8>>
    <<3::8, payload::binary>>
  end

  def encode({:unmute, msg}) do
    payload = encode_string(msg.room_id) <> encode_string(msg.user_id)
    <<4::8, payload::binary>>
  end

  def encode({:deafen, msg}) do
    payload = encode_string(msg.room_id) <> encode_string(msg.user_id) <> <<deafen_state(msg.state)::8>>
    <<5::8, payload::binary>>
  end

  def encode({:speaking_start, msg}) do
    payload = encode_string(msg.room_id) <> encode_string(msg.user_id) <> <<msg.audio_level::float-little-32>>
    <<6::8, payload::binary>>
  end

  def encode({:speaking_stop, msg}) do
    payload = encode_string(msg.room_id) <> encode_string(msg.user_id)
    <<7::8, payload::binary>>
  end

  def encode({:position_update, msg}) do
    payload = encode_string(msg.room_id) <> encode_string(msg.user_id) <> encode_vec3(msg.position) <> <<msg.orientation::float-little-32>>
    <<8::8, payload::binary>>
  end

  def encode({:offer, msg}) do
    payload = encode_string(msg.room_id) <> encode_string(msg.user_id) <> encode_sdp_payload(msg.sdp)
    <<9::8, payload::binary>>
  end

  def encode({:answer, msg}) do
    payload = encode_string(msg.room_id) <> encode_string(msg.user_id) <> encode_sdp_payload(msg.sdp)
    <<10::8, payload::binary>>
  end

  def encode({:ice_candidate, msg}) do
    payload = encode_string(msg.room_id) <> encode_string(msg.user_id) <> encode_ice_candidate_payload(msg.candidate)
    <<11::8, payload::binary>>
  end

  # ---------------------------------------------------------------------------
  # Union decoder — dispatches on discriminator tag
  # ---------------------------------------------------------------------------

  @doc "Decode a VoiceSignal union from binary. Returns `{variant, rest}`."
  def decode(<<1::8, payload::binary>>) do
    {room_id, rest} = decode_string(payload)
    {user_id, rest2} = decode_string(rest)
    {display_name, rest3} = decode_string(rest2)
    <<codec::8, rest4::binary>> = rest3
    {self_muted, rest5} = decode_bool(rest4)
    {position, rest6} = decode_vec3(rest5)
    {:join, %{room_id: room_id, user_id: user_id, display_name: display_name,
              codec: audio_codec(codec), self_muted: self_muted, position: position}, rest6}
  end

  def decode(<<2::8, payload::binary>>) do
    {room_id, rest} = decode_string(payload)
    {user_id, rest2} = decode_string(rest)
    {reason, rest3} = decode_string(rest2)
    {:leave, %{room_id: room_id, user_id: user_id, reason: reason}, rest3}
  end

  def decode(<<3::8, payload::binary>>) do
    {room_id, rest} = decode_string(payload)
    {user_id, rest2} = decode_string(rest)
    <<state::8, rest3::binary>> = rest2
    {:mute, %{room_id: room_id, user_id: user_id, state: mute_state(state)}, rest3}
  end

  def decode(<<4::8, payload::binary>>) do
    {room_id, rest} = decode_string(payload)
    {user_id, rest2} = decode_string(rest)
    {:unmute, %{room_id: room_id, user_id: user_id}, rest2}
  end

  def decode(<<5::8, payload::binary>>) do
    {room_id, rest} = decode_string(payload)
    {user_id, rest2} = decode_string(rest)
    <<state::8, rest3::binary>> = rest2
    {:deafen, %{room_id: room_id, user_id: user_id, state: deafen_state(state)}, rest3}
  end

  def decode(<<6::8, payload::binary>>) do
    {room_id, rest} = decode_string(payload)
    {user_id, rest2} = decode_string(rest)
    <<audio_level::float-little-32, rest3::binary>> = rest2
    {:speaking_start, %{room_id: room_id, user_id: user_id, audio_level: audio_level}, rest3}
  end

  def decode(<<7::8, payload::binary>>) do
    {room_id, rest} = decode_string(payload)
    {user_id, rest2} = decode_string(rest)
    {:speaking_stop, %{room_id: room_id, user_id: user_id}, rest2}
  end

  def decode(<<8::8, payload::binary>>) do
    {room_id, rest} = decode_string(payload)
    {user_id, rest2} = decode_string(rest)
    {position, rest3} = decode_vec3(rest2)
    <<orientation::float-little-32, rest4::binary>> = rest3
    {:position_update, %{room_id: room_id, user_id: user_id, position: position, orientation: orientation}, rest4}
  end

  def decode(<<9::8, payload::binary>>) do
    {room_id, rest} = decode_string(payload)
    {user_id, rest2} = decode_string(rest)
    {sdp, rest3} = decode_sdp_payload(rest2)
    {:offer, %{room_id: room_id, user_id: user_id, sdp: sdp}, rest3}
  end

  def decode(<<10::8, payload::binary>>) do
    {room_id, rest} = decode_string(payload)
    {user_id, rest2} = decode_string(rest)
    {sdp, rest3} = decode_sdp_payload(rest2)
    {:answer, %{room_id: room_id, user_id: user_id, sdp: sdp}, rest3}
  end

  def decode(<<11::8, payload::binary>>) do
    {room_id, rest} = decode_string(payload)
    {user_id, rest2} = decode_string(rest)
    {candidate, rest3} = decode_ice_candidate_payload(rest2)
    {:ice_candidate, %{room_id: room_id, user_id: user_id, candidate: candidate}, rest3}
  end

  def decode(<<tag::8, _::binary>>) do
    {:error, "Unknown VoiceSignal discriminator tag: #{tag}"}
  end

  # ---------------------------------------------------------------------------
  # Primitive encoders/decoders
  # ---------------------------------------------------------------------------

  @doc "Encode a Bebop string (uint32 length prefix + UTF-8 bytes)."
  def encode_string(str) when is_binary(str) do
    len = byte_size(str)
    <<len::32-little, str::binary>>
  end

  @doc "Decode a Bebop string."
  def decode_string(<<len::32-little, str::binary-size(len), rest::binary>>) do
    {str, rest}
  end
  def decode_string(data), do: {"", data}

  @doc "Encode a boolean (1 byte: 0 or 1)."
  def encode_bool(true), do: <<1::8>>
  def encode_bool(false), do: <<0::8>>

  @doc "Decode a boolean."
  def decode_bool(<<1::8, rest::binary>>), do: {true, rest}
  def decode_bool(<<0::8, rest::binary>>), do: {false, rest}
  def decode_bool(<<_::8, rest::binary>>), do: {false, rest}
end
