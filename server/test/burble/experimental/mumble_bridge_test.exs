# SPDX-License-Identifier: MPL-2.0
#
# Tests for Burble.Bridges.Mumble — the EXPERIMENTAL Mumble/Murmur bridge.
#
# Historical note: this file once asserted loadability of four bridges
# (Mumble, SIP, Discord, Matrix). The SIP/Discord/Matrix modules were
# never started by the supervision tree and were deleted in the Phase 0
# truth-reconciliation pass (see git history); Mumble was kept as the
# one bridge whose audience matches Burble's, quarantined as
# experimental. Tests verify:
#   1. The module compiles, is a GenServer, and exports its public API.
#   2. Connect/disconnect lifecycle using a loopback host that always
#      refuses connections (port 1), so no real Murmur server is needed.

defmodule Burble.Bridges.BridgesTest do
  use ExUnit.Case, async: true

  alias Burble.Bridges.Mumble

  # ---------------------------------------------------------------------------
  # 1. Module discovery + API surface
  # ---------------------------------------------------------------------------

  describe "Mumble bridge module" do
    test "is a loadable GenServer with start_link/1" do
      assert Code.ensure_loaded?(Mumble)
      assert function_exported?(Mumble, :start_link, 1)

      behaviours =
        Mumble.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert GenServer in behaviours
    end

    test "exports its public API" do
      # function_exported?/3 does not load the module — ensure it first
      # (test order within this file is randomised).
      assert Code.ensure_loaded?(Mumble)
      assert function_exported?(Mumble, :stop, 1)
      assert function_exported?(Mumble, :status, 1)
      assert function_exported?(Mumble, :mumble_users, 1)
      assert function_exported?(Mumble, :send_text, 3)
      assert function_exported?(Mumble, :relay_to_mumble, 2)
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Mumble bridge — connect/disconnect lifecycle (mocked)
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
end
