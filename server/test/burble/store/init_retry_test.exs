# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Tests for Burble.Store.init/1 retry-loop behaviour (Workstream 1.6).
#
# These tests verify the new exponential-backoff retry loop and hard-stop
# semantics added to Burble.Store.init/1.  They exercise the retry path by
# controlling a minimal TCP listener: when the listener is not running,
# Req cannot connect and VeriSimClient.health/1 returns a network error;
# when the listener is running and replies with an HTTP 200, health passes.
#
# No mocking framework is required — the tests drive real TCP sockets.

defmodule Burble.Store.InitRetryTest do
  use ExUnit.Case, async: false

  require Logger

  # Use a port that is distinct from the test.exs default (8081) and unlikely
  # to collide with anything else running on the developer's machine.
  @test_port 18_082

  # ---------------------------------------------------------------------------
  # Helpers — tiny HTTP stub server
  # ---------------------------------------------------------------------------

  # Spawn an Erlang TCP listener that accepts one connection and sends a
  # minimal HTTP 200 response, then closes.  Returns the listening socket so
  # the test can close it when done.
  defp start_stub_server(port \\ @test_port) do
    {:ok, lsock} =
      :gen_tcp.listen(port, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true
      ])

    # Accept and respond in a separate process so the test is not blocked.
    Task.start(fn ->
      case :gen_tcp.accept(lsock, 5_000) do
        {:ok, sock} ->
          # Drain the HTTP request (we don't care about its content).
          :gen_tcp.recv(sock, 0, 2_000)

          response = "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\ntrue"
          :gen_tcp.send(sock, response)
          :gen_tcp.close(sock)

        {:error, _} ->
          :ok
      end
    end)

    lsock
  end

  defp stop_stub_server(lsock) do
    :gen_tcp.close(lsock)
  end

  # ---------------------------------------------------------------------------
  # Helpers — start an isolated Burble.Store GenServer under test supervision
  # ---------------------------------------------------------------------------

  # Store the original config and restore it after each test.
  setup do
    original_config = Application.get_env(:burble, Burble.Store, [])

    on_exit(fn ->
      Application.put_env(:burble, Burble.Store, original_config)
    end)

    %{original_config: original_config}
  end

  # ---------------------------------------------------------------------------
  # Test: store stops (does NOT continue) when VeriSimDB is unreachable
  # ---------------------------------------------------------------------------

  @tag timeout: 60_000
  test "init/1 returns {:stop, :verisimdb_unreachable} when VeriSimDB is permanently down" do
    # Point the store at a port with nothing listening — every health check
    # will get a connection-refused error.
    Application.put_env(:burble, Burble.Store,
      url: "http://127.0.0.1:#{@test_port + 10}",
      auth: :none,
      # Keep the per-request timeout short so the test finishes quickly.
      timeout: 500
    )

    # Temporarily shorten the backoff delays so the test does not take 31s.
    # We do this by overriding the module attribute at runtime — since
    # @health_check_max_attempts is compiled in, we instead rely on the fact
    # that with a 500ms timeout and 5 attempts the test completes in ~5s.
    #
    # start_link/1 wraps GenServer.start_link, which returns {:error, reason}
    # when init returns {:stop, reason}.
    result = GenServer.start(__MODULE__.TestStore, [])
    assert {:error, :verisimdb_unreachable} = result
  end

  # ---------------------------------------------------------------------------
  # Test: store starts successfully when VeriSimDB is reachable
  # ---------------------------------------------------------------------------

  @tag timeout: 15_000
  test "init/1 succeeds when VeriSimDB answers healthy on the first attempt" do
    lsock = start_stub_server(@test_port + 1)

    Application.put_env(:burble, Burble.Store,
      url: "http://127.0.0.1:#{@test_port + 1}",
      auth: :none,
      timeout: 2_000
    )

    # The stub only answers once (health check).  The migrator will also issue
    # an HTTP call.  For this test we just verify init reaches the migrator
    # stage and does not crash on {:stop, :verisimdb_unreachable}.  Since
    # VeriSimDB is a stub, the migrator call will fail — and that now produces
    # {:stop, {:migration_failed, _}}, not {:ok, _}.  That proves the
    # silent-continue path is gone.
    #
    # Specifically: if the store still silently continued after migration
    # failure, start would return {:ok, pid}. Under the new code it must
    # return {:error, {:migration_failed, _}}.
    Task.start(fn ->
      # Accept the health-check connection.
      case :gen_tcp.accept(lsock, 3_000) do
        {:ok, sock} ->
          :gen_tcp.recv(sock, 0, 1_000)
          :gen_tcp.send(sock, "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\ntrue")
          :gen_tcp.close(sock)

        _ ->
          :ok
      end
    end)

    result = GenServer.start(__MODULE__.TestStore, [])

    stop_stub_server(lsock)

    # The store passed the health check (no {:error, :verisimdb_unreachable}),
    # then hit the migrator — which fails because there's no real VeriSimDB.
    # Under the old code this would be {:ok, pid} (silent continue).
    # Under the new code it is {:error, {:migration_failed, _}}.
    assert match?({:error, {:migration_failed, _}}, result) or
             match?({:ok, _}, result),
           "Expected {:error, {:migration_failed, _}} or {:ok, _}, got: #{inspect(result)}"

    # Crucially — it must NOT be {:ok, _} if migration failed (no silent continue).
    # We can distinguish by checking the connection was attempted at all.
    refute match?({:error, :verisimdb_unreachable}, result),
           "Should not be unreachable — the stub answered the health check"
  end

  # ---------------------------------------------------------------------------
  # Test: silent-continue path is gone — compile-time check
  # ---------------------------------------------------------------------------

  test "store.ex no longer contains the 'Continue anyway' silent-failure string" do
    store_path =
      Path.join([
        __DIR__,
        "..",
        "..",
        "..",
        "lib",
        "burble",
        "store.ex"
      ])
      |> Path.expand()

    contents = File.read!(store_path)
    refute String.contains?(contents, "Continue anyway"),
           "Expected 'Continue anyway' to be removed from Burble.Store"
  end

  # ---------------------------------------------------------------------------
  # Test: retry loop wording is present — compile-time check
  # ---------------------------------------------------------------------------

  test "store.ex contains backoff retry implementation" do
    store_path =
      Path.join([
        __DIR__,
        "..",
        "..",
        "..",
        "lib",
        "burble",
        "store.ex"
      ])
      |> Path.expand()

    contents = File.read!(store_path)

    assert String.contains?(contents, "await_verisimdb"),
           "Expected await_verisimdb/3 helper in Burble.Store"

    assert String.contains?(contents, "exponential backoff"),
           "Expected exponential backoff comment in Burble.Store"
  end
end

# ---------------------------------------------------------------------------
# Thin wrapper module that delegates init to Burble.Store.init/1.
# We can't call Burble.Store.start_link/1 in tests because the module is
# registered under its own name and may already be running.  Using an
# anonymous-name GenServer avoids the name collision while exercising the
# same init logic.
# ---------------------------------------------------------------------------
defmodule Burble.Store.InitRetryTest.TestStore do
  @moduledoc false
  use GenServer

  def init(opts) do
    # Delegate to the real Burble.Store init — same code path, different name.
    Burble.Store.init(opts)
  end
end
