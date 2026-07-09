# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Tests for Burble.Groove — Gossamer Groove GenServer.
#
# Verifies the GenServer lifecycle, message queue operations,
# manifest structure, queue depth limits, leases (groove-protocol
# SPEC v0.3), the attestation chain, and generated-manifest drift.
#
# Uses the application-started Groove process (does not restart it)
# to avoid disrupting the supervision tree.

defmodule Burble.GrooveTest do
  use ExUnit.Case, async: false

  alias Burble.Groove

  @genesis_hash "sha256:" <> String.duplicate("0", 64)

  # Drain the queue before each test to avoid state leakage.
  setup do
    Groove.pop_messages()
    :ok
  end

  # Drive the heartbeat/lease sweep directly. The periodic sweep is stretched
  # to 1h in config/test.exs, so tests own sweep timing deterministically.
  # Any synchronous call is queued behind the sweep message, so the returned
  # status reflects a completed sweep.
  defp sweep do
    send(Process.whereis(Groove), :check_heartbeats)
    Groove.connection_status()
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

    test "declares active mode" do
      assert Groove.manifest().mode == "active"
    end
  end

  # ---------------------------------------------------------------------------
  # Generated static manifest (.well-known/groove/manifest.json)
  # ---------------------------------------------------------------------------

  describe "generated static manifest file" do
    test "is byte-identical to the live manifest rendering" do
      # mix test runs from server/; the generated file lives at the repo root.
      path = Path.expand("../.well-known/groove/manifest.json", File.cwd!())
      expected = Jason.encode!(Groove.manifest(), pretty: true) <> "\n"

      assert File.read!(path) == expected,
             "#{path} has drifted from Burble.Groove.@manifest — " <>
               "regenerate it with `mix burble.groove.manifest`"
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
  # Leases (groove-protocol SPEC v0.3)
  # ---------------------------------------------------------------------------

  describe "connect/1 with lease" do
    test "echoes the accepted lease beside the session id" do
      peer = %{
        "service_id" => "lease-echo-peer",
        "consumes" => ["voice"],
        "lease" => %{"mode" => "soft", "ttl_ms" => 60_000}
      }

      assert {:ok, session_id, lease} = Groove.connect(peer)
      assert lease == %{mode: "soft", ttl_ms: 60_000}
      Groove.disconnect(session_id)
    end

    test "absent lease keeps the legacy two-tuple reply" do
      peer = %{"service_id" => "legacy-lease-peer", "consumes" => ["voice"]}
      assert {:ok, session_id} = Groove.connect(peer)
      Groove.disconnect(session_id)
    end

    test "rejects a malformed lease" do
      peer = %{
        "service_id" => "bad-lease-peer",
        "consumes" => ["voice"],
        "lease" => %{"mode" => "diamond", "ttl_ms" => 1}
      }

      assert {:error, _reason} = Groove.connect(peer)
    end
  end

  describe "soft lease expiry" do
    test "wipes the peer's queued messages and attests residue 0" do
      peer = %{
        "service_id" => "soft-expiry-peer",
        "consumes" => ["voice"],
        "lease" => %{"mode" => "soft", "ttl_ms" => 10}
      }

      {:ok, session_id, _lease} = Groove.connect(peer)

      Groove.push_message(%{"session_id" => session_id, "type" => "chat", "body" => "residue"})
      Groove.push_message(%{"from" => "unrelated-peer", "type" => "chat", "body" => "keep"})

      # Let the TTL elapse, then drive the sweep directly.
      Process.sleep(50)
      status = sweep()

      refute Map.has_key?(status, session_id)

      # Zero provider-side residue: the peer's messages are gone, everyone
      # else's remain.
      messages = Groove.pop_messages()
      refute Enum.any?(messages, &(Map.get(&1, "session_id") == session_id))
      assert Enum.any?(messages, &(Map.get(&1, "from") == "unrelated-peer"))

      expiries =
        Groove.attestations()
        |> Enum.filter(&(&1.event == "groove:lease-expired" and &1.consumer == "soft-expiry-peer"))

      assert [record] = expiries
      assert record.residue == 0
    end
  end

  describe "hard lease" do
    test "survives 3 refreshed TTLs — actively refreshed is never reaped" do
      peer = %{
        "service_id" => "hard-refresh-peer",
        "consumes" => ["voice"],
        "lease" => %{"mode" => "hard", "ttl_ms" => 200}
      }

      {:ok, session_id, _lease} = Groove.connect(peer)

      for _window <- 1..3 do
        Process.sleep(50)
        assert :ok = Groove.heartbeat(session_id)
        status = sweep()
        assert Map.has_key?(status, session_id)
        assert status[session_id].missed_windows == 0
      end

      Groove.disconnect(session_id)
    end

    test "degrades through the soft-expiry path after 3 missed TTL windows" do
      peer = %{
        "service_id" => "hard-degrade-peer",
        "consumes" => ["voice"],
        "lease" => %{"mode" => "hard", "ttl_ms" => 5}
      }

      {:ok, session_id, _lease} = Groove.connect(peer)
      Groove.push_message(%{"session_id" => session_id, "type" => "chat"})

      # Let the first TTL window lapse without any heartbeat.
      Process.sleep(50)

      # Windows 1 and 2: degraded but never reaped.
      status = sweep()
      assert Map.has_key?(status, session_id)
      assert status[session_id].missed_windows == 1
      status = sweep()
      assert Map.has_key?(status, session_id)
      assert status[session_id].state == :degraded

      # Window 3: degrades through the soft-expiry path (wipe + attest).
      status = sweep()
      refute Map.has_key?(status, session_id)

      refute Enum.any?(Groove.pop_messages(), &(Map.get(&1, "session_id") == session_id))

      expiries =
        Groove.attestations()
        |> Enum.filter(&(&1.event == "groove:lease-expired" and &1.consumer == "hard-degrade-peer"))

      assert [record] = expiries
      assert record.residue == 0
    end
  end

  # ---------------------------------------------------------------------------
  # Attestation chain
  # ---------------------------------------------------------------------------

  describe "attestation chain" do
    test "records connect and disconnect events, newest-last" do
      peer = %{"service_id" => "attest-order-peer", "consumes" => ["voice"]}
      {:ok, session_id} = Groove.connect(peer)
      :ok = Groove.disconnect(session_id)

      events =
        Groove.attestations()
        |> Enum.filter(&(&1.consumer == "attest-order-peer"))
        |> Enum.map(& &1.event)

      assert events == ["groove:connect", "groove:disconnect"]
    end

    test "every record links prev_hash to the prior record's hash" do
      # Generate a few links.
      for i <- 1..3 do
        {:ok, session_id} =
          Groove.connect(%{"service_id" => "chain-peer-#{i}", "consumes" => ["text"]})

        :ok = Groove.disconnect(session_id)
      end

      attestations = Groove.attestations()
      assert length(attestations) >= 6

      attestations
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [prev, next] ->
        assert next.prev_hash == prev.hash
      end)

      # Each hash covers the Jason encoding of the record without :hash.
      Enum.each(attestations, fn record ->
        expected =
          "sha256:" <>
            Base.encode16(
              :crypto.hash(:sha256, Jason.encode!(Map.delete(record, :hash))),
              case: :lower
            )

        assert record.hash == expected
      end)

      # The chain is anchored at the all-zeros genesis hash unless the cap
      # (1000) has already rotated the oldest records out.
      if length(attestations) < 1000 do
        assert hd(attestations).prev_hash == @genesis_hash
      end
    end

    test "records carry provider, capabilities, and ISO8601 UTC timestamps" do
      {:ok, session_id} =
        Groove.connect(%{"service_id" => "stamp-peer", "consumes" => ["voice"]})

      :ok = Groove.disconnect(session_id)

      record =
        Groove.attestations()
        |> Enum.filter(&(&1.consumer == "stamp-peer"))
        |> List.last()

      assert record.provider == %{id: "burble", version: "1.0.0"}
      assert record.capabilities == ["voice"]
      assert {:ok, _dt, 0} = DateTime.from_iso8601(record.timestamp)
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
