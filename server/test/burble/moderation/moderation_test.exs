# SPDX-License-Identifier: MPL-2.0
#
# Tests for Burble.Moderation — permission checks and action type coverage.
#
# These tests focus on the parts that do NOT require a running Room or
# MediaEngine. The permission check is the outermost guard on every
# action, so it can be exercised with an empty MapSet without touching
# the room/media layer.

defmodule Burble.ModerationTest do
  use ExUnit.Case, async: true

  alias Burble.Moderation

  @no_perms MapSet.new()

  # ---------------------------------------------------------------------------
  # Module existence
  # ---------------------------------------------------------------------------

  describe "module" do
    test "Burble.Moderation is loaded" do
      assert Code.ensure_loaded?(Burble.Moderation)
    end

    test "all expected public functions are exported" do
      exports = Burble.Moderation.__info__(:functions)
      assert {:kick, 5} in exports
      assert {:ban, 6} in exports
      assert {:mute, 5} in exports
      assert {:move, 5} in exports
      assert {:timeout, 5} in exports
    end
  end

  # ---------------------------------------------------------------------------
  # Permission guard — common to all action types
  # ---------------------------------------------------------------------------

  describe "insufficient permissions" do
    test "kick/5 returns {:error, :insufficient_permissions} without :kick perm" do
      assert {:error, :insufficient_permissions} =
               Moderation.kick("mod", "user", "room", "reason", @no_perms)
    end

    test "ban/6 returns {:error, :insufficient_permissions} without :ban perm" do
      assert {:error, :insufficient_permissions} =
               Moderation.ban("mod", "user", "server", "reason", nil, @no_perms)
    end

    test "mute/5 returns {:error, :insufficient_permissions} without :mute_others perm" do
      assert {:error, :insufficient_permissions} =
               Moderation.mute("mod", "user", "room", 30, @no_perms)
    end

    test "move/5 returns {:error, :insufficient_permissions} without :move_others perm" do
      assert {:error, :insufficient_permissions} =
               Moderation.move("mod", "user", "room-a", "room-b", @no_perms)
    end
  end

  # ---------------------------------------------------------------------------
  # timeout/5 — invalid duration guard is checked before permission
  # ---------------------------------------------------------------------------

  describe "timeout/5" do
    test "returns {:error, :invalid_duration} for zero duration" do
      assert {:error, :invalid_duration} =
               Moderation.timeout("mod", "user", "room", 0, @no_perms)
    end

    test "returns {:error, :insufficient_permissions} for valid duration without perms" do
      assert {:error, :insufficient_permissions} =
               Moderation.timeout("mod", "user", "room", 60, @no_perms)
    end
  end
end
