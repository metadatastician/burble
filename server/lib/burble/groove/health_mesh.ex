# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Burble.Groove.HealthMesh — Inter-service health mesh via Groove.
#
# Periodically probes known groove peers via GET /.well-known/groove/status
# and maintains a local mesh view. Any groove-connected service can query
# GET /.well-known/groove/mesh to see which peers are up, degraded, or down.
#
# This implements section 6 of the Groove Protocol spec (mesh composition)
# with a focus on operational health rather than capability composition.
#
# Probe interval: 30 seconds (configurable).
# Probe timeout: 500ms per peer.
# Peer discovery: static port list + dynamically connected peers from Burble.Groove.

defmodule Burble.Groove.HealthMesh do
  @moduledoc """
  GenServer that monitors the health of groove peers.

  Polls known groove endpoints every 30 seconds and builds a mesh
  status view. The mesh state is queryable via `mesh_status/0` and
  exposed at `GET /.well-known/groove/mesh`.
  """

  use GenServer

  require Logger

  # Ports to probe for groove peers (excluding our own port 6473).
  @default_probe_ports [8000, 8080, 8081, 8091, 8092, 8093]

  # Probe interval in milliseconds.
  @probe_interval_ms 30_000

  # HTTP probe timeout in milliseconds.
  @probe_timeout_ms 500

  # --- Types ---

  @type peer_status :: %{
          service_id: String.t(),
          port: non_neg_integer(),
          status: :up | :degraded | :down,
          last_seen_ms: non_neg_integer(),
          capabilities: list(String.t())
        }

  # --- Client API ---

  @doc "Start the health mesh monitor."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Return the current mesh status as a map."
  @spec mesh_status() :: map()
  def mesh_status do
    GenServer.call(__MODULE__, :mesh_status)
  end

  @doc "Force an immediate probe cycle (useful for testing)."
  @spec probe_now() :: :ok
  def probe_now do
    GenServer.cast(__MODULE__, :probe_now)
  end

  @doc "Report status for a specific peer (used by WebRTC, etc.)."
  def report_peer_status(peer_id, status, metadata \\ %{}) do
    GenServer.cast(__MODULE__, {:report_peer_status, peer_id, status, metadata})
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    # Schedule the first probe after a short delay to let services start.
    Process.send_after(self(), :probe, 5_000)

    {:ok,
     %{
       peers: %{},
       last_probe_ms: 0,
       probe_ports: @default_probe_ports
     }}
  end

  @impl true
  def handle_call(:mesh_status, _from, state) do
    status = %{
      service_id: "burble",
      timestamp_ms: System.system_time(:millisecond),
      peers: Map.values(state.peers),
      peer_count: map_size(state.peers),
      last_probe_ms: state.last_probe_ms
    }

    {:reply, status, state}
  end

  @impl true
  def handle_cast(:probe_now, state) do
    new_state = do_probe(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:report_peer_status, peer_id, status, metadata}, state) do
    # Update or add peer status
    timestamp_ms = System.system_time(:millisecond)
    peer_entry = %{
      service_id: peer_id,
      status: status,
      last_seen_ms: timestamp_ms,
      capabilities: [:webrtc] ++ [metadata.type || :unknown],
      metadata: metadata
    }
    
    new_peers = Map.put(state.peers, peer_id, peer_entry)
    new_state = %{state | peers: new_peers}
    
    Logger.debug("[HealthMesh] Peer #{peer_id} status: #{status}")
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:probe, state) do
    new_state = do_probe(state)

    # Schedule next probe.
    Process.send_after(self(), :probe, @probe_interval_ms)

    {:noreply, new_state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Internal ---

  # Probe all known ports and update state.
  defp do_probe(state) do
    now_ms = System.system_time(:millisecond)

    # Also include ports from any dynamically connected groove peers.
    dynamic_ports = get_dynamic_peer_ports()
    all_ports = Enum.uniq(state.probe_ports ++ dynamic_ports)

    peers =
      all_ports
      |> Task.async_stream(
        fn port -> {port, probe_peer(port)} end,
        timeout: @probe_timeout_ms * 2,
        max_concurrency: 8,
        on_timeout: :kill_task
      )
      |> Enum.reduce(%{}, fn
        {:ok, {port, {:ok, info}}}, acc ->
          key = "#{info.service_id}:#{port}"

          Map.put(acc, key, %{
            service_id: info.service_id,
            port: port,
            status: :up,
            last_seen_ms: now_ms,
            capabilities: Map.get(info, :capabilities, [])
          })

        {:ok, {port, {:error, _reason}}}, acc ->
          # Check if we had this peer before — mark as degraded, then down.
          # Peers added via report_peer_status/3 don't carry a :port key
          # (they're identified by service_id only); use Map.get/2 so the
          # find returns nothing for those rather than raising :badkey.
          existing =
            Enum.find(state.peers, fn {_k, v} -> Map.get(v, :port) == port end)

          case existing do
            {key, prev} when prev.status == :up ->
              Map.put(acc, key, %{prev | status: :degraded, last_seen_ms: prev.last_seen_ms})

            {key, prev} when prev.status == :degraded ->
              # Already degraded, now down — remove from mesh.
              Logger.warning("[HealthMesh] Peer #{prev.service_id}:#{port} is down, removing")
              Map.delete(acc, key)

            _ ->
              acc
          end

        {:exit, _reason}, acc ->
          acc
      end)

    %{state | peers: peers, last_probe_ms: now_ms}
  end

  # Probe a single peer on the given port.
  #
  # Sends GET /.well-known/groove/status and parses the response.
  defp probe_peer(port) do
    url = "http://127.0.0.1:#{port}/.well-known/groove/status"

    case http_get(url) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"service" => sid}} ->
            {:ok, %{service_id: sid, capabilities: []}}

          {:ok, %{"service_id" => sid}} ->
            {:ok, %{service_id: sid, capabilities: []}}

          {:ok, %{"status" => "ok"}} ->
            {:ok, %{service_id: "unknown:#{port}", capabilities: []}}

          _ ->
            {:error, :invalid_response}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Minimal HTTP GET using :gen_tcp (no external HTTP client dependency).
  #
  # Burble already has reqwest/hackney available, but for probe simplicity
  # we use raw TCP to avoid adding deps or blocking the BEAM scheduler.
  defp http_get(url) do
    uri = URI.parse(url)
    host = uri.host || "127.0.0.1"
    port = uri.port || 80
    path = uri.path || "/"

    case :gen_tcp.connect(~c"#{host}", port, [:binary, active: false, packet: :raw],
           @probe_timeout_ms
         ) do
      {:ok, socket} ->
        request = "GET #{path} HTTP/1.0\r\nHost: #{host}:#{port}\r\nConnection: close\r\n\r\n"
        :gen_tcp.send(socket, request)

        result = recv_all(socket, <<>>)
        :gen_tcp.close(socket)

        case result do
          {:ok, data} ->
            # Split headers from body.
            case String.split(data, "\r\n\r\n", parts: 2) do
              [_headers, body] -> {:ok, body}
              _ -> {:ok, data}
            end

          error ->
            error
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Receive all data from a socket until it closes.
  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, @probe_timeout_ms) do
      {:ok, data} -> recv_all(socket, acc <> data)
      {:error, :closed} -> {:ok, acc}
      {:error, _reason} when byte_size(acc) > 0 -> {:ok, acc}
      {:error, reason} -> {:error, reason}
    end
  end

  # Get ports from dynamically connected groove peers (via Burble.Groove).
  defp get_dynamic_peer_ports do
    try do
      status = Burble.Groove.connection_status()

      status
      |> Map.values()
      |> Enum.flat_map(fn info ->
        # If the peer manifest included port info, extract it.
        case info do
          %{manifest: %{"endpoints" => endpoints}} when is_map(endpoints) ->
            endpoints
            |> Map.values()
            |> Enum.flat_map(fn url ->
              case URI.parse(to_string(url)) do
                %{port: p} when is_integer(p) -> [p]
                _ -> []
              end
            end)

          _ ->
            []
        end
      end)
      |> Enum.uniq()
    catch
      :exit, _ -> []
    end
  end
end
