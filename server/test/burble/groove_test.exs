# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Tests for Burble.Groove — Gossamer Groove GenServer.
#
# Verifies the GenServer lifecycle, message queue operations,
# manifest structure, and queue depth limits.
#
# Uses the application-started Groove process (does not restart it)
# to avoid disrupting the supervision tree.

defmodule Burble.GrooveTest do
  use ExUnit.Case, async: false

  alias Burble.Groove

  # Drain the queue before each test to avoid state leakage.
  setup do
    Groove.pop_messages()
    :ok
  end

  # ---------------------------------------------------------------------------
  # Manifest
  # ---------------------------------------------------------------------------

  describe "manifest/0" do
    test "returns a map with groove_version" do
      manifest = Groove.manifest()
      assert is_map(manifest)
      assert manifest.groove_version == "1"
    end

    test "contains service_id 'burble'" do
      manifest = Groove.manifest()
      assert manifest.service_id == "burble"
    end

    test "contains required capabilities" do
      manifest = Groove.manifest()
      caps = manifest.capabilities
      assert Map.has_key?(caps, :voice)
      assert Map.has_key?(caps, :text)
      assert Map.has_key?(caps, :presence)
    end

    test "each capability has type, protocol, and endpoint" do
      manifest = Groove.manifest()

      Enum.each(manifest.capabilities, fn {_key, cap} ->
        assert Map.has_key?(cap, :type), "capability missing :type"
        assert Map.has_key?(cap, :protocol), "capability missing :protocol"
        assert Map.has_key?(cap, :endpoint), "capability missing :endpoint"
      end)
    end

    test "has health endpoint" do
      manifest = Groove.manifest()
      assert is_binary(manifest.health)
    end

    test "has endpoints map with voice_ws and api" do
      manifest = Groove.manifest()
      assert Map.has_key?(manifest.endpoints, :voice_ws)
      assert Map.has_key?(manifest.endpoints, :api)
      assert Map.has_key?(manifest.endpoints, :health)
    end
  end

  describe "manifest_json/0" do
    test "returns valid JSON string" do
      json = Groove.manifest_json()
      assert is_binary(json)
      assert {:ok, decoded} = Jason.decode(json)
      assert decoded["service_id"] == "burble"
    end
  end

  # ---------------------------------------------------------------------------
  # Message queue
  # ---------------------------------------------------------------------------

  describe "push_message/1" do
    test "enqueues a message" do
      assert :ok = Groove.push_message(%{type: "hello", from: "test"})
      assert Groove.queue_depth() >= 1
    end

    test "multiple messages queue in order" do
      Groove.push_message(%{seq: 1})
      Groove.push_message(%{seq: 2})
      Groove.push_message(%{seq: 3})

      messages = Groove.pop_messages()
      seqs = Enum.map(messages, & &1.seq)
      assert [1, 2, 3] = seqs
    end
  end

  describe "pop_messages/0" do
    test "drains the queue" do
      Groove.push_message(%{a: 1})
      Groove.push_message(%{b: 2})

      messages = Groove.pop_messages()
      assert length(messages) == 2
      assert Groove.queue_depth() == 0
    end

    test "returns empty list when queue is empty" do
      assert [] = Groove.pop_messages()
    end

    test "subsequent pop returns empty after drain" do
      Groove.push_message(%{x: 1})
      Groove.pop_messages()
      assert [] = Groove.pop_messages()
    end
  end

  describe "queue_depth/0" do
    test "returns 0 for empty queue" do
      assert Groove.queue_depth() == 0
    end

    test "tracks queue size accurately" do
      for i <- 1..5, do: Groove.push_message(%{i: i})
      depth = Groove.queue_depth()
      assert depth == 5
      # Clean up.
      Groove.pop_messages()
    end
  end

  describe "queue overflow" do
    test "drops oldest message when at max depth (1000)" do
      # Push 1001 messages — the first should be dropped.
      for i <- 1..1001 do
        Groove.push_message(%{seq: i})
      end

      # Queue depth stays at 1000 (max).
      assert Groove.queue_depth() == 1000

      messages = Groove.pop_messages()
      # First message should be seq: 2 (seq: 1 was dropped).
      assert hd(messages).seq == 2
      assert List.last(messages).seq == 1001
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer lifecycle
  # ---------------------------------------------------------------------------

  describe "GenServer lifecycle" do
    test "is registered and alive" do
      pid = GenServer.whereis(Groove)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end
  end
end
