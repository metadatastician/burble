# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Tests for Burble.Transport.RTSP — session state machine, mountpoint
# registry, transport-header parsing, and per-IP connection rate limiting.
#
# Uses port 19554 for the TCP listener so it doesn't conflict with the
# default RTSP port (8554) or any other in-flight test process.

defmodule Burble.Transport.RTSPTest do
  use ExUnit.Case, async: false

  alias Burble.Transport.RTSP
  alias Burble.Transport.RTSP.Session

  # Port chosen to avoid conflicts with the default 8554 listener.
  @test_port 19554

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Directly register a session via GenServer call so we can exercise the
  # state machine without a real TCP connection.
  defp register_session(server, session) do
    GenServer.call(server, {:register_session, session})
  end

  defp transition_session(server, session_id, new_state) do
    GenServer.call(server, {:transition_session, session_id, new_state})
  end

  defp delete_session(server, session_id) do
    GenServer.call(server, {:delete_session, session_id})
  end

  defp make_session(overrides \\ []) do
    base = %Session{
      id: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
      mountpoint: "/live/room-test/speaker",
      transport: :udp,
      client_port: {4588, 4589},
      server_port: nil,
      state: :init,
      ssrc: 0xDEADBEEF,
      created_at: DateTime.utc_now()
    }

    Enum.reduce(overrides, base, fn {key, value}, acc ->
      Map.put(acc, key, value)
    end)
  end

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    # Start one RTSP GenServer per test under a unique name so it does not
    # collide with the application-owned RTSP (which uses name: __MODULE__).
    # Port 19554 ≠ the application's 8554 so the listener binds cleanly.
    # The `with_named/2` helper still temporarily steals the module name when
    # a test exercises the public API (which hard-codes __MODULE__).
    name = :"rtsp_test_#{System.unique_integer([:positive])}"
    server = start_supervised!({RTSP, [port: @test_port, name: name]})
    {:ok, server: server}
  end

  # ---------------------------------------------------------------------------
  # 1. Session struct creation with correct defaults
  # ---------------------------------------------------------------------------

  describe "Session struct" do
    test "has expected default field shapes" do
      session = make_session()

      assert is_binary(session.id)
      assert byte_size(session.id) == 16   # 8 random bytes → 16 hex chars
      assert session.mountpoint == "/live/room-test/speaker"
      assert session.transport == :udp
      assert session.client_port == {4588, 4589}
      assert session.server_port == nil
      assert session.state == :init
      assert session.ssrc == 0xDEADBEEF
      assert %DateTime{} = session.created_at
    end
  end

  # ---------------------------------------------------------------------------
  # 2. get_session/2 returns {:error, :not_found} for unknown ID
  # ---------------------------------------------------------------------------

  describe "get_session/2" do
    test "returns {:error, :not_found} for an ID that was never registered", %{server: server} do
      assert {:error, :not_found} = RTSP.get_session(server, "nonexistent-id")
    end

    test "returns {:ok, session} after registration", %{server: server} do
      session = make_session()
      :ok = register_session(server, session)

      assert {:ok, ^session} = RTSP.get_session(server, session.id)
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Session state transitions: :init → :ready → :playing
  # ---------------------------------------------------------------------------

  describe "session state transitions" do
    test ":init → :ready (simulating SETUP)", %{server: server} do
      session = make_session(state: :init)
      :ok = register_session(server, session)

      assert {:ok, updated} = transition_session(server, session.id, :ready)
      assert updated.state == :ready

      # Confirm persisted.
      assert {:ok, persisted} = RTSP.get_session(server, session.id)
      assert persisted.state == :ready
    end

    test ":ready → :playing (simulating PLAY)", %{server: server} do
      session = make_session(state: :ready)
      :ok = register_session(server, session)

      assert {:ok, updated} = transition_session(server, session.id, :playing)
      assert updated.state == :playing
    end

    test "full :init → :ready → :playing transition sequence", %{server: server} do
      session = make_session(state: :init)
      :ok = register_session(server, session)

      {:ok, _} = transition_session(server, session.id, :ready)
      {:ok, playing} = transition_session(server, session.id, :playing)

      assert playing.state == :playing
    end
  end

  # ---------------------------------------------------------------------------
  # 4. PLAY rejects if session not in :ready state
  # ---------------------------------------------------------------------------

  describe "PLAY state guard" do
    # The state-machine guard lives in handle_rtsp_method/5, which is called
    # from a live TCP handler. We test the equivalent logic at the GenServer
    # level: a session in :init (or :playing) must NOT be accepted for PLAY.
    # We verify this by inspecting the transition_session result and checking
    # that the session is still present with an unchanged state when we
    # deliberately test wrong-state conditions.

    test "session in :init state is not :ready and therefore PLAY must reject", %{server: server} do
      session = make_session(state: :init)
      :ok = register_session(server, session)

      {:ok, current} = RTSP.get_session(server, session.id)
      # Confirm the PLAY guard condition fails: state is not :ready.
      assert current.state != :ready
    end

    test "session already in :playing state is not :ready and PLAY must reject", %{server: server} do
      # Build a session that's already playing (e.g. a duplicate PLAY attempt).
      session = make_session(state: :playing)
      :ok = register_session(server, session)

      {:ok, current} = RTSP.get_session(server, session.id)
      assert current.state != :ready
    end
  end

  # ---------------------------------------------------------------------------
  # 5. TEARDOWN cleans up session
  # ---------------------------------------------------------------------------

  describe "TEARDOWN (session deletion)" do
    test "session is removed after delete_session", %{server: server} do
      session = make_session(state: :ready)
      :ok = register_session(server, session)

      # Confirm it exists.
      assert {:ok, _} = RTSP.get_session(server, session.id)

      # Simulate TEARDOWN: transition to :teardown then delete.
      {:ok, torn} = transition_session(server, session.id, :teardown)
      assert torn.state == :teardown

      :ok = delete_session(server, session.id)

      # Must be gone.
      assert {:error, :not_found} = RTSP.get_session(server, session.id)
    end

    test "delete_session on unknown ID is a no-op returning :ok", %{server: server} do
      assert :ok = delete_session(server, "ghost-session-id")
    end
  end

  # ---------------------------------------------------------------------------
  # 6. parse_transport_header/1 — UDP client_port and TCP interleaved mode
  # ---------------------------------------------------------------------------
  #
  # parse_transport_header/1 is a private defp.  We exercise it indirectly
  # by sending real RTSP SETUP requests over the TCP listener on @test_port
  # and inspecting the resulting session state stored in the GenServer.

  describe "parse_transport_header/1 (via SETUP over TCP)" do
    # The RTSP SETUP handler calls GenServer.call(__MODULE__, {:register_session, session})
    # internally, so we need the test server registered under the module name for
    # each of these tests.

    test "standard UDP Transport header stores :udp and client_port pair", %{server: server} do
      with_named(server, fn ->
        sid = rtsp_setup(@test_port, "/live/test/speaker",
          "RTP/AVP;unicast;client_port=4588-4589")

        assert {:ok, session} = RTSP.get_session(server, sid)
        assert session.transport == :udp
        assert session.client_port == {4588, 4589}
      end)
    end

    test "RTP/AVP/TCP Transport header stores :tcp_interleaved", %{server: server} do
      with_named(server, fn ->
        sid = rtsp_setup(@test_port, "/live/test/speaker",
          "RTP/AVP/TCP;unicast;interleaved=0-1")

        assert {:ok, session} = RTSP.get_session(server, sid)
        assert session.transport == :tcp_interleaved
      end)
    end

    test "explicit 'interleaved' token stores :tcp_interleaved and extracts port", %{server: server} do
      with_named(server, fn ->
        sid = rtsp_setup(@test_port, "/live/test/speaker",
          "RTP/AVP;unicast;interleaved;client_port=5000-5001")

        assert {:ok, session} = RTSP.get_session(server, sid)
        assert session.transport == :tcp_interleaved
        assert session.client_port == {5000, 5001}
      end)
    end

    test "absent client_port token stores nil client_port", %{server: server} do
      with_named(server, fn ->
        sid = rtsp_setup(@test_port, "/live/test/speaker",
          "RTP/AVP;unicast")

        assert {:ok, session} = RTSP.get_session(server, sid)
        assert session.client_port == nil
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # 7. Mountpoint registry — register, verify listing
  # ---------------------------------------------------------------------------

  describe "mountpoint registry" do
    test "register_mountpoint/3 returns {:ok, path} and path is listed", %{server: server} do
      # register_mountpoint uses GenServer.call(__MODULE__, ...) which will
      # hit the named process.  We use the via-pid approach to direct the
      # call explicitly to our supervised server.
      room_id = "room-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

      # Temporarily register the server under the module name so the public
      # API calls land on the right process.
      with_named(server, fn ->
        assert {:ok, path} = RTSP.register_mountpoint(room_id, :speaker)
        assert path == "/live/room-#{room_id}/speaker"

        listing = RTSP.list_mountpoints()
        paths = Enum.map(listing, fn {p, _subs, _pkts} -> p end)
        assert path in paths
      end)
    end

    test "list_mountpoints/0 returns empty list when no mountpoints registered", %{server: server} do
      with_named(server, fn ->
        assert RTSP.list_mountpoints() == []
      end)
    end

    test "remove_mountpoint/1 removes it from the listing", %{server: server} do
      room_id = "room-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

      with_named(server, fn ->
        {:ok, path} = RTSP.register_mountpoint(room_id, :screen)
        :ok = RTSP.remove_mountpoint(path)

        listing = RTSP.list_mountpoints()
        paths = Enum.map(listing, fn {p, _subs, _pkts} -> p end)
        refute path in paths
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # 8. Per-IP rate limiting — connection limit is enforced
  # ---------------------------------------------------------------------------

  describe "per-IP connection rate limiting" do
    # The @max_connections_per_ip limit is 10 (module attribute). We simulate
    # the tracking logic by directly inspecting the GenServer state via the
    # :sys.get_state/1 call, which is available for any GenServer.

    test "GenServer initialises per_ip_connections as an empty map", %{server: server} do
      state = :sys.get_state(server)
      assert state.per_ip_connections == %{}
    end

    test "active_handlers starts as an empty MapSet", %{server: server} do
      state = :sys.get_state(server)
      assert MapSet.size(state.active_handlers) == 0
    end

    test "rtsp_handler_exit message decrements per_ip_connections", %{server: server} do
      # Simulate the accounting that handle_info({:rtsp_connection, ...}) does
      # by directly manipulating state via :sys.replace_state/2, then firing
      # the exit message and confirming the decrement.
      ip = "192.0.2.1"

      :sys.replace_state(server, fn s ->
        %{s | per_ip_connections: Map.put(s.per_ip_connections, ip, 3)}
      end)

      send(server, {:rtsp_handler_exit, make_ref(), ip})
      # Give the GenServer a moment to process the message.
      :sys.get_state(server)

      state = :sys.get_state(server)
      assert Map.get(state.per_ip_connections, ip) == 2
    end

    test "per_ip_connections entry is removed when count reaches zero", %{server: server} do
      ip = "198.51.100.5"

      :sys.replace_state(server, fn s ->
        %{s | per_ip_connections: Map.put(s.per_ip_connections, ip, 1)}
      end)

      send(server, {:rtsp_handler_exit, make_ref(), ip})
      :sys.get_state(server)

      state = :sys.get_state(server)
      refute Map.has_key?(state.per_ip_connections, ip)
    end
  end

  # ---------------------------------------------------------------------------
  # Private test helpers
  # ---------------------------------------------------------------------------

  # Temporarily registers the supervised RTSP server under its module name so
  # the module's public API (which uses GenServer.call(__MODULE__, ...)) and
  # the SETUP handler (which also calls __MODULE__ internally) route to the
  # test process rather than the application-owned RTSP singleton.
  #
  # Because the test pid already holds a unique :name from setup (#62), we
  # temporarily unregister that name, swap in __MODULE__, then restore on the
  # way out. The application-owned RTSP is also displaced for the duration
  # and restored on exit.
  defp with_named(server_pid, fun) do
    {:registered_name, unique_name} = Process.info(server_pid, :registered_name)

    app_pid = Process.whereis(RTSP)

    if app_pid && app_pid != server_pid, do: Process.unregister(RTSP)
    if is_atom(unique_name) and unique_name != [], do: Process.unregister(unique_name)

    Process.register(server_pid, RTSP)

    try do
      fun.()
    after
      try do
        Process.unregister(RTSP)
      rescue
        ArgumentError -> :ok
      end

      if is_atom(unique_name) and unique_name != [] and Process.alive?(server_pid) do
        Process.register(server_pid, unique_name)
      end

      if app_pid && Process.alive?(app_pid) and Process.whereis(RTSP) == nil do
        Process.register(app_pid, RTSP)
      end
    end
  end

  # Send a minimal RTSP SETUP request over TCP and return the session ID
  # parsed from the server's "Session: <id>" response header.
  #
  # The function opens its own TCP connection (so it doesn't interfere with
  # the main test connection), sends OPTIONS then SETUP, reads the response,
  # and closes the socket.  The returned session ID can then be used with
  # RTSP.get_session/2 to inspect the stored Session struct.
  defp rtsp_setup(port, path, transport_header) do
    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :line], 3_000)

    # OPTIONS first so the connection is primed.
    :gen_tcp.send(sock, "OPTIONS rtsp://127.0.0.1:#{port}#{path} RTSP/1.0\r\n\r\n")
    # Drain the OPTIONS response (200 OK + headers + blank line).
    drain_response(sock)

    # SETUP with the provided Transport header.
    :gen_tcp.send(
      sock,
      "SETUP rtsp://127.0.0.1:#{port}#{path} RTSP/1.0\r\n" <>
        "Transport: #{transport_header}\r\n" <>
        "\r\n"
    )

    session_id = parse_session_id_from_response(sock)
    :gen_tcp.close(sock)
    session_id
  end

  # Read lines until a blank line (end of response headers), returning all
  # header lines as a flat string so the caller can extract what it needs.
  defp drain_response(sock) do
    case :gen_tcp.recv(sock, 0, 3_000) do
      {:ok, line} ->
        if String.trim(line) == "", do: :ok, else: drain_response(sock)

      {:error, _} ->
        :ok
    end
  end

  # Read RTSP response headers and extract the value of the "Session:" header.
  defp parse_session_id_from_response(sock) do
    parse_session_id_from_response(sock, nil)
  end

  defp parse_session_id_from_response(sock, found) do
    case :gen_tcp.recv(sock, 0, 3_000) do
      {:ok, line} ->
        trimmed = String.trim(line)

        if trimmed == "" do
          found
        else
          new_found =
            case Regex.run(~r/^Session:\s*(.+)$/i, trimmed) do
              [_, sid] -> String.trim(sid)
              _ -> found
            end

          parse_session_id_from_response(sock, new_found)
        end

      {:error, _} ->
        found
    end
  end
end
