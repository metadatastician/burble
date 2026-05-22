# SPDX-License-Identifier: MPL-2.0

defmodule Burble.TopologyTest do
  use ExUnit.Case, async: true

  alias Burble.Topology

  describe "mode/0" do
    test "defaults to monarchic" do
      assert Topology.mode() == :monarchic
    end
  end

  describe "capabilities/0" do
    test "returns complete capability map" do
      caps = Topology.capabilities()
      assert is_map(caps)
      assert Map.has_key?(caps, :topology)
      assert Map.has_key?(caps, :store)
      assert Map.has_key?(caps, :recording)
      assert Map.has_key?(caps, :moderation)
      assert Map.has_key?(caps, :e2ee_mandatory)
      assert Map.has_key?(caps, :default_privacy)
      assert Map.has_key?(caps, :federated)
      assert Map.has_key?(caps, :accounts)
      assert Map.has_key?(caps, :audit)
    end

    test "monarchic has full features" do
      caps = Topology.capabilities()
      assert caps.store == true
      assert caps.recording == true
      assert caps.moderation == true
      assert caps.e2ee_mandatory == false
      assert caps.accounts == true
      assert caps.audit == true
      assert caps.federated == false
    end
  end

  describe "feature flags" do
    test "has_store? is true for monarchic" do
      assert Topology.has_store?() == true
    end

    test "e2ee_mandatory? is false for monarchic" do
      assert Topology.e2ee_mandatory?() == false
    end

    test "default_privacy is turn_only for monarchic" do
      assert Topology.default_privacy() == :turn_only
    end
  end
end
