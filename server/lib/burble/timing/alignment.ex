# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
#
# Burble.Timing.Alignment — multi-node playout alignment for Phase 4 PTP.
#
# When multiple Burble nodes (separate machines) share a room, each node's
# clock has a slight offset and drift relative to the others. This module
# collects per-node {rtp_ts, wall_ns} observations (forwarded from peer.ex
# via cast or Phoenix PubSub) and computes the nanosecond offset each remote
# node's clock has from the local node's clock.
#
# Consumers (e.g. the playout jitter buffer) call playout_offset_ns/1 to get
# the correction they must add to their playout timer to keep in phase with a
# given remote node.
#
# Design decisions:
#
#   • "offset" is defined as:  remote_wall_ns_at_observation - local_wall_ns_now
#     A positive offset means the remote clock is ahead of the local clock.
#   • Drift is computed as  delta_offset_ns / delta_monotonic_ns * 1_000_000 PPM
#     so that positive PPM means the remote clock is running faster than local.
#   • Stale nodes (not seen within window_ms ms) are evicted on every cast.
#     O(N) scan is fine; rooms are capped at ~50 nodes.
#   • The local node itself is special: offset is always 0, drift is always 0.0.
#     Callers that ask for node() get {:ok, 0} without any arithmetic.
#   • No PubSub subscription is wired here. The integration point in peer.ex
#     calls report_node_sync/3 directly for same-node observations; cross-node
#     delivery is the caller's responsibility (Phoenix.PubSub broadcast + cast).
#
# Author: Jonathan D.A. Jewell

defmodule Burble.Timing.Alignment do
  @moduledoc """
  Multi-node playout alignment registry for Phase 4 PTP integration.

  Tracks per-node clock offsets and drifts so that playout buffers across
  Burble nodes in the same room can be kept in phase.

  ## Usage

      # Start (normally done by the supervisor, after ClockCorrelator)
      {:ok, _} = Alignment.start_link(name: Burble.Timing.Alignment)

      # From peer.ex, after ClockCorrelator.record_sync_point/3:
      Alignment.report_node_sync(node(), packet.timestamp, wall_ns)

      # From a playout buffer (to find out how far ahead/behind a remote node is):
      {:ok, offset_ns} = Alignment.playout_offset_ns(:"burble@192.168.1.2")

      # Health/debug endpoint:
      %{nodes: [...], local_node: :burble@host} = Alignment.sync_status()

  ## Offset convention

  `playout_offset_ns/1` returns a signed integer. Add this value to the local
  playout timer when scheduling audio from the given remote node:

    - Positive offset → remote clock is ahead; play slightly earlier.
    - Negative offset → remote clock is behind; play slightly later.

  ## Supervision note

  Do **not** add this module to `application.ex` directly. Start it in the
  supervision tree after `Burble.Timing.ClockCorrelator`.
  """

  use GenServer
  require Logger

  # ── Types ──────────────────────────────────────────────────────────────────

  @typedoc "Per-node synchronisation state."
  @type node_entry :: %{
          offset_ns: integer(),
          drift_ppm: float(),
          last_seen: integer()
        }

  @typedoc "Node map: node atom → node_entry."
  @type nodes_map :: %{atom() => node_entry()}

  @typedoc "GenServer state."
  @type state :: %{
          nodes: nodes_map(),
          local_node: atom(),
          window_ms: pos_integer(),
          # Raw previous observation per node for drift computation.
          # %{node => {prev_offset_ns, prev_monotonic_ns}}
          prev_obs: %{atom() => {integer(), integer()}}
        }

  # ── Client API ─────────────────────────────────────────────────────────────

  @doc """
  Start the Alignment GenServer.

  Options:
    - `:name`      — registered name (default: `Burble.Timing.Alignment`)
    - `:window_ms` — stale-node eviction timeout in milliseconds (default: 30_000)
    - `:local_node` — override the local node atom (default: `node()`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    server_opts = Keyword.put_new(server_opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  @doc """
  Report a simultaneous {rtp_ts, wall_ns} observation for a node.

  Typically called from `peer.ex` after `ClockCorrelator.record_sync_point/3`:

      Burble.Timing.Alignment.report_node_sync(node(), packet.timestamp, wall_ns)

  `wall_ns` must be the same wall-clock value that was passed to
  `ClockCorrelator.record_sync_point/3` (i.e. either the PTP hardware-clock
  value or `:erlang.monotonic_time(:nanosecond)`).
  """
  @spec report_node_sync(atom(), non_neg_integer(), integer()) :: :ok
  def report_node_sync(node, rtp_ts, wall_ns) do
    # Sample the matching local timestamp HERE, in the caller — measuring it
    # in the handler adds cast-queue latency to the offset, which shows up
    # directly as phantom drift (µs of jitter → thousands of bogus PPM).
    local_ns = :erlang.monotonic_time(:nanosecond)
    GenServer.cast(__MODULE__, {:report_node_sync, node, rtp_ts, wall_ns, local_ns})
  end

  @doc """
  Return the nanoseconds to add to the local playout timer to align with
  the given remote node's clock.

  Returns `{:ok, 0}` for the local node (no correction needed).
  Returns `{:error, :unknown_node}` if the node has not yet reported or has
  been evicted as stale.
  """
  @spec playout_offset_ns(atom()) :: {:ok, integer()} | {:error, :unknown_node}
  def playout_offset_ns(node) do
    GenServer.call(__MODULE__, {:playout_offset_ns, node})
  end

  @doc """
  Return the estimated clock drift of the given node relative to the local
  node, in parts-per-million (PPM).

  Positive PPM means the remote node's clock is running faster than local.
  Returns `{:ok, 0.0}` for the local node.
  Returns `{:error, :unknown_node}` if the node is unknown or stale.
  """
  @spec node_drift_ppm(atom()) :: {:ok, float()} | {:error, :unknown_node}
  def node_drift_ppm(node) do
    GenServer.call(__MODULE__, {:node_drift_ppm, node})
  end

  @doc """
  Return a summary map suitable for health/debug endpoints.

      %{
        local_node: :burble@host,
        nodes: [
          %{node: :"burble@peer1", offset_ns: 5_200, drift_ppm: 0.3, last_seen: 1234567},
          ...
        ]
      }
  """
  @spec sync_status() :: %{nodes: [map()], local_node: atom()}
  def sync_status do
    GenServer.call(__MODULE__, :sync_status)
  end

  # ── Server Callbacks ───────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    state = %{
      nodes: %{},
      local_node: Keyword.get(opts, :local_node, node()),
      window_ms: Keyword.get(opts, :window_ms, 30_000),
      prev_obs: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:report_node_sync, reporting_node, rtp_ts, wall_ns}, state) do
    # Legacy 4-tuple form: no caller-side local timestamp — sample here and
    # accept the cast-latency noise.
    local_ns = :erlang.monotonic_time(:nanosecond)
    handle_cast({:report_node_sync, reporting_node, rtp_ts, wall_ns, local_ns}, state)
  end

  @impl true
  def handle_cast({:report_node_sync, reporting_node, _rtp_ts, wall_ns, local_ns}, state) do
    now_mono_ms = monotonic_ms()
    now_ns = local_ns

    # Evict stale nodes first (O(N), ≤ ~50 nodes).
    state = evict_stale(state, now_mono_ms)

    # Compute offset: how many ns is the remote clock ahead of ours right now.
    offset_ns = wall_ns - now_ns

    # Compute drift PPM if we have a previous observation for this node.
    {drift_ppm, new_prev_obs} =
      case Map.get(state.prev_obs, reporting_node) do
        nil ->
          # First observation — no drift estimate yet.
          {0.0, Map.put(state.prev_obs, reporting_node, {offset_ns, now_ns})}

        {prev_offset_ns, prev_mono_ns} ->
          delta_offset = offset_ns - prev_offset_ns
          delta_time = now_ns - prev_mono_ns

          drift =
            if delta_time > 0 do
              delta_offset / delta_time * 1_000_000
            else
              0.0
            end

          {Float.round(drift, 3), Map.put(state.prev_obs, reporting_node, {offset_ns, now_ns})}
      end

    entry = %{
      offset_ns: offset_ns,
      drift_ppm: drift_ppm,
      last_seen: now_mono_ms
    }

    new_nodes = Map.put(state.nodes, reporting_node, entry)

    {:noreply, %{state | nodes: new_nodes, prev_obs: new_prev_obs}}
  end

  @impl true
  def handle_call({:playout_offset_ns, queried_node}, _from, state) do
    reply =
      if queried_node == state.local_node do
        {:ok, 0}
      else
        case Map.get(state.nodes, queried_node) do
          nil -> {:error, :unknown_node}
          %{offset_ns: offset_ns} -> {:ok, offset_ns}
        end
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:node_drift_ppm, queried_node}, _from, state) do
    reply =
      if queried_node == state.local_node do
        {:ok, 0.0}
      else
        case Map.get(state.nodes, queried_node) do
          nil -> {:error, :unknown_node}
          %{drift_ppm: drift_ppm} -> {:ok, drift_ppm}
        end
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call(:sync_status, _from, state) do
    node_list =
      Enum.map(state.nodes, fn {node_atom, entry} ->
        Map.put(entry, :node, node_atom)
      end)

    reply = %{
      local_node: state.local_node,
      nodes: node_list
    }

    {:reply, reply, state}
  end

  # ── Private helpers ────────────────────────────────────────────────────────

  # Evict nodes whose last_seen timestamp is older than window_ms milliseconds.
  @spec evict_stale(state(), integer()) :: state()
  defp evict_stale(%{nodes: nodes, prev_obs: prev_obs, window_ms: window_ms} = state, now_ms) do
    cutoff = now_ms - window_ms

    {live_nodes, stale_keys} =
      Enum.reduce(nodes, {%{}, []}, fn {node_atom, entry}, {live, stale} ->
        if entry.last_seen >= cutoff do
          {Map.put(live, node_atom, entry), stale}
        else
          Logger.debug("[Alignment] Evicting stale node #{node_atom} (last seen #{entry.last_seen}, cutoff #{cutoff})")
          {live, [node_atom | stale]}
        end
      end)

    new_prev_obs = Map.drop(prev_obs, stale_keys)

    %{state | nodes: live_nodes, prev_obs: new_prev_obs}
  end

  # Return the current monotonic time in milliseconds.
  @spec monotonic_ms() :: integer()
  defp monotonic_ms do
    :erlang.monotonic_time(:millisecond)
  end
end
