# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

defmodule Burble.Transport.RTSP do
  @moduledoc """
  RTSP transport module for Burble broadcast rooms and screen share.

  Implements a lightweight RTSP server for one-to-many media distribution.
  While Burble's standard voice channels use WebRTC via the SFU (and
  optionally QUIC datagrams), broadcast scenarios require a different
  topology:

  ## Use cases

  - **Stage rooms**: A speaker broadcasts to hundreds of listeners. The SFU
    forwards a single RTP stream to this module, which redistributes via
    RTSP to all viewers — avoiding N PeerConnections for N listeners.

  - **Screen share**: A participant shares their screen as an RTP video
    stream. This module accepts the RTP input and serves it as an RTSP
    mountpoint that viewers can subscribe to.

  - **IDApTIK Q character CCTV feeds**: In IDApTIK's asymmetric co-op mode,
    Q monitors the facility via CCTV cameras. Each camera feed is an RTSP
    mountpoint that Q's PanLL workspace can display in real-time. Jessica
    never sees Q's view (asymmetric design), but Q can watch multiple
    camera feeds simultaneously and relay intel via spatial voice.

  ## Architecture

  ```
  Producer (speaker/screen/CCTV)
      │
      ▼ RTP stream
  ┌─────────────────────┐
  │ Burble.Transport.RTSP │
  │   ├─ Mountpoint A    │  ← /live/room-{id}/speaker
  │   ├─ Mountpoint B    │  ← /live/room-{id}/screen
  │   └─ Mountpoint C    │  ← /live/idaptik/{level}/cctv/{cam}
  └─────────────────────┘
      │ RTSP/RTP
      ▼ (multicast or unicast)
  [Viewer 1] [Viewer 2] ... [Viewer N]
  ```

  ## Protocol details

  - RTSP control: TCP port 8554 (configurable).
  - RTP media: UDP, dynamically allocated port pairs.
  - Codec: Opus for audio, VP8/VP9/H.264 for video (passthrough — no transcoding).
  - SDP: Generated per-mountpoint based on the producer's codec negotiation.

  ## OTP design

  This module is a GenServer that manages a registry of active mountpoints.
  Each mountpoint tracks its producer (the RTP source) and a set of
  subscribers (RTSP clients). RTP packets from the producer are fanned out
  to all subscribers with minimal copying (binary reference sharing).

  ## Configuration

  Set in `config/runtime.exs`:

      config :burble, Burble.Transport.RTSP,
        port: 8554,
        max_mountpoints: 500,
        max_subscribers_per_mount: 5000,
        rtp_port_range: {20000, 30000}
  """

  use GenServer
  require Logger

  # ---------------------------------------------------------------------------
  # Session state machine
  # ---------------------------------------------------------------------------

  defmodule Session do
    defstruct [:id, :mountpoint, :transport, :client_port, :server_port, :state, :ssrc, :created_at]

    @type t :: %__MODULE__{
      id: String.t(),
      mountpoint: String.t(),
      transport: :udp | :tcp_interleaved,
      client_port: {non_neg_integer(), non_neg_integer()} | nil,
      server_port: {non_neg_integer(), non_neg_integer()} | nil,
      state: :init | :ready | :playing | :teardown,
      ssrc: non_neg_integer(),
      created_at: DateTime.t()
    }
  end

  # ---------------------------------------------------------------------------
  # Type definitions
  # ---------------------------------------------------------------------------

  @typedoc """
  A mountpoint path, e.g., "/live/room-abc123/speaker" or
  "/live/idaptik/level-7/cctv/cam-north".
  """
  @type mountpoint_path :: String.t()

  @typedoc """
  State of a single RTSP mountpoint.

  - `:path` — the RTSP URL path for this mountpoint.
  - `:producer` — the process or socket producing RTP packets.
  - `:subscribers` — set of subscriber pids receiving RTP fanout.
  - `:sdp` — SDP description generated from the producer's codec.
  - `:room_id` — Burble room this mountpoint belongs to.
  - `:created_at` — when the mountpoint was registered.
  - `:packet_count` — running count of RTP packets distributed.
  """
  @type mountpoint :: %{
          path: mountpoint_path(),
          producer: pid() | nil,
          subscribers: MapSet.t(pid()),
          sdp: String.t() | nil,
          room_id: String.t(),
          created_at: DateTime.t(),
          packet_count: non_neg_integer()
        }

  @typedoc "GenServer state: listener socket, mountpoint registry, and RTP session table."
  @type state :: %{
          listener: :gen_tcp.socket() | nil,
          mountpoints: %{mountpoint_path() => mountpoint()},
          rtp_sockets: %{mountpoint_path() => :gen_udp.socket()},
          sessions: %{String.t() => Session.t()},
          config: keyword()
        }

  # ---------------------------------------------------------------------------
  # Default configuration
  # ---------------------------------------------------------------------------

  # Standard RTSP port (RFC 7826).
  @default_port 8554

  # Maximum concurrent mountpoints (one per broadcast/screen share).
  @default_max_mountpoints 500

  # Maximum subscribers per mountpoint (large broadcast rooms).
  @default_max_subscribers 5000

  # UDP port range for RTP media streams.
  @default_rtp_port_range {20_000, 30_000}

  # SECURITY FIX: Maximum concurrent RTSP handler connections. Without this
  # cap, an attacker can open thousands of TCP connections and spawn unbounded
  # handler processes, exhausting BEAM process/memory limits. This limit
  # bounds the connection pool to a safe level.
  @max_concurrent_connections 100

  # SECURITY FIX: Maximum connections per IP address. Prevents a single
  # source from monopolizing the connection pool.
  @max_connections_per_ip 10

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Start the RTSP transport server under the supervision tree.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, init_opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, name: name)
  end

  @doc """
  Register a new RTSP mountpoint for a broadcast room or screen share.

  Returns `{:ok, mountpoint_path}` on success. The mountpoint becomes
  available for RTSP DESCRIBE/SETUP/PLAY requests from viewers.

  ## Parameters

  - `room_id` — the Burble room UUID this mountpoint belongs to.
  - `stream_type` — `:speaker`, `:screen`, or `:cctv`.
  - `opts` — optional keyword list:
    - `:camera_id` — required for `:cctv` type (e.g., "cam-north").
    - `:level_id` — required for `:cctv` type (IDApTIK level identifier).
    - `:codec` — audio/video codec hint for SDP generation.
  """
  @spec register_mountpoint(String.t(), atom(), keyword()) ::
          {:ok, mountpoint_path()} | {:error, term()}
  def register_mountpoint(room_id, stream_type, opts \\ []) do
    GenServer.call(__MODULE__, {:register_mountpoint, room_id, stream_type, opts})
  end

  @doc """
  Remove a mountpoint and disconnect all subscribers.

  Called when a broadcast ends, screen share stops, or CCTV feed is
  deactivated. All connected RTSP clients receive a TEARDOWN.
  """
  @spec remove_mountpoint(mountpoint_path()) :: :ok | {:error, :not_found}
  def remove_mountpoint(path) do
    GenServer.call(__MODULE__, {:remove_mountpoint, path})
  end

  @doc """
  Inject an RTP packet into a mountpoint for fanout to subscribers.

  Called by the SFU or the producer's RTP receive loop. The packet is
  forwarded to all subscribers with minimal copying (Erlang binary
  reference counting ensures the packet bytes are shared, not duplicated).

  ## Parameters

  - `path` — the mountpoint path.
  - `packet` — raw RTP packet binary.
  """
  @spec inject_rtp(mountpoint_path(), binary()) :: :ok | {:error, :not_found}
  def inject_rtp(path, packet) do
    GenServer.cast(__MODULE__, {:inject_rtp, path, packet})
  end

  @doc """
  Subscribe a process to receive RTP packets from a mountpoint.

  The subscriber process will receive `{:rtsp_rtp, path, packet}` messages
  for each RTP packet distributed on this mountpoint.
  """
  @spec subscribe(mountpoint_path(), pid()) :: :ok | {:error, term()}
  def subscribe(path, subscriber_pid) do
    GenServer.call(__MODULE__, {:subscribe, path, subscriber_pid})
  end

  @doc """
  Unsubscribe a process from a mountpoint.
  """
  @spec unsubscribe(mountpoint_path(), pid()) :: :ok
  def unsubscribe(path, subscriber_pid) do
    GenServer.call(__MODULE__, {:unsubscribe, path, subscriber_pid})
  end

  @doc """
  List all active mountpoints with their subscriber counts.

  Returns a list of `{path, subscriber_count, packet_count}` tuples.
  """
  @spec list_mountpoints() :: [{mountpoint_path(), non_neg_integer(), non_neg_integer()}]
  def list_mountpoints do
    GenServer.call(__MODULE__, :list_mountpoints)
  end

  @doc """
  Get the SDP description for a mountpoint (used in RTSP DESCRIBE response).
  """
  @spec get_sdp(mountpoint_path()) :: {:ok, String.t()} | {:error, :not_found}
  def get_sdp(path) do
    GenServer.call(__MODULE__, {:get_sdp, path})
  end

  @doc """
  Return the `Session` struct for a given session ID, or `{:error, :not_found}`.

  Useful for inspecting session state from tests or other processes.
  """
  @spec get_session(GenServer.server(), String.t()) :: {:ok, Session.t()} | {:error, :not_found}
  def get_session(server \\ __MODULE__, session_id) do
    GenServer.call(server, {:get_session, session_id})
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    # Merge opts with application config and defaults.
    app_config = Application.get_env(:burble, __MODULE__, [])
    config = Keyword.merge(default_config(), Keyword.merge(app_config, opts))

    state = %{
      listener: nil,
      mountpoints: %{},
      rtp_sockets: %{},
      # RTP session table: maps session_id => Session.t()
      sessions: %{},
      config: config,
      # SECURITY FIX: Track active RTSP handler processes to enforce a
      # connection pool limit. Without this, each incoming TCP connection
      # spawns a new process unboundedly, allowing resource exhaustion via
      # connection flood attacks.
      active_handlers: MapSet.new(),
      # Per-IP connection tracking for rate limiting. Maps IP string to
      # count of active connections from that IP.
      per_ip_connections: %{}
    }

    # Start the RTSP TCP listener for control connections.
    case start_rtsp_listener(config[:port]) do
      {:ok, listener} ->
        Logger.info(
          "[Burble.Transport.RTSP] RTSP server listening on port #{config[:port]}"
        )

        # Spawn the acceptor loop to handle incoming RTSP connections.
        spawn_acceptor(listener)
        {:ok, %{state | listener: listener}}

      {:error, reason} ->
        Logger.error(
          "[Burble.Transport.RTSP] Failed to start RTSP listener: #{inspect(reason)} — " <>
            "broadcast/screen share will be unavailable"
        )

        # Degrade gracefully — broadcast features are optional.
        {:ok, state}
    end
  end

  @impl true
  def handle_call({:register_mountpoint, room_id, stream_type, opts}, _from, state) do
    # Build the mountpoint path from room ID and stream type.
    path = build_mountpoint_path(room_id, stream_type, opts)

    if map_size(state.mountpoints) >= state.config[:max_mountpoints] do
      {:reply, {:error, :max_mountpoints_reached}, state}
    else
      mount = %{
        path: path,
        producer: nil,
        subscribers: MapSet.new(),
        sdp: generate_sdp(path, stream_type, opts),
        room_id: room_id,
        created_at: DateTime.utc_now(),
        packet_count: 0
      }

      Logger.info("[Burble.Transport.RTSP] Registered mountpoint: #{path}")

      updated = put_in(state, [:mountpoints, path], mount)
      {:reply, {:ok, path}, updated}
    end
  end

  @impl true
  def handle_call({:remove_mountpoint, path}, _from, state) do
    case Map.pop(state.mountpoints, path) do
      {nil, _} ->
        {:reply, {:error, :not_found}, state}

      {mount, remaining} ->
        # Notify all subscribers that the mountpoint is going away.
        for sub <- mount.subscribers do
          send(sub, {:rtsp_teardown, path})
        end

        # Close the RTP socket if one was allocated.
        case Map.pop(state.rtp_sockets, path) do
          {nil, _} -> :ok
          {socket, _} -> :gen_udp.close(socket)
        end

        Logger.info(
          "[Burble.Transport.RTSP] Removed mountpoint: #{path} " <>
            "(#{MapSet.size(mount.subscribers)} subscribers disconnected)"
        )

        {:reply, :ok,
         %{state | mountpoints: remaining, rtp_sockets: Map.delete(state.rtp_sockets, path)}}
    end
  end

  @impl true
  def handle_call({:subscribe, path, pid}, _from, state) do
    case Map.get(state.mountpoints, path) do
      nil ->
        {:reply, {:error, :not_found}, state}

      mount ->
        if MapSet.size(mount.subscribers) >= state.config[:max_subscribers_per_mount] do
          {:reply, {:error, :max_subscribers_reached}, state}
        else
          # Monitor the subscriber so we can clean up if it dies.
          Process.monitor(pid)
          updated = put_in(state, [:mountpoints, path, :subscribers], MapSet.put(mount.subscribers, pid))

          Logger.debug(
            "[Burble.Transport.RTSP] Subscriber added to #{path} " <>
              "(total: #{MapSet.size(mount.subscribers) + 1})"
          )

          {:reply, :ok, updated}
        end
    end
  end

  @impl true
  def handle_call({:unsubscribe, path, pid}, _from, state) do
    updated =
      update_in(state, [:mountpoints, path, :subscribers], fn
        nil -> MapSet.new()
        subs -> MapSet.delete(subs, pid)
      end)

    {:reply, :ok, updated}
  end

  @impl true
  def handle_call(:list_mountpoints, _from, state) do
    listing =
      Enum.map(state.mountpoints, fn {path, mount} ->
        {path, MapSet.size(mount.subscribers), mount.packet_count}
      end)

    {:reply, listing, state}
  end

  @impl true
  def handle_call({:get_sdp, path}, _from, state) do
    case Map.get(state.mountpoints, path) do
      nil -> {:reply, {:error, :not_found}, state}
      mount -> {:reply, {:ok, mount.sdp}, state}
    end
  end

  @impl true
  def handle_call({:get_session, session_id}, _from, state) do
    case Map.get(state.sessions, session_id) do
      nil -> {:reply, {:error, :not_found}, state}
      session -> {:reply, {:ok, session}, state}
    end
  end

  @impl true
  def handle_call({:register_session, session}, _from, state) do
    updated = put_in(state, [:sessions, session.id], session)
    {:reply, :ok, updated}
  end

  @impl true
  def handle_call({:transition_session, session_id, new_state}, _from, state) do
    case Map.get(state.sessions, session_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      session ->
        updated_session = %{session | state: new_state}
        updated = put_in(state, [:sessions, session_id], updated_session)
        {:reply, {:ok, updated_session}, updated}
    end
  end

  @impl true
  def handle_call({:delete_session, session_id}, _from, state) do
    updated = %{state | sessions: Map.delete(state.sessions, session_id)}
    {:reply, :ok, updated}
  end

  @impl true
  def handle_cast({:inject_rtp, path, packet}, state) do
    case Map.get(state.mountpoints, path) do
      nil ->
        {:noreply, state}

      mount ->
        # Fan out the RTP packet to all subscribers.
        # Erlang's binary reference counting means we share the packet
        # bytes across all send operations — no per-subscriber copy.
        for sub <- mount.subscribers do
          send(sub, {:rtsp_rtp, path, packet})
        end

        # Increment the packet counter for diagnostics.
        updated =
          update_in(state, [:mountpoints, path, :packet_count], &(&1 + 1))

        {:noreply, updated}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # A subscriber process died — remove it from all mountpoints.
    updated =
      update_in(state, [:mountpoints], fn mounts ->
        Map.new(mounts, fn {path, mount} ->
          {path, %{mount | subscribers: MapSet.delete(mount.subscribers, pid)}}
        end)
      end)

    {:noreply, updated}
  end

  @impl true
  def handle_info({:rtsp_connection, client_socket}, state) do
    # SECURITY FIX: Enforce connection pool limit and per-IP rate limiting
    # before spawning handler processes. Without this, unbounded spawn of
    # RTSP handlers enables resource exhaustion attacks. Uses spawn_link
    # instead of spawn so handler crashes are detected and tracked.
    active_count = MapSet.size(state.active_handlers)

    # Extract client IP for per-IP rate limiting.
    client_ip =
      case :inet.peername(client_socket) do
        {:ok, {ip, _port}} -> :inet.ntoa(ip) |> to_string()
        _ -> "unknown"
      end

    ip_count = Map.get(state.per_ip_connections, client_ip, 0)

    cond do
      active_count >= @max_concurrent_connections ->
        # Connection pool exhausted — reject immediately.
        Logger.warning(
          "[Burble.Transport.RTSP] Connection pool full " <>
          "(#{active_count}/#{@max_concurrent_connections}), rejecting #{client_ip}"
        )
        :gen_tcp.close(client_socket)
        if state.listener, do: spawn_acceptor(state.listener)
        {:noreply, state}

      ip_count >= @max_connections_per_ip ->
        # Per-IP limit exceeded — reject to prevent single-source flood.
        Logger.warning(
          "[Burble.Transport.RTSP] Per-IP limit exceeded for #{client_ip} " <>
          "(#{ip_count}/#{@max_connections_per_ip}), rejecting"
        )
        :gen_tcp.close(client_socket)
        if state.listener, do: spawn_acceptor(state.listener)
        {:noreply, state}

      true ->
        # Within limits — spawn a linked handler process for the RTSP
        # control session (DESCRIBE → SETUP → PLAY lifecycle).
        server_pid = self()
        handler_pid =
          spawn_link(fn ->
            try do
              handle_rtsp_session(client_socket, state)
            after
              # Notify the GenServer when the handler exits so we can
              # decrement the active connection count.
              send(server_pid, {:rtsp_handler_exit, self(), client_ip})
            end
          end)

        updated_state = %{state |
          active_handlers: MapSet.put(state.active_handlers, handler_pid),
          per_ip_connections: Map.update(state.per_ip_connections, client_ip, 1, &(&1 + 1))
        }

        # Continue accepting connections.
        if state.listener, do: spawn_acceptor(state.listener)
        {:noreply, updated_state}
    end
  end

  @impl true
  def handle_info({:rtsp_handler_exit, handler_pid, client_ip}, state) do
    # SECURITY FIX: Clean up connection tracking when a handler exits.
    # This keeps the active_handlers set and per_ip_connections map accurate,
    # preventing connection tracking leaks that would permanently reduce
    # the effective pool size.
    updated_state = %{state |
      active_handlers: MapSet.delete(state.active_handlers, handler_pid),
      per_ip_connections:
        case Map.get(state.per_ip_connections, client_ip, 0) do
          n when n <= 1 -> Map.delete(state.per_ip_connections, client_ip)
          n -> Map.put(state.per_ip_connections, client_ip, n - 1)
        end
    }
    {:noreply, updated_state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("[Burble.Transport.RTSP] Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Build default configuration.
  @spec default_config() :: keyword()
  defp default_config do
    [
      port: @default_port,
      max_mountpoints: @default_max_mountpoints,
      max_subscribers_per_mount: @default_max_subscribers,
      rtp_port_range: @default_rtp_port_range
    ]
  end

  # Start the TCP listener for RTSP control connections.
  @spec start_rtsp_listener(non_neg_integer()) :: {:ok, :gen_tcp.socket()} | {:error, term()}
  defp start_rtsp_listener(port) do
    :gen_tcp.listen(port, [
      :binary,
      {:active, false},
      {:reuseaddr, true},
      {:packet, :line}
    ])
  end

  # Spawn an asynchronous acceptor that waits for the next RTSP client.
  @spec spawn_acceptor(:gen_tcp.socket()) :: pid()
  defp spawn_acceptor(listener) do
    server = self()

    spawn(fn ->
      case :gen_tcp.accept(listener) do
        {:ok, client} ->
          send(server, {:rtsp_connection, client})

        {:error, reason} ->
          Logger.warning("[Burble.Transport.RTSP] Accept failed: #{inspect(reason)}")
      end
    end)
  end

  # Build a mountpoint path from room ID and stream type.
  #
  # Examples:
  #   - Speaker: /live/room-abc123/speaker
  #   - Screen:  /live/room-abc123/screen
  #   - CCTV:    /live/idaptik/level-7/cctv/cam-north
  @spec build_mountpoint_path(String.t(), atom(), keyword()) :: mountpoint_path()
  defp build_mountpoint_path(room_id, :speaker, _opts), do: "/live/room-#{room_id}/speaker"
  defp build_mountpoint_path(room_id, :screen, _opts), do: "/live/room-#{room_id}/screen"

  defp build_mountpoint_path(_room_id, :cctv, opts) do
    level_id = Keyword.fetch!(opts, :level_id)
    camera_id = Keyword.fetch!(opts, :camera_id)
    "/live/idaptik/#{level_id}/cctv/#{camera_id}"
  end

  defp build_mountpoint_path(room_id, type, _opts), do: "/live/room-#{room_id}/#{type}"

  # Generate a minimal SDP description for a mountpoint.
  # This is used in RTSP DESCRIBE responses so clients know what codec
  # to expect before issuing SETUP.
  @spec generate_sdp(mountpoint_path(), atom(), keyword()) :: String.t()
  defp generate_sdp(path, stream_type, opts) do
    codec = Keyword.get(opts, :codec, :opus)

    # Build SDP based on stream type and codec.
    media_line =
      case {stream_type, codec} do
        {:speaker, :opus} -> "m=audio 0 RTP/AVP 111\r\na=rtpmap:111 opus/48000/2"
        {:screen, :vp8} -> "m=video 0 RTP/AVP 96\r\na=rtpmap:96 VP8/90000"
        {:screen, :h264} -> "m=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000"
        {:cctv, _} -> "m=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000"
        {_, :opus} -> "m=audio 0 RTP/AVP 111\r\na=rtpmap:111 opus/48000/2"
        _ -> "m=audio 0 RTP/AVP 111\r\na=rtpmap:111 opus/48000/2"
      end

    """
    v=0\r
    o=burble 0 0 IN IP4 0.0.0.0\r
    s=#{path}\r
    c=IN IP4 0.0.0.0\r
    t=0 0\r
    #{media_line}\r
    a=control:#{path}\r
    """
  end

  # Handle a single RTSP control session (one TCP connection from a viewer).
  # Implements the minimal RTSP method set: OPTIONS, DESCRIBE, SETUP, PLAY, TEARDOWN.
  # `session_id` accumulates across requests on the same TCP connection so that
  # PLAY and TEARDOWN can resolve the correct Session struct.
  @spec handle_rtsp_session(:gen_tcp.socket(), state(), String.t() | nil) :: :ok
  defp handle_rtsp_session(client, state, session_id \\ nil) do
    case :gen_tcp.recv(client, 0, 30_000) do
      {:ok, line} ->
        # Parse the RTSP request line (e.g., "DESCRIBE rtsp://host/path RTSP/1.0").
        case parse_rtsp_request(line) do
          {:ok, method, path, _version} ->
            # Read all headers that follow the request line before dispatching.
            headers = read_headers(client)
            new_session_id = handle_rtsp_method(client, method, path, headers, session_id)
            # Continue reading requests on this session.
            handle_rtsp_session(client, state, new_session_id)

          {:error, _} ->
            Logger.debug("[Burble.Transport.RTSP] Malformed RTSP request, closing")
            :gen_tcp.close(client)
        end

      {:error, :timeout} ->
        Logger.debug("[Burble.Transport.RTSP] RTSP session timed out")
        :gen_tcp.close(client)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.warning("[Burble.Transport.RTSP] RTSP recv error: #{inspect(reason)}")
        :gen_tcp.close(client)
    end
  end

  # Read RTSP headers line-by-line until the blank line that ends the header block.
  # Returns a map of downcased header names to their values.
  @spec read_headers(:gen_tcp.socket()) :: %{String.t() => String.t()}
  defp read_headers(client) do
    read_headers(client, %{})
  end

  defp read_headers(client, acc) do
    case :gen_tcp.recv(client, 0, 5_000) do
      {:ok, line} ->
        trimmed = String.trim(line)

        if trimmed == "" do
          # Blank line signals end of headers.
          acc
        else
          case String.split(trimmed, ":", parts: 2) do
            [name, value] ->
              read_headers(client, Map.put(acc, String.downcase(String.trim(name)), String.trim(value)))

            _ ->
              read_headers(client, acc)
          end
        end

      {:error, _} ->
        acc
    end
  end

  # Parse an RTSP request line into {method, path, version}.
  @spec parse_rtsp_request(String.t()) :: {:ok, String.t(), String.t(), String.t()} | {:error, :malformed}
  defp parse_rtsp_request(line) do
    case String.split(String.trim(line), " ", parts: 3) do
      [method, uri, version] ->
        # Extract the path from the RTSP URI (strip scheme + host).
        path = URI.parse(uri) |> Map.get(:path, uri)
        {:ok, method, path, version}

      _ ->
        {:error, :malformed}
    end
  end

  # Dispatch RTSP methods.
  # Each clause receives the client socket, method, path, request headers map,
  # and the current session_id for this TCP connection (nil until SETUP).
  # Returns the (possibly updated) session_id — callers thread it across requests.
  @spec handle_rtsp_method(
          :gen_tcp.socket(),
          String.t(),
          String.t(),
          %{String.t() => String.t()},
          String.t() | nil
        ) :: String.t() | nil
  defp handle_rtsp_method(client, "OPTIONS", _path, _headers, session_id) do
    response =
      "RTSP/1.0 200 OK\r\n" <>
        "Public: OPTIONS, DESCRIBE, SETUP, PLAY, TEARDOWN\r\n" <>
        "\r\n"

    :gen_tcp.send(client, response)
    session_id
  end

  defp handle_rtsp_method(client, "DESCRIBE", path, _headers, session_id) do
    case get_sdp(path) do
      {:ok, sdp} ->
        response =
          "RTSP/1.0 200 OK\r\n" <>
            "Content-Type: application/sdp\r\n" <>
            "Content-Length: #{byte_size(sdp)}\r\n" <>
            "\r\n" <>
            sdp

        :gen_tcp.send(client, response)

      {:error, :not_found} ->
        :gen_tcp.send(client, "RTSP/1.0 404 Not Found\r\n\r\n")
    end

    session_id
  end

  defp handle_rtsp_method(client, "SETUP", path, headers, _session_id) do
    # Parse the Transport header to extract client RTP/RTCP port pair.
    # RFC 7826 Transport header example:
    #   Transport: RTP/AVP;unicast;client_port=4588-4589
    {transport_type, client_port} =
      case Map.get(headers, "transport") do
        nil -> {:udp, nil}
        t -> parse_transport_header(t)
      end

    # Generate a new session ID and SSRC for this RTP session.
    sid = generate_session_id()
    ssrc = generate_ssrc()

    session = %Session{
      id: sid,
      mountpoint: path,
      transport: transport_type,
      client_port: client_port,
      server_port: nil,
      state: :ready,
      ssrc: ssrc,
      created_at: DateTime.utc_now()
    }

    # Persist the session in the GenServer's session table.
    GenServer.call(__MODULE__, {:register_session, session})

    Logger.debug(
      "[Burble.Transport.RTSP] SETUP session=#{sid} mountpoint=#{path} " <>
        "transport=#{transport_type} client_port=#{inspect(client_port)} ssrc=#{ssrc}"
    )

    # Build the Transport response line — echo back client_port if present.
    transport_header =
      case client_port do
        {rtp, rtcp} ->
          "RTP/AVP;unicast;client_port=#{rtp}-#{rtcp};ssrc=#{Integer.to_string(ssrc, 16)}"

        nil ->
          "RTP/AVP;unicast;ssrc=#{Integer.to_string(ssrc, 16)}"
      end

    response =
      "RTSP/1.0 200 OK\r\n" <>
        "Transport: #{transport_header}\r\n" <>
        "Session: #{sid}\r\n" <>
        "\r\n"

    :gen_tcp.send(client, response)
    sid
  end

  defp handle_rtsp_method(client, "PLAY", _path, headers, session_id) do
    # Resolve the session ID: prefer the Session header from the client, fall
    # back to the one we're tracking on this TCP connection.
    resolved_id = Map.get(headers, "session", session_id)

    case resolved_id && GenServer.call(__MODULE__, {:get_session, resolved_id}) do
      {:ok, %Session{state: :ready} = session} ->
        # Transition to :playing.
        GenServer.call(__MODULE__, {:transition_session, session.id, :playing})

        Logger.debug("[Burble.Transport.RTSP] PLAY session=#{session.id} → :playing")

        response =
          "RTSP/1.0 200 OK\r\n" <>
            "Session: #{session.id}\r\n" <>
            "\r\n"

        :gen_tcp.send(client, response)

      {:ok, %Session{state: bad_state}} ->
        # Session exists but is not in :ready state — reject PLAY.
        Logger.warning(
          "[Burble.Transport.RTSP] PLAY rejected: session #{resolved_id} is in state #{bad_state}"
        )

        :gen_tcp.send(client, "RTSP/1.0 455 Method Not Valid In This State\r\n\r\n")

      {:error, :not_found} ->
        Logger.warning("[Burble.Transport.RTSP] PLAY rejected: unknown session #{inspect(resolved_id)}")
        :gen_tcp.send(client, "RTSP/1.0 454 Session Not Found\r\n\r\n")

      nil ->
        # No session ID at all — client skipped SETUP.
        Logger.warning("[Burble.Transport.RTSP] PLAY rejected: no session established")
        :gen_tcp.send(client, "RTSP/1.0 454 Session Not Found\r\n\r\n")
    end

    resolved_id
  end

  defp handle_rtsp_method(client, "TEARDOWN", _path, headers, session_id) do
    resolved_id = Map.get(headers, "session", session_id)

    if resolved_id do
      # Transition to :teardown then remove the session.
      GenServer.call(__MODULE__, {:transition_session, resolved_id, :teardown})
      GenServer.call(__MODULE__, {:delete_session, resolved_id})
      Logger.debug("[Burble.Transport.RTSP] TEARDOWN session=#{resolved_id} cleaned up")
    end

    :gen_tcp.send(client, "RTSP/1.0 200 OK\r\n\r\n")
    :gen_tcp.close(client)
    nil
  end

  defp handle_rtsp_method(client, method, _path, _headers, session_id) do
    Logger.debug("[Burble.Transport.RTSP] Unsupported RTSP method: #{method}")
    :gen_tcp.send(client, "RTSP/1.0 405 Method Not Allowed\r\n\r\n")
    session_id
  end

  # Parse an RTSP Transport header and extract transport type + client port pair.
  # Example input: "RTP/AVP;unicast;client_port=4588-4589"
  # Returns {transport_type, client_port} where transport_type is :udp or
  # :tcp_interleaved, and client_port is {rtp_port, rtcp_port} or nil.
  @spec parse_transport_header(String.t()) ::
          {:udp | :tcp_interleaved, {non_neg_integer(), non_neg_integer()} | nil}
  defp parse_transport_header(header) do
    parts = String.split(header, ";") |> Enum.map(&String.trim/1)

    transport_type =
      if Enum.any?(parts, &(String.downcase(&1) == "interleaved" or String.starts_with?(String.downcase(&1), "rtp/avp/tcp"))) do
        :tcp_interleaved
      else
        :udp
      end

    client_port =
      Enum.find_value(parts, fn part ->
        case Regex.run(~r/^client_port=(\d+)-(\d+)$/i, part) do
          [_, rtp, rtcp] -> {String.to_integer(rtp), String.to_integer(rtcp)}
          _ -> nil
        end
      end)

    {transport_type, client_port}
  end

  # Generate a URL-safe random session ID (16 hex characters).
  @spec generate_session_id() :: String.t()
  defp generate_session_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  # Generate a random 32-bit SSRC value (RFC 3550).
  @spec generate_ssrc() :: non_neg_integer()
  defp generate_ssrc do
    <<ssrc::unsigned-integer-32>> = :crypto.strong_rand_bytes(4)
    ssrc
  end
end
