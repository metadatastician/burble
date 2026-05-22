# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)

defmodule Burble.Bebop.VoiceSignalTest do
  use ExUnit.Case, async: true

  alias Burble.Bebop.VoiceSignal

  describe "string encoding" do
    test "roundtrips a simple string" do
      encoded = VoiceSignal.encode_string("hello")
      {decoded, rest} = VoiceSignal.decode_string(encoded)
      assert decoded == "hello"
      assert rest == <<>>
    end

    test "roundtrips an empty string" do
      encoded = VoiceSignal.encode_string("")
      {decoded, rest} = VoiceSignal.decode_string(encoded)
      assert decoded == ""
      assert rest == <<>>
    end

    test "roundtrips UTF-8" do
      encoded = VoiceSignal.encode_string("Wittgenstein says: 'The limits of my language mean the limits of my world.'")
      {decoded, _} = VoiceSignal.decode_string(encoded)
      assert decoded == "Wittgenstein says: 'The limits of my language mean the limits of my world.'"
    end
  end

  describe "Vec3 encoding" do
    test "roundtrips a position" do
      vec = %{x: 1.5, y: 2.5, z: 3.5}
      encoded = VoiceSignal.encode_vec3(vec)
      {decoded, rest} = VoiceSignal.decode_vec3(encoded)
      assert_in_delta decoded.x, 1.5, 0.001
      assert_in_delta decoded.y, 2.5, 0.001
      assert_in_delta decoded.z, 3.5, 0.001
      assert rest == <<>>
    end
  end

  describe "Join message" do
    test "roundtrips" do
      msg = {:join, %{
        room_id: "room-123",
        user_id: "user-456",
        display_name: "Alice",
        codec: :opus,
        self_muted: false,
        position: %{x: 0.0, y: 0.0, z: 0.0}
      }}

      encoded = VoiceSignal.encode(msg)
      assert <<1::8, _::binary>> = encoded

      {:join, decoded, rest} = VoiceSignal.decode(encoded)
      assert decoded.room_id == "room-123"
      assert decoded.user_id == "user-456"
      assert decoded.display_name == "Alice"
      assert decoded.codec == :opus
      assert decoded.self_muted == false
      assert rest == <<>>
    end
  end

  describe "Leave message" do
    test "roundtrips" do
      msg = {:leave, %{room_id: "room-1", user_id: "user-2", reason: "user"}}
      encoded = VoiceSignal.encode(msg)
      {:leave, decoded, _} = VoiceSignal.decode(encoded)
      assert decoded.room_id == "room-1"
      assert decoded.reason == "user"
    end
  end

  describe "Mute message" do
    test "roundtrips self_muted" do
      msg = {:mute, %{room_id: "r", user_id: "u", state: :self_muted}}
      encoded = VoiceSignal.encode(msg)
      {:mute, decoded, _} = VoiceSignal.decode(encoded)
      assert decoded.state == :self_muted
    end
  end

  describe "Unmute message" do
    test "roundtrips" do
      msg = {:unmute, %{room_id: "r", user_id: "u"}}
      encoded = VoiceSignal.encode(msg)
      {:unmute, decoded, _} = VoiceSignal.decode(encoded)
      assert decoded.room_id == "r"
    end
  end

  describe "Deafen message" do
    test "roundtrips" do
      msg = {:deafen, %{room_id: "r", user_id: "u", state: :self_deafened}}
      encoded = VoiceSignal.encode(msg)
      {:deafen, decoded, _} = VoiceSignal.decode(encoded)
      assert decoded.state == :self_deafened
    end
  end

  describe "SpeakingStart message" do
    test "roundtrips with audio level" do
      msg = {:speaking_start, %{room_id: "r", user_id: "u", audio_level: 0.75}}
      encoded = VoiceSignal.encode(msg)
      {:speaking_start, decoded, _} = VoiceSignal.decode(encoded)
      assert_in_delta decoded.audio_level, 0.75, 0.001
    end
  end

  describe "SpeakingStop message" do
    test "roundtrips" do
      msg = {:speaking_stop, %{room_id: "r", user_id: "u"}}
      encoded = VoiceSignal.encode(msg)
      {:speaking_stop, decoded, _} = VoiceSignal.decode(encoded)
      assert decoded.user_id == "u"
    end
  end

  describe "PositionUpdate message" do
    test "roundtrips with orientation" do
      msg = {:position_update, %{room_id: "r", user_id: "u", position: %{x: 10.0, y: 20.0, z: 30.0}, orientation: 1.57}}
      encoded = VoiceSignal.encode(msg)
      {:position_update, decoded, _} = VoiceSignal.decode(encoded)
      assert_in_delta decoded.position.x, 10.0, 0.001
      assert_in_delta decoded.orientation, 1.57, 0.01
    end
  end

  describe "Offer message" do
    test "roundtrips with SDP" do
      msg = {:offer, %{room_id: "r", user_id: "u", sdp: %{sdp: "v=0\r\n...", media_type: "audio"}}}
      encoded = VoiceSignal.encode(msg)
      {:offer, decoded, _} = VoiceSignal.decode(encoded)
      assert decoded.sdp.sdp == "v=0\r\n..."
      assert decoded.sdp.media_type == "audio"
    end
  end

  describe "Answer message" do
    test "roundtrips with SDP" do
      msg = {:answer, %{room_id: "r", user_id: "u", sdp: %{sdp: "v=0\r\nanswer", media_type: "audio"}}}
      encoded = VoiceSignal.encode(msg)
      {:answer, decoded, _} = VoiceSignal.decode(encoded)
      assert decoded.sdp.sdp == "v=0\r\nanswer"
    end
  end

  describe "IceCandidate message" do
    test "roundtrips" do
      msg = {:ice_candidate, %{
        room_id: "r", user_id: "u",
        candidate: %{candidate: "candidate:1 1 UDP ...", sdp_m_line_index: 0, sdp_mid: "audio", username_fragment: "frag123"}
      }}
      encoded = VoiceSignal.encode(msg)
      {:ice_candidate, decoded, _} = VoiceSignal.decode(encoded)
      assert decoded.candidate.candidate == "candidate:1 1 UDP ..."
      assert decoded.candidate.sdp_m_line_index == 0
      assert decoded.candidate.sdp_mid == "audio"
    end
  end

  describe "unknown tag" do
    test "returns error" do
      assert {:error, _} = VoiceSignal.decode(<<99::8, 0, 0, 0>>)
    end
  end
end
