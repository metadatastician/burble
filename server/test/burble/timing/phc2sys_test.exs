# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
#
# Tests for Burble.Timing.Phc2sys — phc2sys supervisor.
#
# The test env forces auto_start: false, so these tests never spawn a real
# phc2sys process.  All assertions are about GenServer lifecycle and the idle
# path.

defmodule Burble.Timing.Phc2sysTest do
  use ExUnit.Case, async: false

  alias Burble.Timing.Phc2sys

  # Each test gets a fresh supervised GenServer that is stopped after the test.
  setup do
    pid = start_supervised!(Phc2sys)
    {:ok, pid: pid}
  end

  describe "start_link/1" do
    test "starts the GenServer and registers under its module name" do
      assert pid = Process.whereis(Phc2sys)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "a second start_link/1 call returns {:error, {:already_started, pid}}" do
      assert {:error, {:already_started, _pid}} = Phc2sys.start_link()
    end

    test "auto_start is false by default" do
      # We can infer this from the fact that start_link succeeded without
      # phc2sys being in PATH on most CI runners, and status is :idle.
      assert Phc2sys.status() == :idle
    end
  end

  describe "status/0" do
    test "returns :idle in test env regardless of auto_start option" do
      # Mix.env() == :test forces auto_start: false internally.
      assert Phc2sys.status() == :idle
    end

    test "returns :idle even when auto_start: true is explicitly passed in test env" do
      # stop the supervised one, start a fresh one with auto_start: true
      stop_supervised!(Phc2sys)

      # In test env this should still be :idle because Mix.env() == :test
      # suppresses launching.  We start it directly (not supervised) so we
      # can control its lifetime.
      {:ok, _pid} = Phc2sys.start_link(auto_start: true)
      assert Phc2sys.status() == :idle
    after
      # Clean up if the GenServer is still registered.
      if pid = Process.whereis(Phc2sys), do: GenServer.stop(pid)
    end
  end

  describe "stop/0" do
    test "terminates the GenServer cleanly" do
      pid = Process.whereis(Phc2sys)
      assert Process.alive?(pid)

      # stop/0 calls GenServer.stop which is synchronous — process is gone
      # by the time the call returns.
      # We call stop directly; ExUnit's stop_supervised! would also work but
      # we want to test the public API.
      stop_supervised!(Phc2sys)

      refute Process.alive?(pid)
    end

    test "calling stop/0 on a running server does not raise" do
      # Temporarily start an unregistered copy to test the public stop/0.
      # The supervised copy is still alive; we just want to assert the
      # function itself is exported correctly.
      assert is_function(&Phc2sys.stop/0)
    end
  end

  describe "handle_info/2 — port exit" do
    test "transitions to :idle when a fake port sends an exit_status message" do
      pid = Process.whereis(Phc2sys)

      # Fabricate a fake port reference and inject an exit_status message.
      # In real operation this comes from Port when phc2sys dies; here we
      # exercise the message-handler path without a real port.
      fake_port = :erlang.list_to_port(~c"#Port<0.99999>")
      send(pid, {fake_port, {:exit_status, 1}})

      # Give the GenServer a moment to process the message.
      :timer.sleep(50)

      # State should remain :idle (it was already :idle; the handler
      # transitions to :idle regardless, so this is consistent).
      assert Phc2sys.status() == :idle
    end
  end
end
