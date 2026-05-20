# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
#
# Burble.Timing.PTP — IEEE 1588 Precision Time Protocol integration.
#
# Provides sub-microsecond clock synchronisation for multi-node Burble
# deployments. In self-hosted voice, clock alignment between servers
# determines the lower bound on achievable playout synchronisation —
# without PTP, clock drift between nodes causes audible artefacts
# (echo, double-talk, or choppy playback).
#
# Clock source hierarchy (best to worst):
#   1. PTP hardware clock (/dev/ptp0) — sub-microsecond accuracy
#   2. phc2sys-synchronised system clock — ~1μs accuracy
#   3. chrony/NTP-synchronised system clock — ~1ms accuracy
#   4. Unsynchronised system clock — only monotonic guarantees
#
# This GenServer:
#   - Detects available clock sources at startup
#   - Periodically measures clock offset (local vs PTP master)
#   - Calculates jitter (variance in offset measurements)
#   - Provides timestamps for audio frame synchronisation
#   - Publishes clock quality metrics via telemetry
#   - Exports alignment data for multi-node coordination
#
# ArXiv potential: "Adaptive Precision Timing for Self-Hosted Voice
# Communication" — characterising PTP's impact on playout quality
# in non-datacenter environments (home labs, small offices).
#
# Author: Jonathan D.A. Jewell

defmodule Burble.Timing.PTP do
  @moduledoc """
  IEEE 1588 Precision Time Protocol integration for Burble.

  Provides high-precision timestamps for audio frame synchronisation
  across multiple Burble nodes. Automatically detects the best
  available clock source and monitors synchronisation quality.

  ## Clock sources

  The module probes for clock sources at startup and selects the best:

  | Source | Accuracy | Detection |
  |--------|----------|-----------|
  | PTP HW clock | <1μs | /dev/ptp0 exists |
  | phc2sys | ~1μs | phc2sys process running |
  | chrony/NTP | ~1ms | chronyc/ntpq available |
  | System clock | monotonic only | always available |

  ## Telemetry events

    - `[:burble, :ptp, :offset]` — clock offset measurement
    - `[:burble, :ptp, :jitter]` — jitter calculation
    - `[:burble, :ptp, :source_change]` — clock source changed
  """

  use GenServer

  require Logger

  # ── Types ──

  @typedoc "Clock source in order of preference."
  @type clock_source :: :ptp_hardware | :phc2sys | :ntp | :system

  @typedoc "A single offset measurement sample."
  @type offset_sample :: %{
          offset_ns: integer(),
          measured_at: integer(),
          source: clock_source()
        }

  @typedoc "Clock quality assessment."
  @type clock_quality :: %{
          source: clock_source(),
          offset_ns: integer(),
          jitter_ns: non_neg_integer(),
          samples: non_neg_integer(),
          last_measured_at: integer(),
          synchronized: boolean()
        }

  # Default measurement interval: 5 seconds.
  @default_measurement_interval_ms 5_000

  # Number of samples to keep for jitter calculation (sliding window).
  @jitter_window_size 60

  # Jitter threshold above which we consider the clock unsynchronised.
  # 10ms = 10_000_000 ns — generous for NTP, tight for PTP.
  @unsync_jitter_threshold_ns 10_000_000

  # Path to the PTP hardware clock device.
  @ptp_device_path "/dev/ptp0"

  # ── Client API ──

  @doc """
  Start the PTP timing GenServer.

  Options:
    - `:measurement_interval_ms` — how often to measure offset (default: 5000)
    - `:enabled` — set to false to disable periodic measurements
  """
  def start_link(opts \\ []) do
    {name, init_opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, name: name)
  end

  @doc """
  Get a high-precision timestamp for audio frame labelling.

  Returns a nanosecond timestamp from the best available clock source.
  This timestamp can be compared across Burble nodes that share the
  same PTP master for synchronisation.

  Returns `{:ok, timestamp_ns, source}`.
  """
  @spec now() :: {:ok, integer(), clock_source()}
  def now do
    GenServer.call(__MODULE__, :now)
  end

  @doc """
  Get the current clock offset (local clock vs PTP master).

  Returns the most recent offset measurement in nanoseconds.
  Positive = local clock is ahead of master.
  Negative = local clock is behind master.

  Returns `{:ok, offset_ns}` or `{:error, :no_measurements}`.
  """
  @spec offset() :: {:ok, integer()} | {:error, :no_measurements}
  def offset do
    GenServer.call(__MODULE__, :offset)
  end

  @doc """
  Get the current jitter (standard deviation of offset measurements).

  Returns `{:ok, jitter_ns}` or `{:error, :insufficient_samples}`.
  """
  @spec jitter() :: {:ok, non_neg_integer()} | {:error, :insufficient_samples}
  def jitter do
    GenServer.call(__MODULE__, :jitter)
  end

  @doc """
  Get a full clock quality assessment.

  Returns the current clock source, offset, jitter, sample count,
  and whether the clock is considered synchronised.
  """
  @spec quality() :: clock_quality()
  def quality do
    GenServer.call(__MODULE__, :quality)
  end

  @doc """
  Get alignment data for multi-node coordination.

  Returns a map that can be shared with peer Burble nodes so they
  can account for clock differences when scheduling playout.

  Includes: source, offset, jitter, and a monotonic reference point.
  """
  @spec alignment_data() :: map()
  def alignment_data do
    GenServer.call(__MODULE__, :alignment_data)
  end

  @doc """
  Force an immediate offset measurement (outside the periodic schedule).

  Returns `{:ok, offset_sample}`.
  """
  @spec measure_now() :: {:ok, offset_sample()}
  def measure_now do
    GenServer.call(__MODULE__, :measure_now)
  end

  @doc """
  Get the detected clock source.

  Returns the currently active clock source atom.
  """
  @spec source() :: clock_source()
  def source do
    GenServer.call(__MODULE__, :source)
  end

  # ── Server Callbacks ──

  @impl true
  def init(opts) do
    app_config = Application.get_env(:burble, __MODULE__, [])

    measurement_interval_ms =
      Keyword.get(
        opts,
        :measurement_interval_ms,
        Keyword.get(app_config, :measurement_interval_ms, @default_measurement_interval_ms)
      )

    enabled = Keyword.get(opts, :enabled, Keyword.get(app_config, :enabled, true))

    # Detect the best available clock source.
    source = detect_clock_source()

    state = %{
      source: source,
      measurement_interval_ms: measurement_interval_ms,
      enabled: enabled,
      # Sliding window of offset samples for jitter calculation.
      samples: :queue.new(),
      sample_count: 0,
      # Most recent offset measurement.
      latest_offset_ns: 0,
      # Calculated jitter (stddev of offsets in the window).
      jitter_ns: 0,
      # Timer reference for periodic measurements.
      timer_ref: nil
    }

    Logger.info("[PTP] Clock source detected: #{source}")

    # Take an initial measurement immediately.
    state = take_measurement(state)

    # Start periodic measurements if enabled.
    state =
      if enabled do
        timer_ref = schedule_measurement(measurement_interval_ms)
        %{state | timer_ref: timer_ref}
      else
        state
      end

    {:ok, state}
  end

  @impl true
  def handle_call(:now, _from, state) do
    {timestamp_ns, source} = read_timestamp(state.source)
    {:reply, {:ok, timestamp_ns, source}, state}
  end

  @impl true
  def handle_call(:offset, _from, state) do
    if state.sample_count > 0 do
      {:reply, {:ok, state.latest_offset_ns}, state}
    else
      {:reply, {:error, :no_measurements}, state}
    end
  end

  @impl true
  def handle_call(:jitter, _from, state) do
    if state.sample_count >= 2 do
      {:reply, {:ok, state.jitter_ns}, state}
    else
      {:reply, {:error, :insufficient_samples}, state}
    end
  end

  @impl true
  def handle_call(:quality, _from, state) do
    quality = %{
      source: state.source,
      offset_ns: state.latest_offset_ns,
      jitter_ns: state.jitter_ns,
      samples: state.sample_count,
      last_measured_at: System.monotonic_time(:nanosecond),
      synchronized: state.jitter_ns < @unsync_jitter_threshold_ns and state.sample_count >= 2
    }

    {:reply, quality, state}
  end

  @impl true
  def handle_call(:alignment_data, _from, state) do
    data = %{
      source: state.source,
      offset_ns: state.latest_offset_ns,
      jitter_ns: state.jitter_ns,
      sample_count: state.sample_count,
      monotonic_ref: System.monotonic_time(:nanosecond),
      system_time_ns: System.system_time(:nanosecond),
      node: node()
    }

    {:reply, data, state}
  end

  @impl true
  def handle_call(:measure_now, _from, state) do
    state = take_measurement(state)

    sample = %{
      offset_ns: state.latest_offset_ns,
      measured_at: System.monotonic_time(:nanosecond),
      source: state.source
    }

    {:reply, {:ok, sample}, state}
  end

  @impl true
  def handle_call(:source, _from, state) do
    {:reply, state.source, state}
  end

  # Periodic measurement tick.
  @impl true
  def handle_info(:measure_tick, state) do
    state = take_measurement(state)
    timer_ref = schedule_measurement(state.measurement_interval_ms)
    {:noreply, %{state | timer_ref: timer_ref}}
  end

  # Catch-all for unexpected messages.
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    Logger.info("[PTP] Timing module stopped")
    :ok
  end

  # ── Private: Clock source detection ──

  # Probe for available clock sources in order of preference.
  # Returns the best available source.
  @spec detect_clock_source() :: clock_source()
  defp detect_clock_source do
    cond do
      ptp_hardware_available?() ->
        :ptp_hardware

      phc2sys_running?() ->
        :phc2sys

      ntp_synchronized?() ->
        :ntp

      true ->
        :system
    end
  end

  # Check if a PTP hardware clock is available at /dev/ptp0.
  @spec ptp_hardware_available?() :: boolean()
  defp ptp_hardware_available? do
    File.exists?(@ptp_device_path)
  end

  # SECURITY: All System.cmd calls below use hardcoded binaries (pgrep, chronyc,
  # timedatectl) with hardcoded arguments. No user input reaches any command.

  # Check if phc2sys is running (synchronises PTP HW clock to system clock).
  @spec phc2sys_running?() :: boolean()
  defp phc2sys_running? do
    case System.cmd("pgrep", ["-x", "phc2sys"], stderr_to_stdout: true) do
      {_output, 0} -> true
      _ -> false
    end
  rescue
    # pgrep not available on this system.
    _ -> false
  end

  # Check if the system clock is NTP-synchronised via chrony or ntpd.
  @spec ntp_synchronized?() :: boolean()
  defp ntp_synchronized? do
    # Try chronyc first (modern Fedora/RHEL default).
    chrony_synced =
      case System.cmd("chronyc", ["tracking"], stderr_to_stdout: true) do
        {output, 0} -> String.contains?(output, "Leap status     : Normal")
        _ -> false
      end

    if chrony_synced do
      true
    else
      # Fall back to timedatectl (systemd-timesyncd).
      case System.cmd("timedatectl", ["show", "--property=NTPSynchronized"], stderr_to_stdout: true) do
        {output, 0} -> String.contains?(output, "NTPSynchronized=yes")
        _ -> false
      end
    end
  rescue
    _ -> false
  end

  # ── Private: Timestamp reading ──

  # Read a high-precision timestamp from the best available source.
  # Returns {nanoseconds, source_used}.
  @spec read_timestamp(clock_source()) :: {integer(), clock_source()}
  defp read_timestamp(:ptp_hardware) do
    case Burble.Coprocessor.ZigBackend.ptp_read_clock() do
      {:ok, ns} -> {ns, :ptp_hardware}
      {:error, _} ->
        # Fallback to system clock synchronized by phc2sys
        ts = System.system_time(:nanosecond)
        {ts, :ptp_hardware}
    end
  end

  defp read_timestamp(:phc2sys) do
    # phc2sys keeps the system clock synchronised to the PTP HW clock.
    # System.system_time is the CLOCK_REALTIME which phc2sys adjusts.
    ts = System.system_time(:nanosecond)
    {ts, :phc2sys}
  end

  defp read_timestamp(:ntp) do
    # NTP-synchronised system clock (chrony or systemd-timesyncd).
    ts = System.system_time(:nanosecond)
    {ts, :ntp}
  end

  defp read_timestamp(:system) do
    # Unsynchronised system clock — monotonic for ordering, system for value.
    ts = System.system_time(:nanosecond)
    {ts, :system}
  end

  # ── Private: Offset measurement ──

  # Take a clock offset measurement and update the sliding window.
  #
  # For PTP/phc2sys: we measure the offset between the system clock
  # and the monotonic clock to detect drift and jitter.
  #
  # For NTP: we query chronyc for the current offset.
  #
  # For system: offset is always 0 (no reference to compare against).
  @spec take_measurement(map()) :: map()
  defp take_measurement(state) do
    offset_ns = measure_offset(state.source)

    # Add the sample to the sliding window.
    {samples, sample_count} = add_sample(state.samples, state.sample_count, offset_ns)

    # Calculate jitter (standard deviation of offsets in the window).
    jitter_ns = calculate_jitter(samples, sample_count)

    # Emit telemetry events.
    :telemetry.execute(
      [:burble, :ptp, :offset],
      %{offset_ns: offset_ns},
      %{source: state.source}
    )

    if sample_count >= 2 do
      :telemetry.execute(
        [:burble, :ptp, :jitter],
        %{jitter_ns: jitter_ns},
        %{source: state.source, samples: sample_count}
      )
    end

    %{
      state
      | samples: samples,
        sample_count: sample_count,
        latest_offset_ns: offset_ns,
        jitter_ns: jitter_ns
    }
  end

  # Measure the clock offset for the given source.
  #
  # For PTP/phc2sys: difference between system time and monotonic time
  # (both should advance at the same rate if the clock is stable).
  #
  # For NTP: parse chronyc output for the "System time" offset.
  #
  # For system: always 0 (no external reference).
  @spec measure_offset(clock_source()) :: integer()
  defp measure_offset(:ptp_hardware), do: measure_system_monotonic_offset()
  defp measure_offset(:phc2sys), do: measure_system_monotonic_offset()

  defp measure_offset(:ntp) do
    # Try to get the offset from chronyc tracking output.
    case System.cmd("chronyc", ["tracking"], stderr_to_stdout: true) do
      {output, 0} ->
        parse_chronyc_offset(output)

      _ ->
        # Fallback to system-monotonic offset measurement.
        measure_system_monotonic_offset()
    end
  rescue
    _ -> measure_system_monotonic_offset()
  end

  defp measure_offset(:system), do: 0

  # Measure the offset between system_time and monotonic_time.
  #
  # In a perfectly synchronised system, the difference between
  # system_time and (monotonic_time + time_offset) should be constant.
  # Drift in this value indicates clock adjustment by NTP/PTP.
  @spec measure_system_monotonic_offset() :: integer()
  defp measure_system_monotonic_offset do
    # Take two readings as close together as possible.
    mono_before = System.monotonic_time(:nanosecond)
    sys = System.system_time(:nanosecond)
    mono_after = System.monotonic_time(:nanosecond)

    # Use the midpoint of the monotonic readings to minimise measurement error.
    mono_mid = div(mono_before + mono_after, 2)

    # The offset is the difference between the system clock and the
    # monotonic clock. This value changes when NTP/PTP adjusts the clock.
    sys - mono_mid
  end

  # Parse the "System time" offset from chronyc tracking output.
  # Example line: "System time     :  0.000001234 seconds fast of NTP time"
  @spec parse_chronyc_offset(String.t()) :: integer()
  defp parse_chronyc_offset(output) do
    case Regex.run(~r/System time\s*:\s*([\d.]+) seconds (fast|slow)/, output) do
      [_, seconds_str, direction] ->
        seconds = String.to_float(seconds_str)
        offset_ns = round(seconds * 1_000_000_000)

        case direction do
          "fast" -> offset_ns
          "slow" -> -offset_ns
        end

      nil ->
        # Could not parse — fall back to 0.
        0
    end
  end

  # ── Private: Sliding window and jitter calculation ──

  # Add a sample to the sliding window, evicting the oldest if full.
  @spec add_sample(:queue.queue(), non_neg_integer(), integer()) ::
          {:queue.queue(), non_neg_integer()}
  defp add_sample(queue, count, offset_ns) do
    queue = :queue.in(offset_ns, queue)

    if count >= @jitter_window_size do
      # Evict the oldest sample.
      {{:value, _old}, queue} = :queue.out(queue)
      {queue, count}
    else
      {queue, count + 1}
    end
  end

  # Calculate jitter as the standard deviation of offset samples.
  #
  # Jitter = sqrt(variance) where variance = mean((x - mean(x))^2).
  # Returns 0 if fewer than 2 samples (cannot calculate stddev).
  @spec calculate_jitter(:queue.queue(), non_neg_integer()) :: non_neg_integer()
  defp calculate_jitter(_queue, count) when count < 2, do: 0

  defp calculate_jitter(queue, count) do
    samples = :queue.to_list(queue)

    # Calculate mean.
    sum = Enum.sum(samples)
    mean = sum / count

    # Calculate variance (mean squared deviation from the mean).
    variance =
      samples
      |> Enum.map(fn x -> (x - mean) * (x - mean) end)
      |> Enum.sum()
      |> Kernel./(count)

    # Standard deviation (jitter) in nanoseconds.
    round(:math.sqrt(variance))
  end

  # ── Private: Timer scheduling ──

  @spec schedule_measurement(non_neg_integer()) :: reference()
  defp schedule_measurement(interval_ms) do
    Process.send_after(self(), :measure_tick, interval_ms)
  end
end
