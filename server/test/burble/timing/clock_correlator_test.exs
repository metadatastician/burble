# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
#
# Tests for Burble.Timing.ClockCorrelator.

defmodule Burble.Timing.ClockCorrelatorTest do
  use ExUnit.Case, async: true

  alias Burble.Timing.ClockCorrelator

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Start a fresh, anonymous correlator for each test.
  defp start_correlator(opts \\ []) do
    opts = Keyword.put_new(opts, :clock_rate, 48_000)
    start_supervised!({ClockCorrelator, opts})
  end

  # Ideal nanoseconds per RTP tick at 48 000 Hz.
  @ns_per_tick 1_000_000_000 / 48_000

  # ---------------------------------------------------------------------------
  # Empty-state guard
  # ---------------------------------------------------------------------------

  describe "empty state" do
    test "rtp_to_wall returns {:error, :no_sync_points} before any sync points" do
      pid = start_correlator()
      assert ClockCorrelator.rtp_to_wall(pid, 1_000) == {:error, :no_sync_points}
    end

    test "wall_to_rtp returns {:error, :no_sync_points} before any sync points" do
      pid = start_correlator()
      assert ClockCorrelator.wall_to_rtp(pid, 1_000_000_000) == {:error, :no_sync_points}
    end

    test "drift_ppm returns {:error, :insufficient_data} with fewer than two sync points" do
      pid = start_correlator()
      assert ClockCorrelator.drift_ppm(pid) == {:error, :insufficient_data}
    end

    test "drift_ppm returns {:error, :insufficient_data} with exactly one sync point" do
      pid = start_correlator()
      ClockCorrelator.record_sync_point(pid, 0, 0)
      # Allow the cast to be processed.
      :sys.get_state(pid)
      assert ClockCorrelator.drift_ppm(pid) == {:error, :insufficient_data}
    end
  end

  # ---------------------------------------------------------------------------
  # Basic sync point recording and rtp_to_wall conversion
  # ---------------------------------------------------------------------------

  describe "basic sync point + rtp_to_wall" do
    test "single sync point: converts using ideal clock rate" do
      pid = start_correlator()

      anchor_rtp = 96_000
      anchor_wall = 1_000_000_000

      ClockCorrelator.record_sync_point(pid, anchor_rtp, anchor_wall)
      :sys.get_state(pid)

      # 480 ticks ahead @ 48 000 Hz = 10 ms = 10_000_000 ns.
      query_rtp = anchor_rtp + 480
      {:ok, wall} = ClockCorrelator.rtp_to_wall(pid, query_rtp)

      expected = anchor_wall + round(480 * @ns_per_tick)
      assert_in_delta wall, expected, 10
    end

    test "two sync points on ideal clock: conversion is exact" do
      pid = start_correlator()

      # Anchor at t=0, then exactly 1 second later (48_000 ticks = 1 s).
      ClockCorrelator.record_sync_point(pid, 0, 0)
      ClockCorrelator.record_sync_point(pid, 48_000, 1_000_000_000)
      :sys.get_state(pid)

      # Query 2 s from anchor.
      {:ok, wall} = ClockCorrelator.rtp_to_wall(pid, 96_000)
      assert_in_delta wall, 2_000_000_000, 10
    end

    test "rtp_to_wall is monotonically increasing for increasing RTP timestamps" do
      pid = start_correlator()

      base_rtp = 10_000
      base_wall = 5_000_000_000

      for i <- 0..9 do
        ClockCorrelator.record_sync_point(pid, base_rtp + i * 480, base_wall + round(i * 480 * @ns_per_tick))
      end

      :sys.get_state(pid)

      walls =
        for i <- 0..20 do
          {:ok, w} = ClockCorrelator.rtp_to_wall(pid, base_rtp + i * 480)
          w
        end

      assert walls == Enum.sort(walls)
    end
  end

  # ---------------------------------------------------------------------------
  # RTP wraparound handling
  # ---------------------------------------------------------------------------

  describe "RTP wraparound" do
    # The 32-bit RTP counter wraps at 4_294_967_296.  We simulate a stream
    # that crosses the boundary.

    @rtp_max 4_294_967_296

    test "timestamps crossing 2^32 are treated as continuous" do
      pid = start_correlator()

      # Place a sync point just before wraparound.
      pre_wrap_rtp = @rtp_max - 4_800
      pre_wrap_wall = 1_000_000_000

      ClockCorrelator.record_sync_point(pid, pre_wrap_rtp, pre_wrap_wall)

      # 4_800 ticks later the counter wraps to 0.
      post_wrap_rtp = 0
      post_wrap_wall = pre_wrap_wall + round(4_800 * @ns_per_tick)

      ClockCorrelator.record_sync_point(pid, post_wrap_rtp, post_wrap_wall)
      :sys.get_state(pid)

      # Query 480 ticks after the wrap point.
      query_rtp = 480
      expected_wall = post_wrap_wall + round(480 * @ns_per_tick)

      {:ok, result_wall} = ClockCorrelator.rtp_to_wall(pid, query_rtp)

      # Allow 500 ns tolerance for rounding.
      assert_in_delta result_wall, expected_wall, 500
    end

    test "multiple wraps: wall time keeps growing" do
      pid = start_correlator()

      # Simulate three wrap-around events.
      ticks_per_wrap = @rtp_max

      base_wall = 0

      # Seed sync points across wraps.  We feed raw (wrapped) RTP values.
      for wrap <- 0..2 do
        rtp_raw = rem(wrap * ticks_per_wrap, @rtp_max)
        wall = base_wall + wrap * round(ticks_per_wrap * @ns_per_tick)
        ClockCorrelator.record_sync_point(pid, rtp_raw, wall)
      end

      :sys.get_state(pid)

      # Wall time should increase across wraps.
      {:ok, w0} = ClockCorrelator.rtp_to_wall(pid, 0)
      {:ok, w1} = ClockCorrelator.rtp_to_wall(pid, 48_000)
      assert w1 > w0
    end

    test "wall_to_rtp round-trip survives wraparound region" do
      pid = start_correlator()

      pre_wrap_rtp = @rtp_max - 9_600
      pre_wrap_wall = 2_000_000_000

      ClockCorrelator.record_sync_point(pid, pre_wrap_rtp, pre_wrap_wall)
      ClockCorrelator.record_sync_point(pid, 0, pre_wrap_wall + round(9_600 * @ns_per_tick))
      ClockCorrelator.record_sync_point(pid, 9_600, pre_wrap_wall + round(19_200 * @ns_per_tick))
      :sys.get_state(pid)

      test_wall = pre_wrap_wall + round(14_400 * @ns_per_tick)
      {:ok, recovered_rtp} = ClockCorrelator.wall_to_rtp(pid, test_wall)

      # Expected raw RTP: 4800 ticks after wrap = 4800.
      expected_rtp = 4_800
      # Allow 2 tick tolerance (rounding in regression).
      assert abs(recovered_rtp - expected_rtp) <= 2
    end
  end

  # ---------------------------------------------------------------------------
  # Drift estimation
  # ---------------------------------------------------------------------------

  describe "drift estimation" do
    test "ideal clock yields ~0 PPM drift" do
      pid = start_correlator()

      # Feed 10 sync points on a perfect 48 000 Hz clock.
      for i <- 0..9 do
        rtp = i * 48_000
        wall = i * 1_000_000_000
        ClockCorrelator.record_sync_point(pid, rtp, wall)
      end

      :sys.get_state(pid)

      {:ok, ppm} = ClockCorrelator.drift_ppm(pid)
      # Should be very close to 0.
      assert abs(ppm) < 0.1
    end

    test "RTP clock running 100 PPM fast is detected" do
      pid = start_correlator()

      # A 100 PPM fast RTP clock ticks at clock_rate * (1 + 100e-6) Hz.
      # In practice: for every wall second, the RTP counter advances by
      # clock_rate + clock_rate * 100e-6 ticks.
      drift_factor = 1.0 + 100.0 / 1_000_000

      for i <- 0..15 do
        rtp = round(i * 48_000 * drift_factor)
        wall = i * 1_000_000_000
        ClockCorrelator.record_sync_point(pid, rtp, wall)
      end

      :sys.get_state(pid)

      {:ok, ppm} = ClockCorrelator.drift_ppm(pid)

      # The measured PPM should be close to -100 (wall slower → slope
      # smaller → negative drift in our convention: slope - ideal < 0
      # because RTP ticks faster so fewer ns per tick).
      # actual: slope = ns/tick = 1e9 / (48000 * drift_factor)
      # ideal  = 1e9 / 48000
      # (slope - ideal)/ideal = -100/(1e6 + 100) ≈ -100 PPM
      assert_in_delta ppm, -100.0, 1.0
    end

    test "RTP clock running 50 PPM slow is detected" do
      pid = start_correlator()

      drift_factor = 1.0 - 50.0 / 1_000_000

      for i <- 0..15 do
        rtp = round(i * 48_000 * drift_factor)
        wall = i * 1_000_000_000
        ClockCorrelator.record_sync_point(pid, rtp, wall)
      end

      :sys.get_state(pid)

      {:ok, ppm} = ClockCorrelator.drift_ppm(pid)
      # Slope > ideal → positive PPM? Let's check:
      # slope = 1e9 / (48000 * drift_factor) > ideal → (slope-ideal)/ideal > 0 → +50 PPM
      assert_in_delta ppm, 50.0, 1.0
    end
  end

  # ---------------------------------------------------------------------------
  # wall_to_rtp round-trip accuracy
  # ---------------------------------------------------------------------------

  describe "wall_to_rtp round-trip" do
    test "round-trip rtp → wall → rtp is accurate within 2 ticks" do
      pid = start_correlator()

      base_rtp = 100_000
      base_wall = 3_000_000_000

      for i <- 0..19 do
        ClockCorrelator.record_sync_point(
          pid,
          base_rtp + i * 480,
          base_wall + round(i * 480 * @ns_per_tick)
        )
      end

      :sys.get_state(pid)

      query_rtp = base_rtp + 2_400

      {:ok, wall} = ClockCorrelator.rtp_to_wall(pid, query_rtp)
      {:ok, recovered} = ClockCorrelator.wall_to_rtp(pid, wall)

      assert abs(recovered - query_rtp) <= 2
    end

    test "round-trip wall → rtp → wall is accurate within 1 µs" do
      pid = start_correlator()

      base_rtp = 50_000
      base_wall = 1_500_000_000

      for i <- 0..19 do
        ClockCorrelator.record_sync_point(
          pid,
          base_rtp + i * 480,
          base_wall + round(i * 480 * @ns_per_tick)
        )
      end

      :sys.get_state(pid)

      query_wall = base_wall + 5_000_000

      {:ok, rtp} = ClockCorrelator.wall_to_rtp(pid, query_wall)
      {:ok, recovered_wall} = ClockCorrelator.rtp_to_wall(pid, rtp)

      # Within 1 µs (1000 ns).
      assert_in_delta recovered_wall, query_wall, 1_000
    end
  end

  # ---------------------------------------------------------------------------
  # Sliding window (max_points eviction)
  # ---------------------------------------------------------------------------

  describe "sliding window" do
    test "window is capped at max_points (64)" do
      pid = start_correlator()

      # Record 80 sync points.
      for i <- 0..79 do
        ClockCorrelator.record_sync_point(pid, i * 480, i * round(480 * @ns_per_tick))
      end

      :sys.get_state(pid)

      state = :sys.get_state(pid)
      assert length(state.sync_points) == 64
    end

    test "newest points are retained when window is full" do
      pid = start_correlator()

      for i <- 0..79 do
        ClockCorrelator.record_sync_point(pid, i * 480, i * round(480 * @ns_per_tick))
      end

      :sys.get_state(pid)

      # The most recent point is index 79.
      state = :sys.get_state(pid)
      {latest_rtp, _} = hd(state.sync_points)
      # Unwrapped RTP for index 79 = 79 * 480.
      assert latest_rtp == 79 * 480
    end
  end
end
