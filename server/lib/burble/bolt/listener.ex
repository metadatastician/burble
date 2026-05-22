# SPDX-License-Identifier: MPL-2.0
#
# Burble.Bolt.Listener — receives incoming Bolt packets on port 7373.
#
# Always binds raw UDP. If `:quicer` is loaded and a TLS 1.3 cert/key pair
# is resolvable via `Burble.Bolt.Quic.cert_paths/0`, also binds QUIC on the
# same port (UDP) — clients negotiate via ALPN `"burble-bolt-v1"`.
#
# QUIC datagrams (RFC 9221) provide the same unreliable delivery semantics
# as raw UDP but with TLS 1.3 authentication — the sender is
# cryptographically verified. Cold senders (no prior session) still pay a
# full handshake; warm senders with a cached session ticket get 0-RTT.
#
# Active transports are exposed via `transport/0` for telemetry and tests.

defmodule Burble.Bolt.Listener do
  use GenServer
  require Logger

  alias Burble.Bolt.{Packet, Notify, Quic}

  @port Packet.port()

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the UDP port this listener is bound to."
  def port, do: @port

  @doc """
  Returns `{:ok, [transport]}` where each element is `:udp`, `:quic`, or
  `:disabled`. The list is ordered by preference (QUIC first when active).
  """
  def transport do
    GenServer.call(__MODULE__, :transport)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    port = opts[:port] || @port
    quic_enabled? = Keyword.get(opts, :quic, true)

    udp_state = open_udp(port)
    quic_state = if quic_enabled?, do: open_quic(port), else: {:disabled, :off}

    transports =
      []
      |> add_active(:quic, quic_state)
      |> add_active(:udp, udp_state)

    log_startup(port, transports, quic_state)

    state = %{
      port: port,
      udp_socket: socket_of(udp_state),
      quic_listener: socket_of(quic_state),
      quic_acceptor: acceptor_of(quic_state),
      quic_conns: %{},
      transports: transports
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:transport, _from, state) do
    reply =
      case state.transports do
        [] -> {:ok, [:disabled]}
        ts -> {:ok, ts}
      end

    {:reply, reply, state}
  end

  # Raw UDP delivery from :gen_udp (active: true).
  @impl true
  def handle_info({:udp, _socket, src_ip, _src_port, data}, state) do
    handle_packet(data, format_ip(src_ip))
    {:noreply, state}
  end

  # ---- QUIC events from the acceptor + per-connection deliveries -----------

  # New connection accepted by Burble.Bolt.Quic.accept_loop/2.
  def handle_info({:bolt_quic_new_conn, conn}, state) do
    case Quic.accept(conn, self()) do
      :ok ->
        {:noreply, put_in(state.quic_conns[conn], :handshaking)}

      {:error, reason} ->
        Logger.debug("[Bolt] QUIC accept failed: #{inspect(reason)}")
        Quic.close(conn)
        {:noreply, state}
    end
  end

  # quicer event: handshake done.
  def handle_info({:quic, :connected, conn, _info}, state) do
    {:noreply, put_in(state.quic_conns[conn], :open)}
  end

  # quicer event: unreliable datagram received — this is the bolt itself.
  def handle_info({:quic, :dgram, _conn, data}, state) do
    handle_packet(data, "quic")
    {:noreply, state}
  end

  # quicer event: connection closed (either side).
  def handle_info({:quic, :connection_closed, conn, _reason}, state) do
    {:noreply, update_in(state.quic_conns, &Map.delete(&1, conn))}
  end

  # quicer event: peer aborted shutdown (treat like close).
  def handle_info({:quic, :shutdown, conn, _info}, state) do
    {:noreply, update_in(state.quic_conns, &Map.delete(&1, conn))}
  end

  # Unknown quicer event variant — log at debug, do not crash.
  def handle_info({:quic, tag, _conn, _info} = msg, state) do
    Logger.debug("[Bolt] unhandled quic event #{inspect(tag)}: #{inspect(msg)}")
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Private — packet dispatch
  # ---------------------------------------------------------------------------

  defp handle_packet(data, src) do
    case Packet.decode(data) do
      {:ok, packet} ->
        Logger.debug("[Bolt] Received bolt from #{src}")
        Notify.incoming(packet, src)

      {:error, :bad_magic} ->
        # Could be a WoL packet — ignore silently
        :ok

      {:error, reason} ->
        Logger.debug("[Bolt] Ignored malformed packet from #{src}: #{reason}")
    end
  end

  # ---------------------------------------------------------------------------
  # Private — transport setup
  # ---------------------------------------------------------------------------

  defp open_udp(port) do
    udp_opts = [:binary, active: true, reuseaddr: true]

    case :gen_udp.open(port, udp_opts) do
      {:ok, socket} -> {:ok, socket}
      {:error, reason} -> {:error, reason}
    end
  end

  defp open_quic(port) do
    cond do
      not Quic.available?() ->
        {:disabled, :quicer_not_available}

      true ->
        case Quic.listen(port) do
          {:ok, listener} ->
            case Quic.accept_loop_start(listener, self()) do
              {:ok, acceptor} -> {:ok, listener, acceptor}
              {:error, reason} -> {:error, reason}
            end

          {:error, :no_cert} ->
            {:disabled, :no_cert}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp socket_of({:ok, sock}), do: sock
  defp socket_of({:ok, listener, _acceptor}), do: listener
  defp socket_of(_), do: nil

  defp acceptor_of({:ok, _listener, acceptor}), do: acceptor
  defp acceptor_of(_), do: nil

  defp add_active(list, name, {:ok, _}),       do: [name | list]
  defp add_active(list, name, {:ok, _, _}),    do: [name | list]
  defp add_active(list, _name, _other),        do: list

  defp log_startup(port, [], _quic_state) do
    Logger.warning("[Bolt] Listener disabled — neither UDP nor QUIC could bind port #{port}")
  end

  defp log_startup(port, transports, quic_state) do
    Logger.info(
      "[Bolt] Listener active on port #{port} (transports: #{inspect(transports)})"
    )

    case quic_state do
      {:disabled, :quicer_not_available} ->
        Logger.info("[Bolt] QUIC disabled: quicer NIF not loaded (UDP-only)")

      {:disabled, :no_cert} ->
        Logger.info(
          "[Bolt] QUIC disabled: no TLS cert/key — run scripts/gen-bolt-cert.sh to enable"
        )

      {:disabled, :off} ->
        :ok

      {:error, reason} ->
        Logger.warning("[Bolt] QUIC listen failed: #{inspect(reason)} — UDP-only")

      _ ->
        :ok
    end
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip({a, b, c, d, e, f, g, h}),
    do: Enum.map_join([a, b, c, d, e, f, g, h], ":", &Integer.to_string(&1, 16))
  defp format_ip(other), do: inspect(other)
end
