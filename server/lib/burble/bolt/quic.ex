# SPDX-License-Identifier: PMPL-1.0-or-later
#
# Burble.Bolt.Quic — QUIC transport for Burble Bolt magic packets.
#
# Wraps the optional `quicer` NIF (msquic binding) to:
#   * `available?/0` — predicate for whether the NIF is loadable.
#   * `cert_paths/0` — resolve a TLS 1.3 cert/key pair for the listener.
#   * `listen/2`    — start a QUIC server on the Bolt port. Caller process
#     receives standard quicer events: `{:quic, :new_conn, ...}`,
#     `{:quic, :dgram, conn, data}`, `{:quic, :connection_closed, ...}`.
#   * `accept_loop_start/2` — spawn an acceptor that performs handshake
#     and re-arms itself.
#   * `send_datagram/2` — one-shot client send: open conn, handshake,
#     send a single datagram, close. Used by `Burble.Bolt.Sender`'s
#     opt-in QUIC path.
#
# All public functions are safe to call even when `quicer` is not loaded —
# they return `{:error, :quicer_not_available}` rather than raising.

defmodule Burble.Bolt.Quic do
  require Logger

  alias Burble.Bolt.Packet

  # Module atom for the optional :quicer NIF. Referenced via apply/3 so the
  # compiler does not warn when msquic is absent at build time.
  @quicer :quicer

  # ALPN identifier sent on the wire so a Bolt QUIC handshake is
  # distinguishable from a voice QUIC handshake on the same host.
  @alpn ["burble-bolt-v1"]

  # Idle-timeout for accepted Bolt QUIC connections. Bolts are one-shot;
  # 10 s is generous enough to cover a slow handshake + a single datagram.
  @idle_timeout_ms 10_000

  # Client-side handshake budget. Cold bolts cannot use 0-RTT, so a long
  # handshake just wastes time the UDP fallback could be using.
  @handshake_timeout_ms 800

  # ---------------------------------------------------------------------------
  # Predicates
  # ---------------------------------------------------------------------------

  @doc "Returns true if the quicer NIF is loaded and exposes the expected API."
  @spec available?() :: boolean()
  def available? do
    Code.ensure_loaded?(@quicer) and function_exported?(@quicer, :listen, 2)
  end

  @doc """
  Resolve `{certfile, keyfile}` paths for the Bolt QUIC listener.

  Reads (in order):
    1. `:burble, Burble.Bolt.Quic` keyword `:certfile` / `:keyfile`
    2. `priv/cert/bolt.pem` + `priv/cert/bolt_key.pem`

  Returns `{:ok, certfile, keyfile}` if both files exist on disk, otherwise
  `{:error, :no_cert}`. Cert generation is intentionally out of scope —
  see `scripts/gen-bolt-cert.sh`.
  """
  @spec cert_paths() :: {:ok, String.t(), String.t()} | {:error, :no_cert}
  def cert_paths do
    cfg = Application.get_env(:burble, __MODULE__, [])

    default_dir =
      case :code.priv_dir(:burble) do
        {:error, _} -> "priv"
        dir -> Path.join(dir, "cert")
      end

    certfile = Keyword.get(cfg, :certfile, Path.join(default_dir, "bolt.pem"))
    keyfile  = Keyword.get(cfg, :keyfile,  Path.join(default_dir, "bolt_key.pem"))

    if File.exists?(certfile) and File.exists?(keyfile) do
      {:ok, certfile, keyfile}
    else
      {:error, :no_cert}
    end
  end

  # ---------------------------------------------------------------------------
  # Server side
  # ---------------------------------------------------------------------------

  @doc """
  Start a quicer listener on `port` with Bolt's ALPN and datagram support.

  Returns `{:ok, listener_handle}` or `{:error, reason}`. Reasons include
  `:quicer_not_available` and `:no_cert`.
  """
  @spec listen(non_neg_integer(), keyword()) :: {:ok, term()} | {:error, term()}
  def listen(port, opts \\ []) do
    cond do
      not available?() ->
        {:error, :quicer_not_available}

      true ->
        case cert_paths() do
          {:error, :no_cert} = err ->
            err

          {:ok, certfile, keyfile} ->
            listen_opts = [
              certfile: certfile,
              keyfile: keyfile,
              alpn: Keyword.get(opts, :alpn, @alpn),
              idle_timeout_ms: Keyword.get(opts, :idle_timeout_ms, @idle_timeout_ms),
              # Bolts are pure datagrams — no streams expected.
              peer_unidi_stream_count: 0,
              peer_bidi_stream_count: 0,
              datagram_receive_enabled: true,
              datagram_send_enabled: true,
              # Allow 0-RTT for warm bolts (caller already has a session ticket).
              server_resumption_level: 2
            ]

            apply(@quicer, :listen, [port, listen_opts])
        end
    end
  end

  @doc """
  Spawn a linked acceptor process. Each accepted connection's events are
  delivered to `owner` (the listener GenServer).

  The acceptor immediately re-arms after handing off, so a steady stream
  of incoming bolts does not stall behind in-flight handshakes.
  """
  @spec accept_loop_start(term(), pid()) :: {:ok, pid()} | {:error, term()}
  def accept_loop_start(listener, owner) do
    if available?() do
      pid = spawn_link(fn -> accept_loop(listener, owner) end)
      {:ok, pid}
    else
      {:error, :quicer_not_available}
    end
  end

  defp accept_loop(listener, owner) do
    case apply(@quicer, :accept, [listener, [], 5_000]) do
      {:ok, conn} ->
        # Hand the connection to the owner — it will perform the handshake
        # and own the datagram-receive events thereafter.
        send(owner, {:bolt_quic_new_conn, conn})
        accept_loop(listener, owner)

      {:error, :timeout} ->
        accept_loop(listener, owner)

      {:error, reason} ->
        Logger.warning("[Bolt.Quic] accept failed: #{inspect(reason)}")
        accept_loop(listener, owner)
    end
  end

  @doc """
  Complete the handshake on an accepted connection and transfer ownership
  to `owner`. Called from the listener GenServer on `:bolt_quic_new_conn`.
  """
  @spec accept(term(), pid()) :: :ok | {:error, term()}
  def accept(conn, owner) do
    if available?() do
      try do
        _ = apply(@quicer, :handshake, [conn])
        _ = apply(@quicer, :controlling_process, [conn, owner])
        :ok
      rescue
        e -> {:error, {:handshake_failed, e}}
      end
    else
      {:error, :quicer_not_available}
    end
  end

  @doc "Close an accepted Bolt QUIC connection (best-effort, never raises)."
  @spec close(term()) :: :ok
  def close(conn) do
    if available?() do
      try do
        _ = apply(@quicer, :close_connection, [conn])
      rescue
        _ -> :ok
      end
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Client side
  # ---------------------------------------------------------------------------

  @doc """
  Send a single bolt datagram via QUIC to `{ip, port}`.

  Performs: dial → handshake (≤ #{@handshake_timeout_ms} ms) →
  `send_dgram` → close. Returns `:ok` on success, `{:error, reason}` on
  any failure — including `:quicer_not_available` so callers can fall
  back to UDP without special-casing.

  This is **expensive** for cold targets (full TLS 1.3 handshake) and is
  meant for warm scenarios where the caller has reason to believe the
  recipient runs a Bolt QUIC listener — typically because NAPTR/SRV
  advertised it or because there is already a Burble session in flight.
  """
  @spec send_datagram(:inet.ip_address(), binary(), keyword()) :: :ok | {:error, term()}
  def send_datagram(ip, packet, opts \\ []) do
    if not available?() do
      {:error, :quicer_not_available}
    else
      port = Keyword.get(opts, :port, Packet.port())
      timeout = Keyword.get(opts, :handshake_timeout_ms, @handshake_timeout_ms)

      conn_opts = [
        alpn: Keyword.get(opts, :alpn, @alpn),
        verify: Keyword.get(opts, :verify, :verify_none),
        datagram_receive_enabled: true,
        datagram_send_enabled: true,
        idle_timeout_ms: 5_000
      ]

      host =
        case ip do
          {_, _, _, _} = v4 -> :inet.ntoa(v4) |> List.to_string()
          {_, _, _, _, _, _, _, _} = v6 -> :inet.ntoa(v6) |> List.to_string()
          other when is_binary(other) -> other
        end

      try do
        with {:ok, conn} <- apply(@quicer, :connect, [host, port, conn_opts, timeout]),
             :ok <- apply(@quicer, :send_dgram, [conn, packet]) do
          _ = apply(@quicer, :close_connection, [conn])
          :ok
        else
          {:error, _} = err -> err
          other -> {:error, {:unexpected, other}}
        end
      rescue
        e -> {:error, {:send_failed, e}}
      end
    end
  end
end
