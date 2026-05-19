# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
#
# Tests for Burble.Timing.Alignment.

defmodule Burble.Timing.AlignmentTest do
  use ExUnit.Case, async: true

  alias Burble.Timing.Alignment

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Start a fresh, anonymous Alignment GenServer for each test.
  # We use a unique local_node atom per test to avoid node() being treated as
  # the local node unless we explicitly want that behaviour.
  defp start_alignment(opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:local_node, :"local@testhost")
      |> Keyword.put_new(:window_ms, 30_000)
      # start_link/1 forces name: __MODULE__ when :name is absent, colliding
      # with the application-owned Alignment. Unique-name per test (#62).
      |> Keyword.put(:name, :"alignment_test_#{System.unique_integer([:positive])}")

    start_supervised!({Alignment, opts})
  end

  # Flush a cast to the given pid before making assertions.
  defp flush(pid), do: :sys.get_state(pid)

  # ---------------------------------------------------------------------------
  # 1. Unknown node returns :error
  # ---------------------------------------------------------------------------

  describe "unknown node" do
    test "playout_offset_ns returns {:error, :unknown_node} for unreported node" do
      pid = start_alignment()
      assert GenServer.call(pid, {:playout_offset_ns, :"unknown@host"}) == {:error, :unknown_node}
    end

    test "node_drift_ppm returns {:error, :unknown_node} for unreported node" do
      pid = start_alignment()
      assert GenServer.call(pid, {:node_drift_ppm, :"unknown@host"}) == {:error, :unknown_node}
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Report + query offset
  # ---------------------------------------------------------------------------

  describe "report and query offset" do
    test "playout_offset_ns returns {:ok, offset} after a report" do
      pid = start_alignment()
      remote = :"remote@host"

      # We want a predictable offset.  We pass a wall_ns that is 500_000 ns
      # ahead of what :erlang.monotonic_time(:nanosecond) returns.  Because we
      # cannot freeze the clock, we accept that the stored offset is
      # approximately wall_ns_sent - local_now, which will be close to but not
      # exactly 500_000.  We just verify the shape and that it's a finite integer.
      wall_ns = :erlang.monotonic_time(:nanosecond) + 500_000

      GenServer.cast(pid, {:report_node_sync, remote, 48_000, wall_ns})
      flush(pid)

      assert {:ok, offset_ns} = GenServer.call(pid, {:playout_offset_ns, remote})
      assert is_integer(offset_ns)
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Drift computed correctly after two reports
  # ---------------------------------------------------------------------------

  describe "drift computation" do
    test "drift_ppm is non-zero after two reports with a simulated fast remote clock" do
      pid = start_alignment()
      remote = :"drifty@host"

      # First report: pretend remote clock is exactly in sync.
      now1 = :erlang.monotonic_time(:nanosecond)
      GenServer.cast(pid, {:report_node_sync, remote, 48_000, now1})
      flush(pid)

      # Second report: 10 ms of wall time has passed on the local clock, but
      # the remote wall_ns is 10_010_000 ns ahead — 1 000 ns extra in 10 ms =
      # +100 PPM.
      # We sleep a tiny amount to ensure the monotonic clock advances so that
      # delta_time > 0.
      Process.sleep(5)
      delta_ns = 10_010_000
      now2 = :erlang.monotonic_time(:nanosecond)
      GenServer.cast(pid, {:report_node_sync, remote, 96_000, now2 + delta_ns})
      flush(pid)

      assert {:ok, drift} = GenServer.call(pid, {:node_drift_ppm, remote})
      assert is_float(drift)
      # Direction: remote clock moved forward faster than local → positive drift.
      assert drift > 0.0
    end

    test "drift_ppm is 0.0 for a perfectly synchronised remote clock" do
      pid = start_alignment()
      remote = :"sync@host"

      # Two reports where offset stays constant (remote clock moves at exactly
      # the same rate as local).  offset_ns is the same for both observations.
      fixed_offset = 1_000_000

      now1 = :erlang.monotonic_time(:nanosecond)
      GenServer.cast(pid, {:report_node_sync, remote, 0, now1 + fixed_offset})
      flush(pid)

      Process.sleep(5)
      now2 = :erlang.monotonic_time(:nanosecond)
      GenServer.cast(pid, {:report_node_sync, remote, 48_000, now2 + fixed_offset})
      flush(pid)

      assert {:ok, drift} = GenServer.call(pid, {:node_drift_ppm, remote})
      # delta_offset = 0, so drift should be 0.0
      assert_in_delta drift, 0.0, 0.5
    end
  end

  # ---------------------------------------------------------------------------
  # 4. Stale node eviction
  # ---------------------------------------------------------------------------

  describe "stale node eviction" do
    test "node is evicted after window_ms elapses" do
      # Use a very short window so we don't have to wait long.
      pid = start_alignment(window_ms: 50)
      remote = :"stale@host"

      wall_ns = :erlang.monotonic_time(:nanosecond)
      GenServer.cast(pid, {:report_node_sync, remote, 0, wall_ns})
      flush(pid)

      # Confirm it's present.
      assert {:ok, _} = GenServer.call(pid, {:playout_offset_ns, remote})

      # Wait longer than the window, then trigger another cast so eviction runs.
      Process.sleep(100)

      # Trigger the eviction by reporting a second (different) node.
      GenServer.cast(pid, {:report_node_sync, :"trigger@host", 0, :erlang.monotonic_time(:nanosecond)})
      flush(pid)

      # The stale node should now be gone.
      assert GenServer.call(pid, {:playout_offset_ns, remote}) == {:error, :unknown_node}
    end
  end

  # ---------------------------------------------------------------------------
  # 5. sync_status returns node list
  # ---------------------------------------------------------------------------

  describe "sync_status" do
    test "returns empty node list when no nodes have reported" do
      pid = start_alignment()
      status = GenServer.call(pid, :sync_status)
      assert status.nodes == []
      assert status.local_node == :"local@testhost"
    end

    test "sync_status contains reported nodes with expected keys" do
      pid = start_alignment()
      remote = :"peer@remote"

      GenServer.cast(pid, {:report_node_sync, remote, 0, :erlang.monotonic_time(:nanosecond)})
      flush(pid)

      %{nodes: nodes, local_node: local} = GenServer.call(pid, :sync_status)

      assert local == :"local@testhost"
      assert length(nodes) == 1

      [entry] = nodes
      assert entry.node == remote
      assert Map.has_key?(entry, :offset_ns)
      assert Map.has_key?(entry, :drift_ppm)
      assert Map.has_key?(entry, :last_seen)
    end
  end

  # ---------------------------------------------------------------------------
  # 6. playout_offset_ns after report
  # ---------------------------------------------------------------------------

  describe "playout_offset_ns after report" do
    test "offset is close to wall_ns - local_ns at time of report" do
      pid = start_alignment()
      remote = :"ahead@host"

      # Send a wall_ns that is 1_000_000 ns (1 ms) ahead of now.
      now_ns = :erlang.monotonic_time(:nanosecond)
      wall_ns = now_ns + 1_000_000

      GenServer.cast(pid, {:report_node_sync, remote, 0, wall_ns})
      flush(pid)

      assert {:ok, offset_ns} = GenServer.call(pid, {:playout_offset_ns, remote})
      # The offset should be positive (remote is ahead) and in the right ballpark.
      # We allow ±5 ms tolerance for scheduling jitter during test.
      assert offset_ns > 0
      assert_in_delta offset_ns, 1_000_000, 5_000_000
    end
  end

  # ---------------------------------------------------------------------------
  # 7. Multiple nodes tracked independently
  # ---------------------------------------------------------------------------

  describe "multiple nodes tracked independently" do
    test "two remote nodes have independent offsets" do
      pid = start_alignment()
      node_a = :"node_a@host"
      node_b = :"node_b@host"

      now_ns = :erlang.monotonic_time(:nanosecond)

      # node_a is 2 ms ahead, node_b is 5 ms behind.
      GenServer.cast(pid, {:report_node_sync, node_a, 0, now_ns + 2_000_000})
      GenServer.cast(pid, {:report_node_sync, node_b, 0, now_ns - 5_000_000})
      flush(pid)

      assert {:ok, offset_a} = GenServer.call(pid, {:playout_offset_ns, node_a})
      assert {:ok, offset_b} = GenServer.call(pid, {:playout_offset_ns, node_b})

      # They must differ and have the correct signs.
      assert offset_a > 0, "node_a should be reported as ahead"
      assert offset_b < 0, "node_b should be reported as behind"
      assert offset_a != offset_b
    end

    test "reporting one node does not affect another node's stored offset" do
      pid = start_alignment()
      node_a = :"stable_a@host"
      node_b = :"changing_b@host"

      now_ns = :erlang.monotonic_time(:nanosecond)

      GenServer.cast(pid, {:report_node_sync, node_a, 0, now_ns + 1_000_000})
      flush(pid)

      {:ok, offset_a_before} = GenServer.call(pid, {:playout_offset_ns, node_a})

      # Report node_b many times; node_a's offset should be stable.
      for i <- 1..5 do
        GenServer.cast(pid, {:report_node_sync, node_b, i * 480, :erlang.monotonic_time(:nanosecond) + i * 100_000})
      end

      flush(pid)

      {:ok, offset_a_after} = GenServer.call(pid, {:playout_offset_ns, node_a})

      # Allow small tolerance for monotonic clock advancement between the two reads.
      # The stored offset for node_a should not have changed (no new report came in).
      assert offset_a_before == offset_a_after
    end
  end

  # ---------------------------------------------------------------------------
  # 8. Local node excluded from offset (always returns 0)
  # ---------------------------------------------------------------------------

  describe "local node special-casing" do
    test "playout_offset_ns returns {:ok, 0} for the local node" do
      pid = start_alignment(local_node: :"mynode@localhost")
      assert GenServer.call(pid, {:playout_offset_ns, :"mynode@localhost"}) == {:ok, 0}
    end

    test "node_drift_ppm returns {:ok, 0.0} for the local node" do
      pid = start_alignment(local_node: :"mynode@localhost")
      assert GenServer.call(pid, {:node_drift_ppm, :"mynode@localhost"}) == {:ok, 0.0}
    end

    test "local node returns {:ok, 0} even after reporting it as a remote" do
      # If somehow a report arrives with the local node atom, it gets stored.
      # But playout_offset_ns should still short-circuit to {:ok, 0}.
      pid = start_alignment(local_node: :"mynode@localhost")
      now_ns = :erlang.monotonic_time(:nanosecond)
      GenServer.cast(pid, {:report_node_sync, :"mynode@localhost", 0, now_ns + 999_999})
      flush(pid)
      assert GenServer.call(pid, {:playout_offset_ns, :"mynode@localhost"}) == {:ok, 0}
    end
  end
end
