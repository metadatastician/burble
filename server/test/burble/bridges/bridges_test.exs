# SPDX-License-Identifier: MPL-2.0
#
# Tests for Burble.Bridges.* — external voice/chat bridge modules.
#
# Each bridge (Mumble, SIP, Discord, Matrix) is a GenServer that connects
# Burble rooms to third-party voice platforms.  Tests verify:
#   1. Each module compiles, is a GenServer, and exports its public API.
#   2. Mumble bridge: connect/disconnect lifecycle using a loopback host that
#      always refuses connections (port 1), so no real server is needed.
#   3. SIP bridge: module compiles; DNS SRV is noted as not implemented;
#      lifecycle start/stop works with ephemeral RTP port.
#   4. Bridge module discovery: all four bridge modules are loadable.

defmodule Burble.Bridges.BridgesTest do
  use ExUnit.Case, async: true

  alias Burble.Bridges.Discord
  alias Burble.Bridges.Matrix
  alias Burble.Bridges.Mumble
  alias Burble.Bridges.SIP

  # ---------------------------------------------------------------------------
  # 1. Bridge module discovery
  # ---------------------------------------------------------------------------

  describe "available bridge modules" do
    test "all four bridge modules are loadable GenServers with start_link/1" do
      bridges = [Mumble, SIP, Discord, Matrix]

      for mod <- bridges do
        assert Code.ensure_loaded?(mod),
               "#{inspect(mod)} could not be loaded"

        assert function_exported?(mod, :start_link, 1),
               "#{inspect(mod)} is missing start_link/1"

        behaviours =
          mod.__info__(:attributes)
          |> Keyword.get_values(:behaviour)
          |> List.flatten()

        assert GenServer in behaviours,
               "#{inspect(mod)} does not implement the GenServer behaviour"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Module-level API surface assertions
  # ---------------------------------------------------------------------------

  describe "each bridge module exports its public API" do
    test "Mumble bridge API" do
      assert function_exported?(Mumble, :stop, 1)
      assert function_exported?(Mumble, :status, 1)
      assert function_exported?(Mumble, :mumble_users, 1)
      assert function_exported?(Mumble, :send_text, 3)
      assert function_exported?(Mumble, :relay_to_mumble, 2)
    end

    test "SIP bridge API" do
      assert function_exported?(SIP, :stop, 1)
      assert function_exported?(SIP, :status, 1)
      assert function_exported?(SIP, :dial, 2)
      assert function_exported?(SIP, :hangup, 1)
      assert function_exported?(SIP, :relay_to_sip, 2)
      assert function_exported?(SIP, :send_dtmf, 2)
    end

    test "Discord bridge API" do
      assert function_exported?(Discord, :stop, 1)
      assert function_exported?(Discord, :status, 1)
      assert function_exported?(Discord, :discord_users, 1)
      assert function_exported?(Discord, :send_text, 3)
      assert function_exported?(Discord, :relay_to_discord, 2)
    end

    test "Matrix bridge API" do
      assert function_exported?(Matrix, :stop, 1)
      assert function_exported?(Matrix, :status, 1)
      assert function_exported?(Matrix, :matrix_members, 1)
      assert function_exported?(Matrix, :send_text, 3)
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Mumble bridge — connect/disconnect lifecycle (mocked)
  #
  # Port 1 is reserved and always refused by the loopback interface, so the
  # :connect handler fails immediately and schedules a retry.  The bridge
  # process stays alive in a disconnected-but-healthy state.
  # ---------------------------------------------------------------------------

  describe "Mumble bridge lifecycle" do
    setup do
      opts = [
        room_id: "test_mumble_#{System.unique_integer([:positive])}",
        mumble_host: "127.0.0.1",
        mumble_port: 1,     # always refused — no real Murmur server needed
        mumble_channel: "Test",
        bot_name: "TestBot"
      ]

      {:ok, pid} = GenServer.start_link(Mumble, opts)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      %{pid: pid}
    end

    test "GenServer starts, is alive, and reports disconnected status", %{pid: pid} do
      assert Process.alive?(pid)
      # Give the async :connect message time to be processed and fail.
      Process.sleep(50)
      {:ok, status} = Mumble.status(pid)
      assert status.connected == false
    end

    test "status/1 includes all expected fields", %{pid: pid} do
      {:ok, status} = Mumble.status(pid)
      assert Map.has_key?(status, :room_id)
      assert Map.has_key?(status, :mumble_host)
      assert Map.has_key?(status, :mumble_channel)
      assert Map.has_key?(status, :connected)
      assert Map.has_key?(status, :mumble_user_count)
      assert Map.has_key?(status, :bot_name)
    end

    test "mumble_users/1 returns an empty list before connection", %{pid: pid} do
      {:ok, users} = Mumble.mumble_users(pid)
      assert users == []
    end

    test "send_text/3 is a no-op when disconnected and does not crash", %{pid: pid} do
      # With tcp_socket == nil the cast clause silently drops the message.
      assert :ok = Mumble.send_text(pid, "Tester", "hello from test")
      assert Process.alive?(pid)
    end

    test "stop/1 terminates the process cleanly", %{pid: pid} do
      assert :ok = Mumble.stop(pid)
      refute Process.alive?(pid)
    end
  end

  # ---------------------------------------------------------------------------
  # 4. SIP bridge — module compiles; DNS SRV lookup not implemented
  # ---------------------------------------------------------------------------

  describe "SIP bridge lifecycle" do
    setup do
      opts = [
        room_id: "test_sip_#{System.unique_integer([:positive])}",
        sip_host: "127.0.0.1",
        sip_port: 5060,
        sip_user: "test-bridge",
        local_rtp_port: 0       # OS assigns an ephemeral port
      ]

      {:ok, pid} = GenServer.start_link(SIP, opts)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      %{pid: pid}
    end

    test "GenServer starts and initial status shows not registered, no active call", %{pid: pid} do
      assert Process.alive?(pid)
      {:ok, status} = SIP.status(pid)
      assert status.registered == false
      assert status.call == nil
    end

    test "DNS SRV lookup is not implemented — dial/2 does not crash the bridge", %{pid: pid} do
      # The SIP module documents that DNS SRV is not implemented.
      # Dialling when sockets may not yet be open must not raise or kill the
      # GenServer; the result may be :ok (queued) or {:error, _}.
      result = SIP.dial(pid, "sip:test@127.0.0.1")
      assert result in [:ok, {:error, :already_in_call}] or match?({:error, _}, result)
      assert Process.alive?(pid)
    end

    test "stop/1 terminates the process cleanly", %{pid: pid} do
      assert :ok = SIP.stop(pid)
      refute Process.alive?(pid)
    end
  end
end
