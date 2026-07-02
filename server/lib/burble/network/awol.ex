# SPDX-License-Identifier: MPL-2.0
#
# Burble.Network.AWOL — Ad-hoc Wireless Optimized Layer protocol.
#
# AWOL provides reliable real-time communication over highly unstable
# wireless networks (WiFi handover, LTE roaming, high-loss environments).
# It is designed to sit above a multipath UDP transport (not currently
# implemented — sends are dropped with :multipath_not_wired) and adds:
#
#   1. Redundancy — selective duplication of voice/signaling packets.
#   2. Mobility — seamless IP handover (roaming) without session loss.
#   3. Layline Routing — predictive path selection based on trend analysis.
#   4. Low-latency forward error correction (FEC).
#
# The protocol is designed to "never drop a call" even when switching
# between interfaces or losing 20%+ of packets.
#
# This Elixir module implements the control plane for AWOL, managing
# session state, interface monitoring, and routing decisions.

defmodule Burble.Network.AWOL do
  @moduledoc """
  AWOL protocol implementation for Burble.

  Provides redundancy, mobility, and predictive routing for reliable
  voice communication over unstable network paths.
  """

  use GenServer

  require Logger

  # ── Types ──

  @type path_id :: String.t()
  @type session_id :: String.t()
  @type traffic_class :: :voice | :signaling | :bulk

  @type path_info :: %{
          id: path_id(),
          local_ip: :inet.ip_address(),
          remote_ip: :inet.ip_address(),
          last_seen_at: integer(),
          rtt_us: integer(),
          loss_rate: float(),
          healthy: boolean(),
          # Layline trend buffer: [ {timestamp, rtt, loss} ]
          trends: [ {integer(), integer(), float()} ]
        }

  # --- Layline Routing ---

  @doc """
  Predict the best path for the next 500ms based on trend analysis.
  Uses the 'Layline' algorithm to switch paths before degradation hits.
  """
  def predict_best_path(session_id) do
    GenServer.call(__MODULE__, {:predict_best_path, session_id})
  end

  # ── Public API ──

  @doc "Start the AWOL GenServer."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register a new network interface for a session.
  Used for mobility/handover when a new path becomes available.
  """
  def add_interface(session_id, path_id, local_ip, remote_ip) do
    GenServer.call(__MODULE__, {:add_interface, session_id, path_id, local_ip, remote_ip})
  end

  @doc """
  Send a packet with AWOL redundancy and routing.
  """
  def send(session_id, traffic_class, payload) do
    GenServer.call(__MODULE__, {:send, session_id, traffic_class, payload})
  end

  @doc """
  Signal an IP handover. Transition traffic to the new path.
  """
  def handover(session_id, to_path_id) do
    GenServer.call(__MODULE__, {:handover, session_id, to_path_id})
  end

  # ── GenServer Callbacks ──

  @impl true
  def init(_opts) do
    # Check trends every 500ms.
    :timer.send_interval(500, :analyze_trends)
    {:ok, %{sessions: %{}}}
  end

  @impl true
  def handle_call({:add_interface, session_id, path_id, local_ip, remote_ip}, _from, state) do
    session = Map.get(state.sessions, session_id, %{paths: %{}, active_path_id: nil, redundancy: 1.0})

    new_path = %{
      id: path_id,
      local_ip: local_ip,
      remote_ip: remote_ip,
      last_seen_at: System.system_time(:millisecond),
      rtt_us: 0,
      loss_rate: 0.0,
      healthy: true,
      trends: []
    }

    updated_paths = Map.put(session.paths, path_id, new_path)
    active_path = session.active_path_id || path_id

    new_session = %{session | paths: updated_paths, active_path_id: active_path}
    {:reply, :ok, %{state | sessions: Map.put(state.sessions, session_id, new_session)}}
  end

  @impl true
  def handle_call({:predict_best_path, session_id}, _from, state) do
    case Map.get(state.sessions, session_id) do
      nil -> {:reply, {:error, :not_found}, state}
      session ->
        best_path_id = run_layline_algorithm(session.paths)
        {:reply, {:ok, best_path_id}, state}
    end
  end

  @impl true
  def handle_call({:send, session_id, traffic_class, payload}, _from, state) do
    case Map.get(state.sessions, session_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      session ->
        # Implement Redundancy: send on active path + others if redundancy > 1.0.
        paths_to_use = select_paths(session, traffic_class)

        send_results = Enum.map(paths_to_use, fn _path ->
          Logger.debug("[AWOL] send: multipath transport not wired, dropping packet")
          {:error, :multipath_not_wired}
        end)

        case send_results do
          [] -> {:reply, {:error, :no_paths}, state}
          _ -> {:reply, {:error, :multipath_not_wired}, state}
        end
    end
  end

  @impl true
  def handle_call({:handover, session_id, to_path_id}, _from, state) do
    case Map.get(state.sessions, session_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      session ->
        if Map.has_key?(session.paths, to_path_id) do
          Logger.info("[AWOL] Handover session #{session_id} to #{to_path_id}")
          new_session = %{session | active_path_id: to_path_id}
          new_sessions = Map.put(state.sessions, session_id, new_session)
          {:reply, :ok, %{state | sessions: new_sessions}}
        else
          {:reply, {:error, :unknown_path}, state}
        end
    end
  end

  @impl true
  def handle_info(:analyze_trends, state) do
    # Update trend buffers for all paths in all sessions.
    new_sessions = Map.new(state.sessions, fn {sid, session} ->
      {sid, %{session | paths: update_path_trends(session.paths)}}
    end)
    {:noreply, %{state | sessions: new_sessions}}
  end

  # ── Internal: Layline Algorithm ──

  defp update_path_trends(paths) do
    now = System.system_time(:millisecond)
    Map.new(paths, fn {id, path} ->
      new_trend = [{now, path.rtt_us, path.loss_rate} | Enum.take(path.trends, 9)]
      {id, %{path | trends: new_trend}}
    end)
  end

  defp run_layline_algorithm(paths) do
    # Layline: score paths based on current value + velocity (trend) + loss penalty.
    # If RTT is increasing rapidly, penalise the path even if it's currently "low".
    paths
    |> Map.values()
    |> Enum.filter(& &1.healthy)
    |> Enum.map(fn path ->
      score = calculate_layline_score(path)
      {path.id, score}
    end)
    |> Enum.min_by(fn {_, score} -> score end, fn -> {nil, 0} end)
    |> elem(0)
  end

  defp calculate_layline_score(%{trends: []} = path), do: path.rtt_us
  defp calculate_layline_score(path) do
    {_, rtt0, l0} = Enum.at(path.trends, 0, {0, path.rtt_us, path.loss_rate})
    {_, rtt1, l1} = Enum.at(path.trends, 1, {0, rtt0, l0})
    {_, rtt2, l2} = Enum.at(path.trends, 2, {0, rtt1, l1})

    # Is it a transient spike?
    # A single large jump where the previous values were stable and much lower.
    is_spike = rtt0 > rtt1 * 1.5 and abs(rtt1 - rtt2) <= 10

    baseline = if is_spike do
      rtt1 # Ignore the spike for baseline
    else
      (rtt0 + rtt1 + rtt2) / 3
    end

    velocity = if is_spike do
      0.0 # Ignore velocity for a spike
    else
      (rtt0 - rtt2) / 2.0
    end

    # Predicted RTT in 500ms
    predicted_rtt = baseline + (velocity * 2.0)

    # Apply heavy penalty for packet loss (Loss-adjusted RTT)
    avg_loss = (l0 + l1 + l2) / 3.0
    loss_penalty = 1.0 + (avg_loss * 10.0)

    predicted_rtt * loss_penalty
  end

  # ── Helpers ──

  # Path selection with redundancy logic.
  defp select_paths(session, :signaling) do
    # Signaling is ALWAYS redundant (on all healthy paths).
    session.paths |> Map.values() |> Enum.filter(& &1.healthy)
  end

  defp select_paths(session, :voice) do
    # Voice depends on redundancy level.
    # Level 1.0 = just active path.
    # Level 2.0 = active + best alternative.
    active = Map.get(session.paths, session.active_path_id)
    [active] |> Enum.reject(&is_nil/1)
  end

  defp select_paths(session, _bulk) do
    # Bulk just uses the active path.
    active = Map.get(session.paths, session.active_path_id)
    [active] |> Enum.reject(&is_nil/1)
  end
end
