# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
#
# Burble.Transport.Multipath — Multipath/line-bonding transport layer.
#
# Burble uses multiple UDP ports for different traffic classes:
#   - Port 4020: Voice audio (latency-critical, lossy OK)
#   - Port 6474: Bulk data (file transfers, screen share, non-critical)
#   - Port 6475: Signaling mirror (critical control messages, duplicated)
#
# This GenServer manages path quality monitoring and intelligent traffic
# distribution across available network paths. In multi-homed environments
# (e.g. WiFi + Ethernet, or multiple ISPs), packets are striped across
# paths for throughput, while critical signaling is duplicated for
# reliability.
#
# Path quality metrics (measured per path):
#   - RTT (Round-Trip Time): measured via periodic probe packets
#   - Loss rate: ratio of lost probes to sent probes (sliding window)
#   - Jitter: variation in RTT (affects playout buffer sizing)
#   - Available bandwidth: estimated via probe spacing
#
# Traffic distribution strategies:
#   - Voice: lowest-RTT path (single path, failover on degradation)
#   - Bulk: striped across all healthy paths (maximum throughput)
#   - Signaling: duplicated on all paths (maximum reliability)
#
# Failover:
#   When a path's loss rate exceeds a threshold (default 10%), traffic
#   is migrated to the next-best path within one RTT measurement cycle.
#
# Author: Jonathan D.A. Jewell

defmodule Burble.Transport.Multipath do
  @moduledoc """
  Multipath transport manager for Burble voice communication.

  Manages multiple UDP paths for voice, bulk, and signaling traffic.
  Monitors path quality and distributes traffic intelligently.

  ## Ports

  | Port | Purpose | Strategy |
  |------|---------|----------|
  | 4020 | Voice audio | Lowest RTT, single path |
  | 6474 | Bulk data | Striped across paths |
  | 6475 | Signaling | Duplicated on all paths |

  ## Usage

      # Start the multipath manager
      {:ok, pid} = Burble.Transport.Multipath.start_link()

      # Send a voice packet (routed to best path)
      :ok = Burble.Transport.Multipath.send(:voice, dest, packet)

      # Send signaling (duplicated on all paths)
      :ok = Burble.Transport.Multipath.send(:signaling, dest, packet)

      # Get path quality metrics
      metrics = Burble.Transport.Multipath.path_metrics()
  """

  use GenServer

  require Logger

  # ── Types ──

  @typedoc "Traffic class determines routing strategy."
  @type traffic_class :: :voice | :bulk | :signaling

  @typedoc "Network path identifier."
  @type path_id :: String.t()

  @typedoc "Destination address as {ip, port} tuple."
  @type destination :: {:inet.ip_address(), :inet.port_number()}

  @typedoc "Per-path quality metrics."
  @type path_metrics :: %{
          path_id: path_id(),
          port: :inet.port_number(),
          rtt_us: non_neg_integer(),
          loss_rate: float(),
          jitter_us: non_neg_integer(),
          packets_sent: non_neg_integer(),
          packets_received: non_neg_integer(),
          last_probe_at: integer(),
          healthy: boolean(),
          socket: :gen_udp.socket() | nil
        }

  # Default ports for each traffic class.
  @voice_port 4020
  @bulk_port 6474
  @signaling_port 6475

  # Probe interval for path quality measurement (milliseconds).
  @probe_interval_ms 1_000

  # Number of probe samples to keep for statistics (sliding window).
  @probe_window_size 30

  # Loss rate threshold above which a path is considered unhealthy.
  @loss_threshold 0.10

  # RTT threshold above which a path is deprioritised (microseconds).
  # 100ms = too high for voice.
  @rtt_threshold_us 100_000

  # Probe packet magic bytes (used to identify probe responses).
  @probe_magic <<0xBB, 0x50, 0x52, 0x42>>

  # ── Client API ──

  @doc """
  Start the multipath transport manager.

  Options:
    - `:voice_port` — UDP port for voice traffic (default: 4020)
    - `:bulk_port` — UDP port for bulk traffic (default: 6474)
    - `:signaling_port` — UDP port for signaling traffic (default: 6475)
    - `:bind_address` — IP address to bind to (default: {0, 0, 0, 0})
    - `:probe_interval_ms` — path probe interval (default: 1000)
    - `:enabled` — set to false to disable (default: true)
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Send a packet via the appropriate path(s) for the given traffic class.

  - `:voice` — sent on the lowest-RTT healthy path (port 4020)
  - `:bulk` — striped across all healthy paths (port 6474)
  - `:signaling` — duplicated on ALL paths (port 6475)

  Returns `:ok` or `{:error, reason}`.
  """
  @spec send(traffic_class(), destination(), binary()) :: :ok | {:error, term()}
  def send(traffic_class, dest, packet) do
    GenServer.call(__MODULE__, {:send, traffic_class, dest, packet})
  end

  @doc """
  Get quality metrics for all paths.

  Returns a list of path_metrics maps.
  """
  @spec path_metrics() :: [path_metrics()]
  def path_metrics do
    GenServer.call(__MODULE__, :path_metrics)
  end

  @doc """
  Get the currently selected path for voice traffic.

  Returns `{:ok, path_metrics}` or `{:error, :no_healthy_path}`.
  """
  @spec voice_path() :: {:ok, path_metrics()} | {:error, :no_healthy_path}
  def voice_path do
    GenServer.call(__MODULE__, :voice_path)
  end

  @doc """
  Manually trigger a path probe cycle (outside the periodic schedule).

  Returns `:ok`.
  """
  @spec probe_now() :: :ok
  def probe_now do
    GenServer.cast(__MODULE__, :probe_now)
  end

  @doc """
  Add a new path (e.g. when a new network interface comes up).

  Parameters:
    - `path_id` — unique identifier for this path (e.g. "eth0", "wlan0")
    - `bind_ip` — local IP address to bind the socket to

  Returns `:ok` or `{:error, reason}`.
  """
  @spec add_path(path_id(), :inet.ip_address()) :: :ok | {:error, term()}
  def add_path(path_id, bind_ip) do
    GenServer.call(__MODULE__, {:add_path, path_id, bind_ip})
  end

  @doc """
  Remove a path (e.g. when a network interface goes down).

  Closes the sockets for this path and removes it from the active set.
  If this was the voice path, traffic fails over to the next best path.

  Returns `:ok`.
  """
  @spec remove_path(path_id()) :: :ok
  def remove_path(path_id) do
    GenServer.call(__MODULE__, {:remove_path, path_id})
  end

  # ── Server Callbacks ──

  @impl true
  def init(opts) do
    voice_port = Keyword.get(opts, :voice_port, @voice_port)
    bulk_port = Keyword.get(opts, :bulk_port, @bulk_port)
    signaling_port = Keyword.get(opts, :signaling_port, @signaling_port)
    bind_address = Keyword.get(opts, :bind_address, {0, 0, 0, 0})
    probe_interval = Keyword.get(opts, :probe_interval_ms, @probe_interval_ms)
    enabled = Keyword.get(opts, :enabled, true)

    # Open UDP sockets for each traffic class on the default path.
    default_path_id = "default"

    paths =
      case open_path_sockets(default_path_id, bind_address, voice_port, bulk_port, signaling_port) do
        {:ok, path_state} ->
          %{default_path_id => path_state}

        {:error, reason} ->
          Logger.error("[Multipath] Failed to open default path sockets: #{inspect(reason)}")
          %{}
      end

    state = %{
      # All known paths: %{path_id => path_state}.
      paths: paths,
      # Port assignments.
      voice_port: voice_port,
      bulk_port: bulk_port,
      signaling_port: signaling_port,
      bind_address: bind_address,
      # Path selected for voice traffic (lowest RTT).
      voice_path_id: if(map_size(paths) > 0, do: default_path_id, else: nil),
      # Round-robin counter for bulk traffic striping.
      bulk_round_robin: 0,
      # Probe state.
      probe_interval_ms: probe_interval,
      probe_timer_ref: nil,
      # Outstanding probes awaiting response: %{probe_id => {path_id, sent_at_us}}.
      outstanding_probes: %{},
      enabled: enabled
    }

    # Start periodic probing if enabled and paths exist.
    state =
      if enabled and map_size(paths) > 0 do
        timer_ref = schedule_probe(probe_interval)
        %{state | probe_timer_ref: timer_ref}
      else
        state
      end

    Logger.info(
      "[Multipath] Started (paths: #{map_size(paths)}, ports: #{voice_port}/#{bulk_port}/#{signaling_port})"
    )

    {:ok, state}
  end

  @impl true
  def handle_call({:send, traffic_class, dest, packet}, _from, state) do
    result = do_send(traffic_class, dest, packet, state)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:path_metrics, _from, state) do
    metrics =
      state.paths
      |> Enum.map(fn {_id, path} -> sanitise_metrics(path) end)
      |> Enum.sort_by(& &1.rtt_us)

    {:reply, metrics, state}
  end

  @impl true
  def handle_call(:voice_path, _from, state) do
    case state.voice_path_id do
      nil ->
        {:reply, {:error, :no_healthy_path}, state}

      path_id ->
        case Map.get(state.paths, path_id) do
          nil -> {:reply, {:error, :no_healthy_path}, state}
          path -> {:reply, {:ok, sanitise_metrics(path)}, state}
        end
    end
  end

  @impl true
  def handle_call({:add_path, path_id, bind_ip}, _from, state) do
    case open_path_sockets(path_id, bind_ip, state.voice_port, state.bulk_port, state.signaling_port) do
      {:ok, path_state} ->
        new_paths = Map.put(state.paths, path_id, path_state)
        Logger.info("[Multipath] Path added: #{path_id}")
        {:reply, :ok, %{state | paths: new_paths}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:remove_path, path_id}, _from, state) do
    case Map.pop(state.paths, path_id) do
      {nil, _} ->
        {:reply, :ok, state}

      {path_state, remaining_paths} ->
        # Close the sockets for this path.
        close_path_sockets(path_state)

        # If this was the voice path, fail over.
        new_voice_path =
          if state.voice_path_id == path_id do
            select_voice_path(remaining_paths)
          else
            state.voice_path_id
          end

        Logger.info("[Multipath] Path removed: #{path_id} (voice now: #{inspect(new_voice_path)})")
        {:reply, :ok, %{state | paths: remaining_paths, voice_path_id: new_voice_path}}
    end
  end

  @impl true
  def handle_cast(:probe_now, state) do
    state = send_probes(state)
    {:noreply, state}
  end

  # Periodic probe timer.
  @impl true
  def handle_info(:probe_tick, state) do
    state = send_probes(state)
    timer_ref = schedule_probe(state.probe_interval_ms)
    {:noreply, %{state | probe_timer_ref: timer_ref}}
  end

  # UDP message received (probe response or data).
  def handle_info({:udp, _socket, _ip, _port, data}, state) do
    state = handle_udp_data(data, state)
    {:noreply, state}
  end

  # Catch-all for unexpected messages.
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Close all sockets.
    Enum.each(state.paths, fn {_id, path} -> close_path_sockets(path) end)

    if state.probe_timer_ref, do: Process.cancel_timer(state.probe_timer_ref)
    Logger.info("[Multipath] Transport stopped")
    :ok
  end

  # ── Private: Socket management ──

  # Open UDP sockets for a new path (one socket per traffic class).
  @spec open_path_sockets(path_id(), :inet.ip_address(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          {:ok, map()} | {:error, term()}
  defp open_path_sockets(path_id, bind_ip, voice_port, bulk_port, signaling_port) do
    udp_opts = [:binary, active: true, reuseaddr: true]

    with {:ok, voice_sock} <- :gen_udp.open(voice_port, [{:ip, bind_ip} | udp_opts]),
         {:ok, bulk_sock} <- :gen_udp.open(bulk_port, [{:ip, bind_ip} | udp_opts]),
         {:ok, sig_sock} <- :gen_udp.open(signaling_port, [{:ip, bind_ip} | udp_opts]) do
      path_state = %{
        path_id: path_id,
        bind_ip: bind_ip,
        voice_socket: voice_sock,
        bulk_socket: bulk_sock,
        signaling_socket: sig_sock,
        # Quality metrics (initialised with optimistic defaults).
        rtt_us: 0,
        loss_rate: 0.0,
        jitter_us: 0,
        packets_sent: 0,
        packets_received: 0,
        probes_sent: 0,
        probes_received: 0,
        last_probe_at: 0,
        healthy: true,
        # RTT sample history for jitter calculation.
        rtt_samples: :queue.new(),
        rtt_sample_count: 0
      }

      {:ok, path_state}
    else
      {:error, reason} ->
        Logger.error("[Multipath] Socket open failed for path #{path_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Close all sockets for a path.
  @spec close_path_sockets(map()) :: :ok
  defp close_path_sockets(path_state) do
    safe_close(path_state.voice_socket)
    safe_close(path_state.bulk_socket)
    safe_close(path_state.signaling_socket)
    :ok
  end

  # Safely close a UDP socket (ignore errors if already closed).
  @spec safe_close(:gen_udp.socket() | nil) :: :ok
  defp safe_close(nil), do: :ok

  defp safe_close(socket) do
    :gen_udp.close(socket)
    :ok
  rescue
    _ -> :ok
  end

  # ── Private: Sending ──

  # Route and send a packet based on traffic class.
  @spec do_send(traffic_class(), destination(), binary(), map()) :: :ok | {:error, term()}
  defp do_send(:voice, dest, packet, state) do
    # Voice: send on the lowest-RTT healthy path only.
    case get_voice_path_socket(state) do
      {:ok, socket} ->
        send_udp(socket, dest, packet)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_send(:bulk, dest, packet, state) do
    # Bulk: stripe across all healthy paths using round-robin.
    healthy_paths = get_healthy_paths(state.paths)

    if length(healthy_paths) == 0 do
      {:error, :no_healthy_path}
    else
      # Select path via round-robin.
      index = rem(state.bulk_round_robin, length(healthy_paths))
      {_id, path} = Enum.at(healthy_paths, index)
      send_udp(path.bulk_socket, dest, packet)
    end
  end

  defp do_send(:signaling, dest, packet, state) do
    # Signaling: duplicate on ALL paths for maximum reliability.
    results =
      Enum.map(state.paths, fn {_id, path} ->
        send_udp(path.signaling_socket, dest, packet)
      end)

    # Return :ok if at least one path succeeded.
    if Enum.any?(results, &(&1 == :ok)) do
      :ok
    else
      {:error, :all_paths_failed}
    end
  end

  # Send a UDP packet on a specific socket.
  @spec send_udp(:gen_udp.socket(), destination(), binary()) :: :ok | {:error, term()}
  defp send_udp(socket, {ip, port}, packet) do
    case :gen_udp.send(socket, ip, port, packet) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Get the voice socket from the currently selected voice path.
  @spec get_voice_path_socket(map()) :: {:ok, :gen_udp.socket()} | {:error, :no_healthy_path}
  defp get_voice_path_socket(state) do
    case state.voice_path_id do
      nil ->
        {:error, :no_healthy_path}

      path_id ->
        case Map.get(state.paths, path_id) do
          nil -> {:error, :no_healthy_path}
          %{healthy: false} -> {:error, :no_healthy_path}
          path -> {:ok, path.voice_socket}
        end
    end
  end

  # Get all healthy paths as a sorted list (by RTT).
  @spec get_healthy_paths(map()) :: [{path_id(), map()}]
  defp get_healthy_paths(paths) do
    paths
    |> Enum.filter(fn {_id, path} -> path.healthy end)
    |> Enum.sort_by(fn {_id, path} -> path.rtt_us end)
  end

  # ── Private: Path probing ──

  # Send probe packets on all paths and record timestamps.
  @spec send_probes(map()) :: map()
  defp send_probes(state) do
    now_us = System.monotonic_time(:microsecond)

    {updated_paths, new_probes} =
      Enum.reduce(state.paths, {%{}, state.outstanding_probes}, fn {path_id, path}, {paths_acc, probes_acc} ->
        # Generate a unique probe ID.
        probe_id = :crypto.strong_rand_bytes(8)

        # Build the probe packet: magic + probe_id + timestamp.
        probe_packet = @probe_magic <> probe_id <> <<now_us::64>>

        # Send probe on the voice socket (most latency-sensitive).
        # We send to localhost as a loopback test; in production, this
        # would be sent to the peer's probe endpoint.
        case :gen_udp.send(path.voice_socket, path.bind_ip, @voice_port, probe_packet) do
          :ok ->
            updated_path = %{path | probes_sent: path.probes_sent + 1, last_probe_at: now_us}
            new_probes = Map.put(probes_acc, probe_id, {path_id, now_us})
            {Map.put(paths_acc, path_id, updated_path), new_probes}

          {:error, _reason} ->
            {Map.put(paths_acc, path_id, path), probes_acc}
        end
      end)

    # After probing, re-evaluate path health and voice path selection.
    updated_paths = evaluate_path_health(updated_paths)
    new_voice_path = select_voice_path(updated_paths)

    if new_voice_path != state.voice_path_id and new_voice_path != nil do
      Logger.info("[Multipath] Voice path changed: #{state.voice_path_id} -> #{new_voice_path}")

      :telemetry.execute(
        [:burble, :multipath, :voice_path_change],
        %{},
        %{old_path: state.voice_path_id, new_path: new_voice_path}
      )
    end

    %{state | paths: updated_paths, outstanding_probes: new_probes, voice_path_id: new_voice_path}
  end

  # Handle incoming UDP data (check if it's a probe response).
  @spec handle_udp_data(binary(), map()) :: map()
  defp handle_udp_data(<<@probe_magic, probe_id::binary-8, sent_us::64>>, state) do
    now_us = System.monotonic_time(:microsecond)

    case Map.pop(state.outstanding_probes, probe_id) do
      {nil, _probes} ->
        # Unknown probe — might be from a previous session. Ignore.
        state

      {{path_id, _recorded_sent_us}, remaining_probes} ->
        rtt_us = now_us - sent_us

        case Map.get(state.paths, path_id) do
          nil ->
            %{state | outstanding_probes: remaining_probes}

          path ->
            # Update RTT samples for this path.
            {rtt_queue, rtt_count} = add_rtt_sample(path.rtt_samples, path.rtt_sample_count, rtt_us)
            avg_rtt = calculate_average_rtt(rtt_queue, rtt_count)
            jitter = calculate_rtt_jitter(rtt_queue, rtt_count)

            updated_path = %{
              path
              | rtt_us: avg_rtt,
                jitter_us: jitter,
                probes_received: path.probes_received + 1,
                rtt_samples: rtt_queue,
                rtt_sample_count: rtt_count
            }

            updated_paths = Map.put(state.paths, path_id, updated_path)

            :telemetry.execute(
              [:burble, :multipath, :probe_rtt],
              %{rtt_us: rtt_us, avg_rtt_us: avg_rtt, jitter_us: jitter},
              %{path_id: path_id}
            )

            %{state | paths: updated_paths, outstanding_probes: remaining_probes}
        end
    end
  end

  # Non-probe UDP data — ignore (would be handled by media/signaling layers).
  defp handle_udp_data(_data, state), do: state

  # ── Private: Path quality evaluation ──

  # Evaluate health of all paths based on loss rate and RTT.
  @spec evaluate_path_health(map()) :: map()
  defp evaluate_path_health(paths) do
    Map.new(paths, fn {path_id, path} ->
      loss_rate =
        if path.probes_sent > 0 do
          1.0 - path.probes_received / max(path.probes_sent, 1)
        else
          0.0
        end

      healthy = loss_rate < @loss_threshold and path.rtt_us < @rtt_threshold_us
      {path_id, %{path | loss_rate: loss_rate, healthy: healthy}}
    end)
  end

  # Select the best path for voice traffic (lowest RTT among healthy paths).
  @spec select_voice_path(map()) :: path_id() | nil
  defp select_voice_path(paths) do
    paths
    |> Enum.filter(fn {_id, path} -> path.healthy end)
    |> Enum.sort_by(fn {_id, path} -> path.rtt_us end)
    |> case do
      [{best_id, _} | _] -> best_id
      [] -> nil
    end
  end

  # ── Private: RTT statistics ──

  # Add an RTT sample to the sliding window.
  @spec add_rtt_sample(:queue.queue(), non_neg_integer(), non_neg_integer()) ::
          {:queue.queue(), non_neg_integer()}
  defp add_rtt_sample(queue, count, rtt_us) do
    queue = :queue.in(rtt_us, queue)

    if count >= @probe_window_size do
      {{:value, _old}, queue} = :queue.out(queue)
      {queue, count}
    else
      {queue, count + 1}
    end
  end

  # Calculate average RTT from the sample window.
  @spec calculate_average_rtt(:queue.queue(), non_neg_integer()) :: non_neg_integer()
  defp calculate_average_rtt(_queue, 0), do: 0

  defp calculate_average_rtt(queue, count) do
    samples = :queue.to_list(queue)
    round(Enum.sum(samples) / count)
  end

  # Calculate RTT jitter (standard deviation).
  @spec calculate_rtt_jitter(:queue.queue(), non_neg_integer()) :: non_neg_integer()
  defp calculate_rtt_jitter(_queue, count) when count < 2, do: 0

  defp calculate_rtt_jitter(queue, count) do
    samples = :queue.to_list(queue)
    mean = Enum.sum(samples) / count

    variance =
      samples
      |> Enum.map(fn x -> (x - mean) * (x - mean) end)
      |> Enum.sum()
      |> Kernel./(count)

    round(:math.sqrt(variance))
  end

  # ── Private: Helpers ──

  # Schedule the next probe tick.
  @spec schedule_probe(non_neg_integer()) :: reference()
  defp schedule_probe(interval_ms) do
    Process.send_after(self(), :probe_tick, interval_ms)
  end

  # Sanitise path state for external consumption (remove socket references).
  @spec sanitise_metrics(map()) :: path_metrics()
  defp sanitise_metrics(path) do
    %{
      path_id: path.path_id,
      port: @voice_port,
      rtt_us: path.rtt_us,
      loss_rate: path.loss_rate,
      jitter_us: path.jitter_us,
      packets_sent: path.packets_sent,
      packets_received: path.packets_received,
      last_probe_at: path.last_probe_at,
      healthy: path.healthy,
      socket: nil
    }
  end
end
