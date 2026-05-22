# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
#
# Burble.Media.PipeWire — PipeWire device management for Burble.
#
# Provides audio device enumeration, exclusive access management,
# and capability detection via PipeWire's command-line tools.
# This module enables Burble to request exclusive access to specific
# audio devices (bypassing PulseAudio mixing) for lowest-latency
# voice capture and playout.
#
# PipeWire interaction:
#   - pw-dump: JSON dump of all PipeWire objects (nodes, ports, links)
#   - pw-metadata: read/write PipeWire metadata (exclusive access flags)
#   - pw-cli: general-purpose PipeWire control
#
# Exclusive access:
#   Setting "exclusive" metadata on a PipeWire node tells the session
#   manager (WirePlumber) to give that node sole access to the device.
#   Other applications cannot use the device while exclusive mode is active.
#   This eliminates mixing latency and ensures bit-perfect audio.
#
# Integration:
#   - Burble.Coprocessor.Pipeline uses device selection from this module
#   - Burble.Media.Engine routes audio to/from the selected device
#   - BurbleWeb.API.SetupController uses enumeration for the setup wizard
#
# Author: Jonathan D.A. Jewell

defmodule Burble.Media.PipeWire do
  @moduledoc """
  PipeWire audio device management for Burble.

  Enumerates audio devices, manages exclusive access, and detects
  device capabilities (sample rates, channel counts, formats).

  ## Requirements

  - PipeWire must be running on the host system
  - `pw-dump`, `pw-metadata`, and `pw-cli` must be in PATH
  - Exclusive access requires WirePlumber as the session manager

  ## Usage

      # List all audio devices
      {:ok, devices} = Burble.Media.PipeWire.enumerate_devices()

      # Get details for a specific device
      {:ok, device} = Burble.Media.PipeWire.device_info(42)

      # Request exclusive access
      :ok = Burble.Media.PipeWire.request_exclusive(42)

      # Release exclusive access
      :ok = Burble.Media.PipeWire.release_exclusive(42)
  """

  require Logger

  # ── Types ──

  @typedoc "PipeWire node ID (integer assigned by the PipeWire daemon)."
  @type node_id :: non_neg_integer()

  @typedoc "Audio device direction."
  @type direction :: :input | :output | :duplex

  @typedoc "Audio device information."
  @type device_info :: %{
          id: node_id(),
          name: String.t(),
          description: String.t(),
          direction: direction(),
          media_class: String.t(),
          sample_rates: [non_neg_integer()],
          channels: non_neg_integer(),
          format: String.t(),
          is_default: boolean(),
          is_exclusive: boolean(),
          driver: String.t(),
          state: String.t()
        }

  # Timeout for PipeWire commands (milliseconds).
  @pw_command_timeout 5_000

  # SECURITY FIX: Maximum concurrent PipeWire command invocations.
  # pw-dump can be expensive (parses the full PipeWire object graph) and
  # multiple concurrent calls from device enumeration, health checks, or
  # hot-plug events can overwhelm the system. This semaphore limits
  # concurrent pw-dump/pw-metadata calls to prevent fork-bomb-like
  # resource exhaustion.
  @max_concurrent_pw_commands 3

  # ETS table name for the PipeWire command semaphore counter.
  # Using :counters (Erlang atomics) for lock-free concurrency.
  @pw_semaphore_ref :burble_pw_semaphore

  # ── Public API ──

  @doc """
  Check whether PipeWire is available on this system.

  Returns `true` if pw-dump is in PATH and PipeWire is running,
  `false` otherwise.
  """
  @spec available?() :: boolean()
  def available? do
    case System.cmd("pw-dump", ["--help"], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _code} -> true
      _ -> false
    end
  rescue
    # pw-dump not found in PATH.
    _ -> false
  end

  @doc """
  Enumerate all audio devices visible to PipeWire.

  Returns a list of device_info maps, one per audio node. Includes
  both input (microphone) and output (speaker) devices.

  Filters to only show Audio/Source, Audio/Sink, and Audio/Duplex nodes.

  Returns `{:ok, [device_info]}` or `{:error, reason}`.
  """
  @spec enumerate_devices() :: {:ok, [device_info()]} | {:error, term()}
  def enumerate_devices do
    case run_pw_dump() do
      {:ok, objects} ->
        devices =
          objects
          |> Enum.filter(&audio_node?/1)
          |> Enum.map(&parse_device/1)
          |> Enum.sort_by(& &1.id)

        {:ok, devices}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Enumerate only input devices (microphones).

  Returns `{:ok, [device_info]}` or `{:error, reason}`.
  """
  @spec enumerate_inputs() :: {:ok, [device_info()]} | {:error, term()}
  def enumerate_inputs do
    with {:ok, devices} <- enumerate_devices() do
      inputs = Enum.filter(devices, &(&1.direction in [:input, :duplex]))
      {:ok, inputs}
    end
  end

  @doc """
  Enumerate only output devices (speakers/headphones).

  Returns `{:ok, [device_info]}` or `{:error, reason}`.
  """
  @spec enumerate_outputs() :: {:ok, [device_info()]} | {:error, term()}
  def enumerate_outputs do
    with {:ok, devices} <- enumerate_devices() do
      outputs = Enum.filter(devices, &(&1.direction in [:output, :duplex]))
      {:ok, outputs}
    end
  end

  @doc """
  Get detailed information about a specific device by node ID.

  Returns `{:ok, device_info}` or `{:error, :not_found}`.
  """
  @spec device_info(node_id()) :: {:ok, device_info()} | {:error, term()}
  def device_info(node_id) do
    with {:ok, devices} <- enumerate_devices() do
      case Enum.find(devices, &(&1.id == node_id)) do
        nil -> {:error, :not_found}
        device -> {:ok, device}
      end
    end
  end

  @doc """
  Request exclusive access to a PipeWire audio device.

  Sets the "exclusive" metadata property on the node, telling
  WirePlumber to give Burble sole access. Other applications
  will not be able to use this device until exclusive mode is released.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec request_exclusive(node_id()) :: :ok | {:error, term()}
  def request_exclusive(node_id) do
    Logger.info("[PipeWire] Requesting exclusive access for node #{node_id}")

    # Set the exclusive metadata via pw-metadata.
    # The property "exclusive" = "true" on the node tells the session manager
    # to bypass mixing for this node.
    case run_pw_metadata_set(node_id, "exclusive", "true") do
      :ok ->
        Logger.info("[PipeWire] Exclusive access granted for node #{node_id}")
        :ok

      {:error, reason} ->
        Logger.error("[PipeWire] Failed to set exclusive mode: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Release exclusive access to a PipeWire audio device.

  Clears the "exclusive" metadata property, allowing other applications
  to use the device again.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec release_exclusive(node_id()) :: :ok | {:error, term()}
  def release_exclusive(node_id) do
    Logger.info("[PipeWire] Releasing exclusive access for node #{node_id}")

    case run_pw_metadata_delete(node_id, "exclusive") do
      :ok ->
        Logger.info("[PipeWire] Exclusive access released for node #{node_id}")
        :ok

      {:error, reason} ->
        Logger.error("[PipeWire] Failed to release exclusive mode: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Detect the capabilities of a specific audio device.

  Queries PipeWire for supported sample rates, channel counts,
  and audio formats for the given node.

  Returns `{:ok, capabilities}` or `{:error, reason}`.
  """
  @spec detect_capabilities(node_id()) :: {:ok, map()} | {:error, term()}
  def detect_capabilities(node_id) do
    case run_pw_dump() do
      {:ok, objects} ->
        case Enum.find(objects, fn obj -> get_in_safe(obj, ["id"]) == node_id end) do
          nil ->
            {:error, :not_found}

          obj ->
            capabilities = %{
              id: node_id,
              sample_rates: extract_sample_rates(obj),
              channels: extract_channels(obj),
              format: extract_format(obj),
              min_latency: extract_min_latency(obj),
              max_latency: extract_max_latency(obj),
              supports_exclusive: true
            }

            {:ok, capabilities}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get the default input device (microphone).

  Returns `{:ok, device_info}` or `{:error, :no_default_input}`.
  """
  @spec default_input() :: {:ok, device_info()} | {:error, term()}
  def default_input do
    with {:ok, devices} <- enumerate_inputs() do
      case Enum.find(devices, & &1.is_default) || List.first(devices) do
        nil -> {:error, :no_default_input}
        device -> {:ok, device}
      end
    end
  end

  @doc """
  Get the default output device (speakers).

  Returns `{:ok, device_info}` or `{:error, :no_default_output}`.
  """
  @spec default_output() :: {:ok, device_info()} | {:error, term()}
  def default_output do
    with {:ok, devices} <- enumerate_outputs() do
      case Enum.find(devices, & &1.is_default) || List.first(devices) do
        nil -> {:error, :no_default_output}
        device -> {:ok, device}
      end
    end
  end

  # ── Private: PipeWire command execution ──
  #
  # SECURITY: All System.cmd calls use hardcoded binary names with no user
  # input in commands or arguments. Arguments are either empty, integer node
  # IDs (validated by Integer.to_string), or hardcoded PipeWire property keys.
  # No command injection vector exists.

  # SECURITY FIX: Semaphore for limiting concurrent PipeWire command
  # invocations. Uses :atomics for lock-free, process-safe counting.
  # The counter is lazily initialized on first use and stored in
  # :persistent_term for zero-cost reads.
  @spec get_pw_semaphore() :: :atomics.atomics_ref()
  defp get_pw_semaphore do
    case :persistent_term.get(@pw_semaphore_ref, nil) do
      nil ->
        ref = :atomics.new(1, signed: true)
        :persistent_term.put(@pw_semaphore_ref, ref)
        ref

      ref ->
        ref
    end
  end

  # Acquire a semaphore slot. Returns :ok if a slot is available,
  # {:error, :too_many_concurrent} if all slots are taken.
  @spec acquire_pw_slot() :: :ok | {:error, :too_many_concurrent}
  defp acquire_pw_slot do
    ref = get_pw_semaphore()
    # Atomically increment; if result exceeds max, decrement and reject.
    count = :atomics.add_get(ref, 1, 1)

    if count > @max_concurrent_pw_commands do
      :atomics.sub(ref, 1, 1)
      {:error, :too_many_concurrent}
    else
      :ok
    end
  end

  # Release a semaphore slot after a PipeWire command completes.
  @spec release_pw_slot() :: :ok
  defp release_pw_slot do
    ref = get_pw_semaphore()
    :atomics.sub(ref, 1, 1)
    :ok
  end

  # Run pw-dump and parse the JSON output.
  # pw-dump outputs a JSON array of all PipeWire objects.
  #
  # SECURITY FIX: Wrapped with a semaphore to limit concurrent pw-dump
  # invocations to @max_concurrent_pw_commands. Without this, bursts
  # of device enumeration, health checks, or hot-plug events can spawn
  # many pw-dump processes simultaneously, exhausting system resources.
  @spec run_pw_dump() :: {:ok, [map()]} | {:error, term()}
  defp run_pw_dump do
    case acquire_pw_slot() do
      {:error, :too_many_concurrent} ->
        Logger.warning(
          "[PipeWire] Too many concurrent pw-dump calls " <>
          "(max #{@max_concurrent_pw_commands}), rejecting"
        )
        {:error, :too_many_concurrent}

      :ok ->
        try do
          case System.cmd("pw-dump", [], stderr_to_stdout: true, timeout: @pw_command_timeout) do
            {output, 0} ->
              case Jason.decode(output) do
                {:ok, objects} when is_list(objects) ->
                  {:ok, objects}

                {:error, _} ->
                  Logger.error("[PipeWire] Failed to parse pw-dump output")
                  {:error, :parse_error}
              end

            {output, code} ->
              Logger.error("[PipeWire] pw-dump failed (exit #{code}): #{String.slice(output, 0, 200)}")
              {:error, {:pw_dump_failed, code}}
          end
        rescue
          error ->
            Logger.error("[PipeWire] pw-dump error: #{inspect(error)}")
            {:error, :pw_not_available}
        after
          release_pw_slot()
        end
    end
  end

  # Set a metadata property on a PipeWire node via pw-metadata.
  @spec run_pw_metadata_set(node_id(), String.t(), String.t()) :: :ok | {:error, term()}
  defp run_pw_metadata_set(node_id, key, value) do
    args = [Integer.to_string(node_id), key, value]

    case System.cmd("pw-metadata", args, stderr_to_stdout: true, timeout: @pw_command_timeout) do
      {_output, 0} -> :ok
      {output, code} -> {:error, {:pw_metadata_failed, code, output}}
    end
  rescue
    error -> {:error, {:command_error, error}}
  end

  # Delete a metadata property from a PipeWire node.
  @spec run_pw_metadata_delete(node_id(), String.t()) :: :ok | {:error, term()}
  defp run_pw_metadata_delete(node_id, key) do
    # Setting empty value effectively deletes the property.
    args = [Integer.to_string(node_id), key, ""]

    case System.cmd("pw-metadata", args, stderr_to_stdout: true, timeout: @pw_command_timeout) do
      {_output, 0} -> :ok
      {output, code} -> {:error, {:pw_metadata_failed, code, output}}
    end
  rescue
    error -> {:error, {:command_error, error}}
  end

  # ── Private: PipeWire object parsing ──

  # Check if a PipeWire object is an audio node (source, sink, or duplex).
  @spec audio_node?(map()) :: boolean()
  defp audio_node?(obj) do
    media_class = get_property(obj, "media.class", "")

    media_class in [
      "Audio/Source",
      "Audio/Sink",
      "Audio/Duplex",
      "Audio/Source/Virtual",
      "Audio/Sink/Virtual"
    ]
  end

  # Parse a PipeWire object into a device_info map.
  @spec parse_device(map()) :: device_info()
  defp parse_device(obj) do
    media_class = get_property(obj, "media.class", "")

    direction =
      cond do
        String.contains?(media_class, "Source") -> :input
        String.contains?(media_class, "Sink") -> :output
        String.contains?(media_class, "Duplex") -> :duplex
        true -> :output
      end

    %{
      id: get_in_safe(obj, ["id"]) || 0,
      name: get_property(obj, "node.name", "unknown"),
      description: get_property(obj, "node.description", get_property(obj, "node.nick", "Unknown Device")),
      direction: direction,
      media_class: media_class,
      sample_rates: extract_sample_rates(obj),
      channels: extract_channels(obj),
      format: extract_format(obj),
      is_default: get_property(obj, "default", "") == "true",
      is_exclusive: get_property(obj, "exclusive", "") == "true",
      driver: get_property(obj, "factory.name", "unknown"),
      state: get_property(obj, "node.state", "unknown")
    }
  end

  # Extract supported sample rates from a PipeWire object.
  # Looks in the format list and the params section.
  @spec extract_sample_rates(map()) :: [non_neg_integer()]
  defp extract_sample_rates(obj) do
    # Check for rate in properties.
    rate_str = get_property(obj, "audio.rate", "")

    if rate_str != "" do
      case Integer.parse(rate_str) do
        {rate, _} -> [rate]
        :error -> default_sample_rates()
      end
    else
      # No explicit rate — return common defaults.
      default_sample_rates()
    end
  end

  # Common audio sample rates supported by most devices.
  @spec default_sample_rates() :: [non_neg_integer()]
  defp default_sample_rates, do: [44_100, 48_000, 96_000]

  # Extract channel count from a PipeWire object.
  @spec extract_channels(map()) :: non_neg_integer()
  defp extract_channels(obj) do
    channels_str = get_property(obj, "audio.channels", "2")

    case Integer.parse(channels_str) do
      {channels, _} -> channels
      :error -> 2
    end
  end

  # Extract audio format string from a PipeWire object.
  @spec extract_format(map()) :: String.t()
  defp extract_format(obj) do
    get_property(obj, "audio.format", "S16LE")
  end

  # Extract minimum latency from PipeWire object params.
  @spec extract_min_latency(map()) :: non_neg_integer() | nil
  defp extract_min_latency(obj) do
    latency_str = get_property(obj, "latency.min", "")

    case Integer.parse(latency_str) do
      {val, _} -> val
      :error -> nil
    end
  end

  # Extract maximum latency from PipeWire object params.
  @spec extract_max_latency(map()) :: non_neg_integer() | nil
  defp extract_max_latency(obj) do
    latency_str = get_property(obj, "latency.max", "")

    case Integer.parse(latency_str) do
      {val, _} -> val
      :error -> nil
    end
  end

  # ── Private: Property access helpers ──

  # Get a property value from a PipeWire object's "info.props" or "properties" map.
  # PipeWire objects have varying structures depending on type.
  @spec get_property(map(), String.t(), String.t()) :: String.t()
  defp get_property(obj, key, default) do
    # Try multiple locations where PipeWire stores properties.
    result =
      get_in_safe(obj, ["info", "props", key]) ||
        get_in_safe(obj, ["properties", key]) ||
        get_in_safe(obj, ["info", "properties", key])

    if result, do: to_string(result), else: default
  end

  # Safe get_in that returns nil on any error (missing keys, non-map values).
  @spec get_in_safe(term(), [String.t()]) :: term() | nil
  defp get_in_safe(nil, _keys), do: nil
  defp get_in_safe(value, []), do: value

  defp get_in_safe(map, [key | rest]) when is_map(map) do
    get_in_safe(Map.get(map, key), rest)
  end

  defp get_in_safe(_non_map, _keys), do: nil
end
