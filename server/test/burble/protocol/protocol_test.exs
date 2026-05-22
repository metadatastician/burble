# SPDX-License-Identifier: MPL-2.0
#
# Tests for Burble.Protocol — Bebop codec modules.
#
# Covers message type definitions (enum round-trips) and the top-level
# encode/decode union for both RoomEvent and VoiceSignal.

defmodule Burble.ProtocolTest do
  use ExUnit.Case, async: true

  alias Burble.Protocol.RoomEvent
  alias Burble.Protocol.VoiceSignal

  describe "RoomEvent enum round-trips" do
    test "room_type atoms encode to integers and back" do
      for atom <- [:voice, :stage, :broadcast, :spatial] do
        int = RoomEvent.room_type(atom)
        assert is_integer(int)
        assert RoomEvent.room_type(int) == atom
      end
    end

    test "leave_reason atoms encode to integers and back" do
      for atom <- [:voluntary, :kicked, :banned, :timeout, :server_shutdown] do
        int = RoomEvent.leave_reason(atom)
        assert is_integer(int)
        assert RoomEvent.leave_reason(int) == atom
      end
    end

    test "participant_role atoms encode to integers and back" do
      for atom <- [:listener, :speaker, :moderator, :owner] do
        int = RoomEvent.participant_role(atom)
        assert is_integer(int)
        assert RoomEvent.participant_role(int) == atom
      end
    end
  end

  describe "VoiceSignal enum round-trips" do
    test "audio_codec atoms encode to integers and back" do
      for atom <- [:opus, :lyra] do
        int = VoiceSignal.audio_codec(atom)
        assert is_integer(int)
        assert VoiceSignal.audio_codec(int) == atom
      end
    end

    test "mute_state atoms encode to integers and back" do
      for atom <- [:unmuted, :self_muted, :server_muted] do
        int = VoiceSignal.mute_state(atom)
        assert is_integer(int)
        assert VoiceSignal.mute_state(int) == atom
      end
    end
  end

  describe "RoomEvent encode/decode" do
    test "participant_joined round-trips through encode/decode" do
      msg = %{
        room_id: "room-1",
        participant: %{
          user_id: "u-1",
          display_name: "Alice",
          avatar_url: "",
          role: :speaker,
          voice_state: %{muted: false, deafened: false, speaking: true, streaming: false, mute_type: 0}
        },
        timestamp: "2026-04-20T00:00:00Z",
        participant_count: 1
      }

      binary = RoomEvent.encode({:participant_joined, msg})
      assert is_binary(binary)
      assert {:participant_joined, decoded, <<>>} = RoomEvent.decode(binary)
      assert decoded.room_id == "room-1"
      assert decoded.participant.display_name == "Alice"
    end

    test "decode returns error for unknown discriminator tag" do
      assert {:error, _reason} = RoomEvent.decode(<<99::8, 0::8>>)
    end
  end
end
