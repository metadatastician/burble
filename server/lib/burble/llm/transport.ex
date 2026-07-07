# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

defmodule Burble.LLM.Transport do
  @moduledoc """
  QUIC-based transport for LLM communication with TCP+TLS fallback.
  
  Features:
  - Primary: QUIC (UDP) + TLS 1.3 on port 8503
  - Fallback: TCP + TLS 1.3 on port 8085
  - IPv6 preference with IPv4 fallback
  - ALPN protocol negotiation
  - Automatic protocol detection
  """
  
  require Logger
  use GenServer

  @primary_port 8503
  @fallback_port 8085
  @alpn_protocols [~c"llm-burble", ~c"llm-burble-v1"]

  # --- Redundancy & Fallback State Machine ---

  @type endpoint :: %{
          host: String.t(),
          port: :inet.port_number(),
          priority: integer(),
          protocol: :quic | :tcp,
          status: :online | :offline | :degraded
        }

  @doc """
  Start the LLM transport manager with redundancy.
  
  Manages a pool of LLM endpoints and automatically fails over
  between them based on health checks and priority.
  """
  def start_link(opts \\ []) do
    endpoints = Keyword.get(opts, :endpoints, default_endpoints())

    # `auto_health_check: false` (tests) skips the connect-based probe that
    # would mark unreachable fixture hosts offline.
    init_arg = %{
      endpoints: endpoints,
      auto_health_check: Keyword.get(opts, :auto_health_check, true)
    }

    # `name: nil` starts an unregistered instance (tests); default is the
    # app-owned singleton registered under the module name.
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, init_arg)
      name -> GenServer.start_link(__MODULE__, init_arg, name: name)
    end
  end

  @doc """
  Get the best available LLM endpoint.
  """
  def get_active_endpoint(server \\ __MODULE__) do
    GenServer.call(server, :get_active_endpoint)
  end

  @doc """
  Report a failure on an endpoint to trigger failover.
  """
  def report_failure(server \\ __MODULE__, host, port)

  def report_failure(server, host, port) do
    GenServer.cast(server, {:report_failure, host, port})
  end

  # --- GenServer Callbacks ---

  def init(%{endpoints: endpoints, auto_health_check: auto?}) do
    # Initial health check (skipped when auto_health_check: false)
    if auto?, do: send(self(), :health_check)
    {:ok, %{endpoints: endpoints, active: nil}}
  end

  def handle_call(:get_active_endpoint, _from, state) do
    case state.active || select_best_endpoint(state.endpoints) do
      nil -> {:reply, {:error, :no_endpoint_available}, state}
      active -> {:reply, {:ok, active}, %{state | active: active}}
    end
  end

  def handle_cast({:report_failure, host, port}, state) do
    Logger.warning("LLM Endpoint failure reported: #{host}:#{port}")
    new_endpoints = Enum.map(state.endpoints, fn
      e when e.host == host and e.port == port -> %{e | status: :offline}
      e -> e
    end)
    
    # Trigger immediate failover
    new_active = select_best_endpoint(new_endpoints)
    {:noreply, %{state | endpoints: new_endpoints, active: new_active}}
  end

  def handle_info(:health_check, state) do
    # Periodic background health checks
    Process.send_after(self(), :health_check, 30_000)
    new_endpoints = Enum.map(state.endpoints, &check_endpoint_health/1)
    {:noreply, %{state | endpoints: new_endpoints}}
  end

  # --- Helpers ---

  defp default_endpoints do
    [
      %{host: "llm-primary.burble.local", port: @primary_port, priority: 1, protocol: :quic, status: :online},
      %{host: "llm-backup.burble.local", port: @primary_port, priority: 2, protocol: :quic, status: :online},
      %{host: "llm-fallback.burble.local", port: @fallback_port, priority: 3, protocol: :tcp, status: :online}
    ]
  end

  defp select_best_endpoint(endpoints) do
    endpoints
    |> Enum.filter(&(&1.status != :offline))
    |> Enum.sort_by(& &1.priority)
    |> List.first()
  end

  defp check_endpoint_health(endpoint) do
    case :gen_tcp.connect(String.to_charlist(endpoint.host), endpoint.port, [], 2_000) do
      {:ok, socket} -> :gen_tcp.close(socket); %{endpoint | status: :online}
      {:error, _} -> %{endpoint | status: :offline}
    end
  rescue
    _ -> %{endpoint | status: :offline}
  end

  @doc """
  Check if QUIC is available on this system.
  """
  def check_quic_available do
    case Application.get_env(:quicer, :available) do
      true -> :available
      false -> :unavailable
      nil -> :unavailable
    end
  rescue
    _ -> :unavailable
  end
  
  @doc """
  Start QUIC listener with TLS 1.3.
  """
  def start_quic_listener(port) when is_integer(port) do
    quic_opts = [
      alpn: @alpn_protocols,
      versions: [:v1],
      certfile: cert_path(),
      keyfile: key_path(),
      reuse_addr: true,
      ipv6: true,
      ipv4: true
    ]
    
    case :quicer.listen(port, quic_opts) do
      {:ok, listener} ->
        Logger.info("LLM service listening on QUIC port #{port}")
        {:ok, %{protocol: :quic, port: port, listener: listener}}
      {:error, reason} ->
        Logger.error("Failed to start QUIC listener: #{inspect(reason)}")
        {:error, reason}
    end
  end
  
  @doc """
  Start TCP+TLS listener as fallback.
  """
  def start_tcp_listener(port) when is_integer(port) do
    tls_opts = [
      :binary,
      packet: :raw,
      active: false,
      reuseaddr: true,
      ipv6: true,
      ipv4: true,
      ssl_opts: ssl_options()
    ]
    
    case :gen_tcp.listen(port, tls_opts) do
      {:ok, listener} ->
        Logger.info("LLM service listening on TCP+TLS port #{port}")
        {:ok, %{protocol: :tcp, port: port, listener: listener}}
      {:error, reason} ->
        Logger.error("Failed to start TCP listener: #{inspect(reason)}")
        {:error, reason}
    end
  end
  
  defp ssl_options do
    [
      versions: [:"tlsv1.3"],
      cacerts: cacert_path(),
      certfile: cert_path(),
      keyfile: key_path(),
      verify: :verify_peer,
      depth: 3,
      server_name_indication: :disable,
      alpn_preferred_protocols: @alpn_protocols
    ]
  end
  
  defp cert_path, do: Path.expand("#{:code.priv_dir(:burble)}/ssl/cert.pem")
  defp key_path, do: Path.expand("#{:code.priv_dir(:burble)}/ssl/key.pem")
  defp cacert_path, do: Path.expand("#{:code.priv_dir(:burble)}/ssl/cacert.pem")
  
  @doc """
  Handle incoming connection.
  """
  def handle_connection(listener, accept_fn) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        accept_fn.(socket)
      {:error, reason} ->
        Logger.warning("Connection failed: #{inspect(reason)}")
    end
  end
end
