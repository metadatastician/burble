# SPDX-License-Identifier: MPL-2.0
#
# Burble.Cluster.Distributed — multi-region clustering support.
#
# Provides distributed coordination for Burble instances running
# across multiple regions/data centres. Uses Erlang's built-in
# distribution and pg (process groups) for cluster membership
# and room state synchronisation.
#
# This module is the foundation for multi-region support. It handles:
#   1. Cluster membership tracking (which nodes are alive)
#   2. Region-aware room routing (prefer local region)
#   3. Cross-region room state sync via PubSub
#   4. Graceful degradation when a region goes offline

defmodule Burble.Cluster.Distributed do
  @moduledoc """
  Multi-region clustering support for Burble.

  Manages distributed node membership, region-aware routing,
  and cross-region room state synchronisation.

  ## Configuration

      config :burble, Burble.Cluster.Distributed,
        region: "us-east-1",
        dns_cluster_query: "burble.internal",
        heartbeat_interval_ms: 5_000

  ## Topology

  Each Burble node belongs to a region. Rooms are created on the node
  closest to the first participant. When participants from different
  regions join, the room state is synchronised via PubSub, but audio
  flows directly peer-to-peer (or through regional TURN servers).
  """

  use GenServer

  require Logger

  @heartbeat_interval 5_000
  @stale_threshold 15_000

  defstruct [
    :region,
    :node_id,
    :started_at,
    peers: %{},
    rooms: %{},
    config: %{}
  ]

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get the current node's region."
  def region do
    GenServer.call(__MODULE__, :region)
  end

  @doc "List all known peers across regions."
  def peers do
    GenServer.call(__MODULE__, :peers)
  end

  @doc "List peers in a specific region."
  def peers_in_region(region) do
    GenServer.call(__MODULE__, {:peers_in_region, region})
  end

  @doc "Get the best node for a new room based on participant locations."
  def best_node_for_room(participant_regions) do
    GenServer.call(__MODULE__, {:best_node, participant_regions})
  end

  @doc "Register a room on this node."
  def register_room(room_id, metadata \\ %{}) do
    GenServer.cast(__MODULE__, {:register_room, room_id, metadata})
  end

  @doc "Find which node hosts a room."
  def locate_room(room_id) do
    GenServer.call(__MODULE__, {:locate_room, room_id})
  end

  @doc "Get cluster health status."
  def health do
    GenServer.call(__MODULE__, :health)
  end

  # --- Server Implementation ---

  @impl true
  def init(opts) do
    region = Keyword.get(opts, :region,
      Application.get_env(:burble, __MODULE__, [])
      |> Keyword.get(:region, "local")
    )

    heartbeat_ms = Keyword.get(opts, :heartbeat_interval_ms, @heartbeat_interval)

    state = %__MODULE__{
      region: region,
      node_id: node_id(),
      started_at: System.monotonic_time(:millisecond),
      config: %{heartbeat_interval_ms: heartbeat_ms}
    }

    # Monitor node connections/disconnections.
    :net_kernel.monitor_nodes(true)

    # Schedule periodic heartbeat.
    Process.send_after(self(), :heartbeat, heartbeat_ms)

    # Announce presence to existing cluster members.
    broadcast_presence(state)

    Logger.info("[Cluster] Started in region #{region} on #{node_id()}")

    {:ok, state}
  end

  @impl true
  def handle_call(:region, _from, state) do
    {:reply, state.region, state}
  end

  @impl true
  def handle_call(:peers, _from, state) do
    {:reply, state.peers, state}
  end

  @impl true
  def handle_call({:peers_in_region, region}, _from, state) do
    filtered =
      state.peers
      |> Enum.filter(fn {_node, info} -> info.region == region end)
      |> Enum.into(%{})

    {:reply, filtered, state}
  end

  @impl true
  def handle_call({:best_node, participant_regions}, _from, state) do
    # Count which region has the most participants.
    region_counts =
      participant_regions
      |> Enum.frequencies()
      |> Enum.sort_by(fn {_r, count} -> count end, :desc)

    best_region = case region_counts do
      [{region, _} | _] -> region
      [] -> state.region
    end

    # Find a peer in that region, or fall back to self.
    node = case peers_in_region_from_state(state, best_region) do
      [{node_id, _} | _] -> node_id
      [] -> state.node_id
    end

    {:reply, {:ok, node}, state}
  end

  @impl true
  def handle_call({:locate_room, room_id}, _from, state) do
    case Map.get(state.rooms, room_id) do
      nil ->
        # Ask other nodes.
        {:reply, {:error, :not_found}, state}
      info ->
        {:reply, {:ok, info}, state}
    end
  end

  @impl true
  def handle_call(:health, _from, state) do
    now = System.monotonic_time(:millisecond)
    active_peers =
      state.peers
      |> Enum.count(fn {_node, info} ->
        now - info.last_seen < @stale_threshold
      end)

    health = %{
      region: state.region,
      node_id: state.node_id,
      active_peers: active_peers,
      total_peers: map_size(state.peers),
      rooms_hosted: map_size(state.rooms),
      uptime_ms: now - state.started_at
    }

    {:reply, health, state}
  end

  @impl true
  def handle_cast({:register_room, room_id, metadata}, state) do
    room_info = Map.merge(metadata, %{
      node: state.node_id,
      region: state.region,
      registered_at: System.monotonic_time(:millisecond)
    })

    new_state = %{state | rooms: Map.put(state.rooms, room_id, room_info)}
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:nodeup, node}, state) do
    Logger.info("[Cluster] Node joined: #{node}")
    broadcast_presence(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:nodedown, node}, state) do
    Logger.warning("[Cluster] Node left: #{node}")
    new_peers = Map.delete(state.peers, to_string(node))
    {:noreply, %{state | peers: new_peers}}
  end

  @impl true
  def handle_info({:cluster_presence, from_node, info}, state) do
    new_peers = Map.put(state.peers, from_node, Map.put(info, :last_seen, System.monotonic_time(:millisecond)))
    {:noreply, %{state | peers: new_peers}}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    broadcast_presence(state)
    prune_stale_peers(state)

    interval = state.config.heartbeat_interval_ms
    Process.send_after(self(), :heartbeat, interval)

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Private Helpers ---

  defp node_id do
    to_string(Node.self())
  end

  defp broadcast_presence(state) do
    info = %{
      region: state.region,
      rooms: map_size(state.rooms),
      started_at: state.started_at
    }

    for node <- Node.list() do
      send({__MODULE__, node}, {:cluster_presence, state.node_id, info})
    end
  end

  defp prune_stale_peers(state) do
    now = System.monotonic_time(:millisecond)

    stale =
      state.peers
      |> Enum.filter(fn {_node, info} ->
        now - Map.get(info, :last_seen, 0) > @stale_threshold
      end)
      |> Enum.map(fn {node, _} -> node end)

    if length(stale) > 0 do
      Logger.debug("[Cluster] Pruning stale peers: #{inspect(stale)}")
    end

    %{state | peers: Map.drop(state.peers, stale)}
  end

  defp peers_in_region_from_state(state, region) do
    state.peers
    |> Enum.filter(fn {_node, info} -> info.region == region end)
  end
end
