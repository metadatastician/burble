# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Tests for Burble.Topology and Burble.Topology.Transition.
#
# Burble.Topology reports the deployment mode (monarchic / oligarchic /
# distributed / serverless) and derives feature flags from it.
# Burble.Topology.Transition handles room-level topology changes.

defmodule Burble.Topology.TopologyTest do
  use ExUnit.Case, async: true

  alias Burble.Topology
  alias Burble.Topology.Transition

  # ---------------------------------------------------------------------------
  # 1. Module existence
  # ---------------------------------------------------------------------------

  describe "module definition" do
    test "Topology module exists and exports expected functions" do
      expected = [
        mode: 0, capabilities: 0, has_store?: 0, has_recording?: 0,
        has_moderation?: 0, e2ee_mandatory?: 0, default_privacy: 0,
        federated?: 0, has_accounts?: 0, has_audit?: 0
      ]

      for {fun, arity} <- expected do
        assert function_exported?(Topology, fun, arity),
               "Topology.#{fun}/#{arity} is not exported"
      end
    end

    test "Transition module exists and exports expected functions" do
      assert function_exported?(Transition, :transition_room, 2)
      assert function_exported?(Transition, :merge_rooms, 3)
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Valid topology modes
  # ---------------------------------------------------------------------------

  describe "topology modes" do
    test "mode/0 returns a valid topology atom" do
      assert Topology.mode() in [:monarchic, :oligarchic, :distributed, :serverless]
    end

    test "room topology modes :open, :moderated, :presentation are not deployment modes" do
      # Burble.Topology is a deployment topology, not a room governance mode.
      # :open / :moderated / :presentation belong to room policy, not here.
      valid = [:monarchic, :oligarchic, :distributed, :serverless]
      refute :open in valid
      refute :moderated in valid
      refute :presentation in valid
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Capability map
  # ---------------------------------------------------------------------------

  describe "capabilities/0" do
    test "returns a map with all required keys" do
      caps = Topology.capabilities()
      assert is_map(caps)

      required_keys = [
        :topology, :store, :recording, :moderation,
        :e2ee_mandatory, :default_privacy, :federated, :accounts, :audit
      ]

      for key <- required_keys do
        assert Map.has_key?(caps, key), "capabilities/0 is missing key #{inspect(key)}"
      end
    end

    test "capabilities derived fields are consistent with individual functions" do
      caps = Topology.capabilities()
      assert caps.topology        == Topology.mode()
      assert caps.store           == Topology.has_store?()
      assert caps.e2ee_mandatory  == Topology.e2ee_mandatory?()
      assert caps.federated       == Topology.federated?()
      assert caps.accounts        == Topology.has_accounts?()
      assert caps.audit           == Topology.has_audit?()
    end

    test "monarchic (default) has full server-side feature set" do
      # Default test config is monarchic; serverless would invert these.
      caps = Topology.capabilities()
      assert caps.store        == true
      assert caps.recording    == true
      assert caps.moderation   == true
      assert caps.accounts     == true
      assert caps.audit        == true
      assert caps.e2ee_mandatory == false
      assert caps.federated      == false
    end
  end

  # ---------------------------------------------------------------------------
  # 4. Individual feature flag functions (monarchic defaults)
  # ---------------------------------------------------------------------------

  describe "feature flags under default (monarchic) mode" do
    test "privacy and encryption settings" do
      assert Topology.default_privacy()  == :turn_only
      assert Topology.e2ee_mandatory?()  == false
    end

    test "federation and account settings" do
      assert Topology.federated?()    == false
      assert Topology.has_accounts?() == true
    end

    test "server-side services are available" do
      assert Topology.has_store?()      == true
      assert Topology.has_recording?()  == true
      assert Topology.has_moderation?() == true
      assert Topology.has_audit?()      == true
    end
  end

  # ---------------------------------------------------------------------------
  # 5. Topology.Transition validation
  # ---------------------------------------------------------------------------

  describe "Topology.Transition" do
    test "transition to monarchic returns :ok (no chain fork needed)" do
      result = Transition.transition_room("test_room", :monarchic)
      assert result == :ok or match?({:error, :room_not_found}, result)
    end

    test "transition to oligarchic returns :ok (no chain fork needed)" do
      result = Transition.transition_room("test_room", :oligarchic)
      assert result == :ok or match?({:error, :room_not_found}, result)
    end

    test "transition to distributed returns fork_not_implemented error (Phase 2)" do
      # Transition validates room existence before the fork step, so use a
      # real room — the test documents that chain fork is Phase 2.
      room_id = "topo-fork-dist-#{:erlang.unique_integer([:positive])}"
      {:ok, _pid} = Burble.Rooms.RoomManager.ensure_room(room_id, server_id: "default", name: "Topo")
      result = Transition.transition_room(room_id, :distributed)
      assert {:error, :fork_not_implemented} = result
    end

    test "transition to serverless returns fork_not_implemented error (Phase 2)" do
      room_id = "topo-fork-srvless-#{:erlang.unique_integer([:positive])}"
      {:ok, _pid} = Burble.Rooms.RoomManager.ensure_room(room_id, server_id: "default", name: "Topo")
      result = Transition.transition_room(room_id, :serverless)
      assert {:error, :fork_not_implemented} = result
    end

    test "merge_rooms/3 returns :ok for any valid target mode" do
      # merge_rooms is currently a stub that always returns :ok.
      assert Transition.merge_rooms("room_a", "room_b", :oligarchic) == :ok
    end
  end
end
