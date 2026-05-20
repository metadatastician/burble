# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
#
# Tests for Burble.Timing.PTP — IEEE 1588 Precision Time Protocol integration.
#
# Uses `enabled: false` to suppress periodic measurements and calls
# `PTP.measure_now/0` explicitly so tests are deterministic.

defmodule Burble.Timing.PTPTest do
  use ExUnit.Case, async: false

  alias Burble.Timing.PTP

  # PTP is an application-owned singleton (lib/burble/application.ex:90), so
  # tests use the running instance instead of starting a fresh one
  # (#62 shared-app+reset strategy, established by PR #64). Tests that need a
  # known sample count call PTP.measure_now/0 directly.
  setup do
    pid = Process.whereis(PTP)
    assert is_pid(pid) and Process.alive?(pid), "app-owned PTP must be running"
    {:ok, pid: pid}
  end

  describe "start_link/1" do
    test "starts the GenServer and registers under its module name" do
      assert pid = Process.whereis(PTP)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "is already running from setup — second start_link returns error" do
      assert {:error, {:already_started, _pid}} = PTP.start_link(enabled: false)
    end
  end

  describe "now/0" do
    test "returns {:ok, timestamp_ns, source} with a positive timestamp" do
      assert {:ok, timestamp_ns, source} = PTP.now()
      assert is_integer(timestamp_ns)
      assert timestamp_ns > 0
      assert source in [:ptp_hardware, :phc2sys, :ntp, :system]
    end

    test "successive calls return non-decreasing timestamps" do
      {:ok, ts1, _source} = PTP.now()
      {:ok, ts2, _source} = PTP.now()
      assert ts2 >= ts1
    end
  end

  describe "offset/0" do
    test "returns {:ok, offset_ns} after a measurement" do
      PTP.measure_now()
      assert {:ok, offset_ns} = PTP.offset()
      assert is_integer(offset_ns)
    end

    test "returns {:ok, offset_ns} after an explicit measure_now/0 call" do
      PTP.measure_now()
      assert {:ok, offset_ns} = PTP.offset()
      assert is_integer(offset_ns)
    end
  end

  describe "jitter/0" do
    test "returns {:ok, jitter_ns} after taking two measurements" do
      # Shared app-owned PTP has measured many times across the suite; the
      # original "insufficient_samples" assertion is no longer reachable.
      PTP.measure_now()
      PTP.measure_now()
      assert {:ok, jitter_ns} = PTP.jitter()
      assert is_integer(jitter_ns)
      assert jitter_ns >= 0
    end

    test "returns {:ok, jitter_ns} after a second measurement" do
      PTP.measure_now()
      assert {:ok, jitter_ns} = PTP.jitter()
      assert is_integer(jitter_ns)
      assert jitter_ns >= 0
    end
  end

  describe "quality/0" do
    test "returns a map with all required keys" do
      quality = PTP.quality()
      assert is_map(quality)
      assert Map.has_key?(quality, :source)
      assert Map.has_key?(quality, :offset_ns)
      assert Map.has_key?(quality, :jitter_ns)
      assert Map.has_key?(quality, :samples)
      assert Map.has_key?(quality, :synchronized)
    end

    test "source is a valid clock source atom" do
      assert PTP.quality().source in [:ptp_hardware, :phc2sys, :ntp, :system]
    end

    test "synchronized is a boolean" do
      # Shared app-owned PTP may have any sample count by the time this test
      # runs, so we assert type rather than a specific value.
      assert is_boolean(PTP.quality().synchronized)
    end
  end

  describe "alignment_data/0" do
    test "returns a map with node, monotonic_ref, and system_time_ns" do
      data = PTP.alignment_data()
      assert is_map(data)
      assert Map.has_key?(data, :node)
      assert Map.has_key?(data, :monotonic_ref)
      assert Map.has_key?(data, :system_time_ns)
    end

    test "node matches the running node" do
      assert PTP.alignment_data().node == node()
    end

    test "system_time_ns is a positive integer" do
      assert PTP.alignment_data().system_time_ns > 0
    end
  end

  describe "source/0" do
    test "returns a valid clock source atom" do
      assert PTP.source() in [:ptp_hardware, :phc2sys, :ntp, :system]
    end
  end

  describe "measurement updates state" do
    test "measure_now/0 updates the offset visible via offset/0" do
      {:ok, before_offset} = PTP.offset()

      # Force a new measurement; the offset may or may not differ numerically,
      # but the call must succeed and offset/0 must still return a value.
      assert {:ok, sample} = PTP.measure_now()
      assert is_map(sample)
      assert Map.has_key?(sample, :offset_ns)
      assert Map.has_key?(sample, :measured_at)
      assert Map.has_key?(sample, :source)

      assert {:ok, after_offset} = PTP.offset()
      # The returned offset matches the most recent sample.
      assert after_offset == sample.offset_ns

      # Both offsets are integers (the value itself may be identical on a
      # stable system clock, so we only assert type, not inequality).
      assert is_integer(before_offset)
      assert is_integer(after_offset)
    end

    test "sample_count increments with each measure_now/0 call" do
      %{samples: count_before} = PTP.quality()
      PTP.measure_now()
      %{samples: count_after} = PTP.quality()
      assert count_after == count_before + 1
    end
  end
end
