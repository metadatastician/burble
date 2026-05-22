# SPDX-License-Identifier: MPL-2.0
#
# Tests for Burble.Audit — audit log entry creation.

defmodule Burble.AuditTest do
  use ExUnit.Case, async: true

  alias Burble.Audit

  describe "log/3" do
    test "returns {:ok, entry} tuple" do
      assert {:ok, entry} = Audit.log(:test_action, "actor-1")
      assert is_map(entry)
    end

    test "entry contains the action, actor_id, and timestamp" do
      {:ok, entry} = Audit.log(:mod_kick, "moderator-99")
      assert entry.action == :mod_kick
      assert entry.actor_id == "moderator-99"
      assert %DateTime{} = entry.timestamp
    end

    test "entry contains metadata when provided" do
      meta = %{target_id: "user-7", room_id: "room-a", reason: "spam"}
      {:ok, entry} = Audit.log(:mod_ban, "admin-1", meta)
      assert entry.metadata == meta
    end

    test "metadata defaults to empty map when omitted" do
      {:ok, entry} = Audit.log(:mod_mute, "mod-2")
      assert entry.metadata == %{}
    end

    test "timestamp is in UTC" do
      {:ok, entry} = Audit.log(:mod_timeout, "actor-x", %{duration: 60})
      assert entry.timestamp.time_zone == "Etc/UTC"
    end

    test "does not crash with atom action and numeric actor_id string" do
      assert {:ok, _} = Audit.log(:room_created, "0", %{room_id: "r-1"})
    end
  end
end
