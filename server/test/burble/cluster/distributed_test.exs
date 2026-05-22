# SPDX-License-Identifier: MPL-2.0
#
# Tests for Burble.Cluster.Distributed — multi-region clustering.

defmodule Burble.Cluster.DistributedTest do
  use ExUnit.Case, async: false

  alias Burble.Cluster.Distributed

  setup do
    start_supervised!({Distributed, region: "us-east-1"})
    :ok
  end

  describe "region/0" do
    test "returns the configured region" do
      assert "us-east-1" == Distributed.region()
    end
  end

  describe "peers/0" do
    test "returns empty map initially (no other nodes)" do
      peers = Distributed.peers()
      assert peers == %{}
    end
  end

  describe "peers_in_region/1" do
    test "returns empty map for unknown region" do
      assert %{} == Distributed.peers_in_region("ap-southeast-1")
    end
  end

  describe "register_room/2 and locate_room/1" do
    test "registered room can be located" do
      Distributed.register_room("test-room-1", %{creator: "user1"})

      # Give the cast time to process.
      Process.sleep(50)

      assert {:ok, info} = Distributed.locate_room("test-room-1")
      assert info.region == "us-east-1"
    end

    test "unregistered room returns :not_found" do
      assert {:error, :not_found} = Distributed.locate_room("nonexistent-room")
    end
  end

  describe "best_node_for_room/1" do
    test "returns self node when no peers exist" do
      {:ok, node} = Distributed.best_node_for_room(["us-east-1", "us-east-1"])
      assert is_binary(node)
    end

    test "handles empty participant list" do
      {:ok, node} = Distributed.best_node_for_room([])
      assert is_binary(node)
    end
  end

  describe "health/0" do
    test "returns health map with expected fields" do
      health = Distributed.health()
      assert health.region == "us-east-1"
      assert health.active_peers == 0
      assert health.total_peers == 0
      assert health.rooms_hosted == 0
      assert health.uptime_ms >= 0
    end
  end
end
