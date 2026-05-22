# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)

defmodule Burble.Bebop.RoomEventTest do
  use ExUnit.Case, async: true

  alias Burble.Bebop.RoomEvent

  @sample_voice_state %{muted: false, deafened: false, speaking: true, streaming: false, mute_type: 0}
  @sample_participant %{
    user_id: "user-1",
    display_name: "Alice",
    avatar_url: "https://example.com/alice.png",
    role: :speaker,
    voice_state: @sample_voice_state
  }
  @sample_config %{
    room_id: "room-1",
    name: "Test Room",
    room_type: :voice,
    max_participants: 25,
    bitrate: 64000,
    e2ee_required: true,
    recording_active: false,
    spatial_audio: false,
    region: "eu-west"
  }

  describe "ParticipantJoined" do
    test "roundtrips" do
      msg = {:participant_joined, %{
        room_id: "room-1",
        participant: @sample_participant,
        timestamp: "2026-03-29T12:00:00Z",
        participant_count: 5
      }}

      encoded = RoomEvent.encode(msg)
      assert <<1::8, _::binary>> = encoded

      {:participant_joined, decoded, _} = RoomEvent.decode(encoded)
      assert decoded.room_id == "room-1"
      assert decoded.participant.user_id == "user-1"
      assert decoded.participant.display_name == "Alice"
      assert decoded.participant.role == :speaker
      assert decoded.participant.voice_state.speaking == true
      assert decoded.participant_count == 5
      assert decoded.timestamp == "2026-03-29T12:00:00Z"
    end
  end

  describe "ParticipantLeft" do
    test "roundtrips with kick reason" do
      msg = {:participant_left, %{
        room_id: "room-1",
        user_id: "user-2",
        reason: :kicked,
        timestamp: "2026-03-29T12:01:00Z",
        participant_count: 4
      }}

      encoded = RoomEvent.encode(msg)
      {:participant_left, decoded, _} = RoomEvent.decode(encoded)
      assert decoded.reason == :kicked
      assert decoded.participant_count == 4
    end
  end

  describe "VoiceStateChanged" do
    test "roundtrips" do
      msg = {:voice_state_changed, %{
        room_id: "room-1",
        user_id: "user-1",
        voice_state: @sample_voice_state,
        role: :moderator,
        timestamp: "2026-03-29T12:02:00Z"
      }}

      encoded = RoomEvent.encode(msg)
      {:voice_state_changed, decoded, _} = RoomEvent.decode(encoded)
      assert decoded.role == :moderator
      assert decoded.voice_state.speaking == true
    end
  end

  describe "RoomConfigUpdated" do
    test "roundtrips full config" do
      msg = {:room_config_updated, %{
        room_id: "room-1",
        config: @sample_config,
        changed_by: "admin-1",
        timestamp: "2026-03-29T12:03:00Z"
      }}

      encoded = RoomEvent.encode(msg)
      {:room_config_updated, decoded, _} = RoomEvent.decode(encoded)
      assert decoded.config.room_type == :voice
      assert decoded.config.max_participants == 25
      assert decoded.config.bitrate == 64000
      assert decoded.config.e2ee_required == true
      assert decoded.config.region == "eu-west"
      assert decoded.changed_by == "admin-1"
    end
  end

  describe "unknown tag" do
    test "returns error" do
      assert {:error, _} = RoomEvent.decode(<<99::8, 0, 0, 0>>)
    end
  end
end
