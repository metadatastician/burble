# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Tests for Burble.Rooms.Participant — participant state struct.

defmodule Burble.Rooms.ParticipantTest do
  use ExUnit.Case, async: true

  alias Burble.Rooms.Participant

  describe "new/2" do
    test "creates a participant with defaults" do
      p = Participant.new("user-1", %{display_name: "Alice"})
      assert p.user_id == "user-1"
      assert p.display_name == "Alice"
      assert p.voice_state == :connected
      assert p.is_speaking == false
      assert p.volume == 1.0
      assert %DateTime{} = p.joined_at
    end

    test "defaults display_name to Guest when not provided" do
      p = Participant.new("user-1", %{})
      assert p.display_name == "Guest"
    end
  end

  describe "set_voice_state/2" do
    test "transitions to :muted" do
      p = Participant.new("user-1", %{display_name: "A"})
      updated = Participant.set_voice_state(p, :muted)
      assert updated.voice_state == :muted
    end

    test "transitions to :deafened" do
      p = Participant.new("user-1", %{display_name: "A"})
      updated = Participant.set_voice_state(p, :deafened)
      assert updated.voice_state == :deafened
    end

    test "transitions to :priority sets is_speaking true" do
      p = Participant.new("user-1", %{display_name: "A"})
      updated = Participant.set_voice_state(p, :priority)
      assert updated.voice_state == :priority
      assert updated.is_speaking == true
    end

    test "transitions back to :connected sets is_speaking true" do
      p = Participant.new("user-1", %{display_name: "A"})
      muted = Participant.set_voice_state(p, :muted)
      reconnected = Participant.set_voice_state(muted, :connected)
      assert reconnected.voice_state == :connected
      assert reconnected.is_speaking == true
    end
  end

  describe "set_volume/2" do
    test "sets volume within range" do
      p = Participant.new("user-1", %{display_name: "A"})
      updated = Participant.set_volume(p, 1.5)
      assert updated.volume == 1.5
    end

    test "accepts 0.0 (mute)" do
      p = Participant.new("user-1", %{display_name: "A"})
      updated = Participant.set_volume(p, 0.0)
      assert updated.volume == 0.0
    end

    test "accepts 2.0 (max boost)" do
      p = Participant.new("user-1", %{display_name: "A"})
      updated = Participant.set_volume(p, 2.0)
      assert updated.volume == 2.0
    end

    test "rejects volume below 0.0" do
      p = Participant.new("user-1", %{display_name: "A"})
      assert_raise FunctionClauseError, fn -> Participant.set_volume(p, -0.1) end
    end

    test "rejects volume above 2.0" do
      p = Participant.new("user-1", %{display_name: "A"})
      assert_raise FunctionClauseError, fn -> Participant.set_volume(p, 2.1) end
    end
  end

  describe "summarise/1" do
    test "returns a map without internal fields" do
      p = Participant.new("user-1", %{display_name: "Alice"})
      summary = Participant.summarise(p)

      assert summary.user_id == "user-1"
      assert summary.display_name == "Alice"
      assert summary.voice_state == :connected
      assert Map.has_key?(summary, :is_speaking)
      assert Map.has_key?(summary, :volume)
      refute Map.has_key?(summary, :joined_at)
    end
  end
end
