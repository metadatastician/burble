# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
#
# Burble.Timing.ClockCorrelator — RTP↔wall-clock correlation with drift tracking.
#
# Maintains a sliding window of sync points (simultaneously observed RTP
# timestamp + wall-clock nanosecond pairs) and uses linear regression over
# that window to estimate the mapping and drift between the two clocks.
#
# Design decisions:
#
#   • RTP timestamps are 32-bit unsigned counters (wrap at 2^32) ticking at
#     `clock_rate` Hz (48 000 for Opus). Wraparound is handled by converting
#     every stored RTP timestamp to an "unwrapped" 64-bit value relative to
#     the first sync point.
#   • Wall-clock time comes from the PTP hardware clock when available, and
#     falls back to :erlang.monotonic_time(:nanosecond) (see Peer integration).
#   • Drift is estimated as the slope deviation from the ideal 1 tick/ns ratio,
#     expressed in parts-per-million (PPM). Positive means RTP runs fast.
#   • Linear regression is computed over the last 64 sync points for robustness
#     against jitter. Two-point fallback is used when fewer than two points exist.
#
# Author: Jonathan D.A. Jewell

defmodule Burble.Timing.ClockCorrelator do
  @moduledoc """
  RTP↔PTP wall-clock correlation with sliding-window drift estimation.

  Maintains a window of `{rtp_ts, wall_ns}` sync points and converts between
  RTP timestamps and nanosecond wall-clock time using linear regression over
  the window. Handles the 32-bit RTP wraparound transparently.

  ## Usage

      {:ok, pid} = ClockCorrelator.start_link(clock_rate: 48_000)

      # Record a simultaneously observed pair (e.g. on RTP packet arrival)
      ClockCorrelator.record_sync_point(pid, rtp_ts, wall_ns)

      # Map an RTP timestamp to wall-clock nanoseconds
      {:ok, wall_ns} = ClockCorrelator.rtp_to_wall(pid, rtp_ts)

      # Reverse mapping
      {:ok, rtp_ts} = ClockCorrelator.wall_to_rtp(pid, wall_ns)

      # Current clock drift estimate
      {:ok, ppm} = ClockCorrelator.drift_ppm(pid)

  ## RTP wraparound

  RTP timestamps wrap at 2^32 (4 294 967 296). The correlator unwraps them
  by detecting when a new timestamp is more than 2^31 less than the previous
  one, treating such a jump as a wraparound rather than a backwards jump.

  ## Drift estimation

  Linear regression over the sync window gives the best-fit line relating
  RTP ticks to wall nanoseconds. The slope of that line (in ns/tick) is
  compared against the ideal `1_000_000_000 / clock_rate` ns/tick to yield
  the drift in PPM.
  """

  use GenServer
  require Logger

  @max_points 64
  @rtp_wraparound 4_294_967_296

  # ── Types ──────────────────────────────────────────────────────────────────

  @typedoc "Unwrapped RTP tick (64-bit, monotonically increasing)."
  @type unwrapped_rtp :: integer()

  @typedoc "Wall-clock time in nanoseconds."
  @type wall_ns :: integer()

  @typedoc "Sync point: {unwrapped_rtp_tick, wall_ns}."
  @type sync_point :: {unwrapped_rtp, wall_ns}

  @typedoc "GenServer state."
  @type state :: %{
          clock_rate: pos_integer(),
          sync_points: [sync_point()],
          max_points: pos_integer(),
          # The raw RTP value of the very first sync point, used to anchor
          # unwrapping to a known origin so comparisons are consistent.
          first_rtp_raw: non_neg_integer() | nil,
          # The last unwrapped RTP value, used to detect wraparound.
          last_unwrapped: integer() | nil
        }

  # ── Client API ─────────────────────────────────────────────────────────────

  @doc """
  Start the ClockCorrelator GenServer.

  Options:
    - `:clock_rate` — RTP clock rate in Hz (default: 48_000)
    - `:name` — registered name (optional)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  @doc """
  Record a simultaneously observed RTP timestamp and wall-clock nanosecond value.

  Both clocks should be read as close together as possible (ideally on RTP
  packet arrival, read the wall clock immediately before or after extracting
  `packet.timestamp`).
  """
  @spec record_sync_point(GenServer.server(), non_neg_integer(), wall_ns()) :: :ok
  def record_sync_point(pid, rtp_ts, wall_ns) do
    GenServer.cast(pid, {:record_sync_point, rtp_ts, wall_ns})
  end

  @doc """
  Convert an RTP timestamp to wall-clock nanoseconds.

  Returns `{:ok, wall_ns}` when at least one sync point exists, or
  `{:error, :no_sync_points}` when the window is empty.
  """
  @spec rtp_to_wall(GenServer.server(), non_neg_integer()) ::
          {:ok, wall_ns()} | {:error, :no_sync_points}
  def rtp_to_wall(pid, rtp_ts) do
    GenServer.call(pid, {:rtp_to_wall, rtp_ts})
  end

  @doc """
  Convert a wall-clock nanosecond value to the closest RTP timestamp.

  Returns `{:ok, rtp_ts}` when at least one sync point exists, or
  `{:error, :no_sync_points}` when the window is empty.

  The returned value is a 32-bit unsigned integer (wrapped back into
  the RTP timestamp space).
  """
  @spec wall_to_rtp(GenServer.server(), wall_ns()) ::
          {:ok, non_neg_integer()} | {:error, :no_sync_points}
  def wall_to_rtp(pid, wall_ns) do
    GenServer.call(pid, {:wall_to_rtp, wall_ns})
  end

  @doc """
  Return the estimated clock drift in parts-per-million (PPM).

  Positive values mean the RTP clock is running faster than nominal.
  Negative values mean it is running slower.

  Returns `{:error, :insufficient_data}` if fewer than two sync points
  have been recorded (drift cannot be estimated from a single point).
  """
  @spec drift_ppm(GenServer.server()) :: {:ok, float()} | {:error, :insufficient_data}
  def drift_ppm(pid) do
    GenServer.call(pid, :drift_ppm)
  end

  # ── Server Callbacks ───────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    clock_rate = Keyword.get(opts, :clock_rate, 48_000)

    state = %{
      clock_rate: clock_rate,
      sync_points: [],
      max_points: @max_points,
      first_rtp_raw: nil,
      last_unwrapped: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:record_sync_point, rtp_ts, wall_ns}, state) do
    {unwrapped, new_state} = unwrap_rtp(rtp_ts, state)
    point = {unwrapped, wall_ns}

    # Prepend and trim to max window size.  We store newest-first so pattern
    # matching on the head gives the most recent point cheaply.
    points =
      [point | new_state.sync_points]
      |> Enum.take(new_state.max_points)

    {:noreply, %{new_state | sync_points: points}}
  end

  @impl true
  def handle_call({:rtp_to_wall, _rtp_ts}, _from, %{sync_points: []} = state) do
    {:reply, {:error, :no_sync_points}, state}
  end

  @impl true
  def handle_call({:rtp_to_wall, rtp_ts}, _from, state) do
    {unwrapped, _} = unwrap_rtp(rtp_ts, state)
    result = apply_regression_rtp_to_wall(unwrapped, state)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:wall_to_rtp, _wall_ns}, _from, %{sync_points: []} = state) do
    {:reply, {:error, :no_sync_points}, state}
  end

  @impl true
  def handle_call({:wall_to_rtp, wall_ns}, _from, state) do
    result = apply_regression_wall_to_rtp(wall_ns, state)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:drift_ppm, _from, %{sync_points: points} = state) when length(points) < 2 do
    {:reply, {:error, :insufficient_data}, state}
  end

  @impl true
  def handle_call(:drift_ppm, _from, state) do
    result = compute_drift_ppm(state)
    {:reply, result, state}
  end

  # ── Private helpers ────────────────────────────────────────────────────────

  # Unwrap a raw 32-bit RTP timestamp into a monotonically increasing 64-bit
  # integer, relative to the first sync point's raw RTP value.
  #
  # Wraparound detection: if the new raw value is more than 2^31 less than
  # the last unwrapped value (modulo 2^32), we increment the wrap counter.
  @spec unwrap_rtp(non_neg_integer(), state()) :: {integer(), state()}
  defp unwrap_rtp(rtp_ts, %{first_rtp_raw: nil} = state) do
    # First point — anchor here.
    unwrapped = rtp_ts
    new_state = %{state | first_rtp_raw: rtp_ts, last_unwrapped: unwrapped}
    {unwrapped, new_state}
  end

  defp unwrap_rtp(rtp_ts, state) do
    last = state.last_unwrapped
    # Compute the difference in the 32-bit space.
    raw_diff = rtp_ts - Integer.mod(last, @rtp_wraparound)

    # Adjust for wraparound: if diff is < -2^31, the counter wrapped forward.
    diff =
      cond do
        raw_diff < -div(@rtp_wraparound, 2) -> raw_diff + @rtp_wraparound
        raw_diff > div(@rtp_wraparound, 2) -> raw_diff - @rtp_wraparound
        true -> raw_diff
      end

    unwrapped = last + diff
    new_state = %{state | last_unwrapped: unwrapped}
    {unwrapped, new_state}
  end

  # Linear regression helpers.
  #
  # We fit the model:  wall_ns = intercept + slope * unwrapped_rtp
  #
  # slope has units ns/tick.  The ideal slope for a clock_rate Hz RTP clock
  # is 1_000_000_000 / clock_rate ns/tick.

  @spec linear_regression([sync_point()]) ::
          {:ok, %{slope: float(), intercept: float()}} | {:error, :insufficient_data}
  defp linear_regression([_]), do: {:error, :insufficient_data}
  defp linear_regression([]), do: {:error, :insufficient_data}

  defp linear_regression(points) do
    n = length(points)

    {sum_x, sum_y, sum_xx, sum_xy} =
      Enum.reduce(points, {0, 0, 0, 0}, fn {x, y}, {sx, sy, sxx, sxy} ->
        {sx + x, sy + y, sxx + x * x, sxy + x * y}
      end)

    denom = n * sum_xx - sum_x * sum_x

    if denom == 0 do
      # All x values are identical — can't fit a line.  Use mean y.
      {:ok, %{slope: 0.0, intercept: sum_y / n}}
    else
      slope = (n * sum_xy - sum_x * sum_y) / denom
      intercept = (sum_y - slope * sum_x) / n
      {:ok, %{slope: slope, intercept: intercept}}
    end
  end

  @spec apply_regression_rtp_to_wall(integer(), state()) ::
          {:ok, wall_ns()} | {:error, :insufficient_data}
  defp apply_regression_rtp_to_wall(unwrapped_rtp, %{sync_points: [anchor | _]} = state) do
    case linear_regression(state.sync_points) do
      {:ok, %{slope: slope, intercept: intercept}} ->
        wall = round(intercept + slope * unwrapped_rtp)
        {:ok, wall}

      {:error, :insufficient_data} ->
        # Single-point fallback: use the ideal clock rate.
        {anchor_rtp, anchor_wall} = anchor
        ideal_ns_per_tick = 1_000_000_000 / state.clock_rate
        delta_ticks = unwrapped_rtp - anchor_rtp
        {:ok, round(anchor_wall + delta_ticks * ideal_ns_per_tick)}
    end
  end

  @spec apply_regression_wall_to_rtp(wall_ns(), state()) ::
          {:ok, non_neg_integer()} | {:error, :insufficient_data}
  defp apply_regression_wall_to_rtp(wall_ns, %{sync_points: [anchor | _]} = state) do
    case linear_regression(state.sync_points) do
      {:ok, %{slope: slope, intercept: intercept}} when slope != 0.0 ->
        # Invert: rtp = (wall - intercept) / slope
        unwrapped = round((wall_ns - intercept) / slope)
        wrapped = Integer.mod(unwrapped, @rtp_wraparound)
        {:ok, wrapped}

      {:ok, _} ->
        # Slope is zero — degenerate; use anchor + ideal rate.
        {anchor_rtp, anchor_wall} = anchor
        ideal_ns_per_tick = 1_000_000_000 / state.clock_rate
        delta_ticks = round((wall_ns - anchor_wall) / ideal_ns_per_tick)
        wrapped = Integer.mod(anchor_rtp + delta_ticks, @rtp_wraparound)
        {:ok, wrapped}

      {:error, :insufficient_data} ->
        # Single-point fallback.
        {anchor_rtp, anchor_wall} = anchor
        ideal_ns_per_tick = 1_000_000_000 / state.clock_rate
        delta_ticks = round((wall_ns - anchor_wall) / ideal_ns_per_tick)
        wrapped = Integer.mod(anchor_rtp + delta_ticks, @rtp_wraparound)
        {:ok, wrapped}
    end
  end

  @spec compute_drift_ppm(state()) :: {:ok, float()} | {:error, :insufficient_data}
  defp compute_drift_ppm(state) do
    case linear_regression(state.sync_points) do
      {:ok, %{slope: slope}} ->
        ideal = 1_000_000_000 / state.clock_rate
        # drift_ppm = (measured_slope - ideal_slope) / ideal_slope * 1_000_000
        ppm = (slope - ideal) / ideal * 1_000_000
        {:ok, Float.round(ppm, 3)}

      {:error, _} = err ->
        err
    end
  end
end
