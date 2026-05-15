# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Tests for Burble.Store.Migrator — verifies the three critical behaviours:
#
#   (a) Fresh-DB path: mock VeriSimClient returns not_found for the version
#       search AND not_found (transiently) then ok for the create → migration
#       proceeds and returns :ok.
#
#   (b) Already-applied path: search finds the tracking octad already present
#       → migration is skipped (idempotent), returns :ok.
#
#   (c) Genuine-error preservation: mock returns 500 from the create call →
#       migrator propagates {:migration_failed, 1, reason} (loud-fail preserved).
#
# These tests drive real TCP sockets and a locally-started Finch instance.
# Finch is started per-test (anonymous name) to avoid the global Req.Finch
# registry which requires the full application to be running.
#
# Run with: mix test test/burble/store/migrator_test.exs --no-start

defmodule Burble.Store.MigratorTest do
  use ExUnit.Case, async: false

  require Logger

  # ---------------------------------------------------------------------------
  # Setup: start Finch for each test so Req can make HTTP requests without the
  # full Burble application running.  Using a unique name avoids registry
  # collisions when tests run concurrently.
  # ---------------------------------------------------------------------------

  setup do
    # Derive a unique Finch instance name per test process.
    finch_name = Module.concat(__MODULE__, "Finch#{System.unique_integer([:positive])}")
    start_supervised!({Finch, name: finch_name})

    # Patch Req to use our named Finch instance instead of the global Req.Finch.
    # Req 0.5.x respects the `:finch` option on `Req.new/1`.
    # VeriSimClient uses `Req.new/1` without specifying `:finch`, so it defaults
    # to `Req.Finch` (which isn't started).  We work around this by monkeypatching
    # the process dictionary to override the finch_name for VeriSimClient — but
    # VeriSimClient does not support that.
    #
    # Instead we start the globally-named Req.Finch if not already running.
    # This is safe in --no-start mode because no other process is using it.
    if Process.whereis(Req.Finch) == nil do
      start_supervised!({Finch, name: Req.Finch})
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # (a) Fresh-DB path — migration v1 proceeds and returns :ok
  # ---------------------------------------------------------------------------

  describe "Burble.Store.Migrations.InitialSetup.up/1 — fresh DB" do
    test "returns :ok when search finds no tracking octad and create succeeds" do
      migration_mod = load_migration()

      lsock = start_tcp_stub([
        # already_applied? search: empty list (no tracking octad)
        http_200_json("[]"),
        # do_create attempt 1: 200 OK
        http_200_json("{\"id\":\"abc\",\"name\":\"_migration:burble\"}")
      ])

      {:ok, client} = client_for(lsock)
      result = migration_mod.up(client)
      stop_tcp_stub(lsock)

      assert result == :ok, "Expected :ok for fresh-DB create, got: #{inspect(result)}"
    end

    test "returns :ok when create first returns 404 (fresh-DB transient) then succeeds on retry" do
      migration_mod = load_migration()

      lsock = start_tcp_stub([
        # already_applied? search: empty list
        http_200_json("[]"),
        # do_create attempt 1: 404 (VeriSimDB write endpoint not yet initialised)
        "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n",
        # do_create attempt 2: 200 OK
        http_200_json("{\"id\":\"abc\",\"name\":\"_migration:burble\"}")
      ])

      {:ok, client} = client_for(lsock)
      # Override the retry delay to 0ms for this test by calling do_create via up/1.
      # The module attribute @create_retry_delay_ms = 1_000 means the retry will
      # sleep 1s.  Accept the delay — the test is tagged with a reasonable timeout.
      result = migration_mod.up(client)
      stop_tcp_stub(lsock)

      assert result == :ok,
             "Expected :ok after transient 404 retry, got: #{inspect(result)}"
    end
  end

  # ---------------------------------------------------------------------------
  # (b) Already-applied path — idempotent, returns :ok
  # ---------------------------------------------------------------------------

  describe "Burble.Store.Migrations.InitialSetup.up/1 — already applied" do
    test "returns :ok without creating when tracking octad already exists in search" do
      migration_mod = load_migration()

      tracking_octad_json =
        Jason.encode!([%{
          "id" => "existing-id",
          "name" => "_migration:burble",
          "document" => %{
            "content" =>
              Jason.encode!(%{
                "current_version" => 1,
                "applied_at" => "2026-01-01T00:00:00Z",
                "migrations" => []
              })
          }
        }])

      lsock = start_tcp_stub([
        # already_applied? search: returns the existing tracking octad
        http_200_json(tracking_octad_json)
        # No create call expected.
      ])

      {:ok, client} = client_for(lsock)
      result = migration_mod.up(client)
      stop_tcp_stub(lsock)

      assert result == :ok,
             "Expected :ok for idempotent already-applied case, got: #{inspect(result)}"
    end

    test "returns :ok when VeriSimDB returns 409 Conflict on duplicate create" do
      migration_mod = load_migration()

      lsock = start_tcp_stub([
        # already_applied? search: empty (not yet indexed in search)
        http_200_json("[]"),
        # do_create: 409 Conflict (octad already exists in write path)
        "HTTP/1.1 409 Conflict\r\nContent-Length: 0\r\n\r\n"
      ])

      {:ok, client} = client_for(lsock)
      result = migration_mod.up(client)
      stop_tcp_stub(lsock)

      assert result == :ok,
             "Expected :ok for 409-Conflict idempotent case, got: #{inspect(result)}"
    end
  end

  # ---------------------------------------------------------------------------
  # (c) Genuine-error preservation — loud-fail propagates through migrator
  # ---------------------------------------------------------------------------

  describe "Burble.Store.Migrator.run/1 — genuine error propagation" do
    test "up/1 returns {:error, _} when create returns a non-retryable 500 error" do
      migration_mod = load_migration()

      lsock = start_tcp_stub([
        # already_applied? search: empty
        http_200_json("[]"),
        # do_create: 500 Internal Server Error (genuine failure)
        http_500_json("{\"error\":\"storage engine down\"}")
      ])

      {:ok, client} = client_for(lsock)
      result = migration_mod.up(client)
      stop_tcp_stub(lsock)

      assert match?({:error, _}, result),
             "Expected {:error, _} for genuine 500 failure, got: #{inspect(result)}"
      refute result == :ok
    end

    test "Migrator.run/1 returns {:error, {:migration_failed, 1, _}} on genuine create error" do
      lsock = start_tcp_stub([
        # Migrator's get_current_version search: empty list → v0
        http_200_json("[]"),
        # Migration up/1: already_applied? search: empty
        http_200_json("[]"),
        # Migration up/1: do_create: 500 genuine failure
        http_500_json("{\"error\":\"storage crashed\"}")
      ])

      {:ok, client} = client_for(lsock)
      result = Burble.Store.Migrator.run(client)
      stop_tcp_stub(lsock)

      assert match?({:error, {:migration_failed, 1, _}}, result),
             "Expected {:error, {:migration_failed, 1, _}}, got: #{inspect(result)}"
    end
  end

  # ---------------------------------------------------------------------------
  # (d) Exhausted-retries path — not_found persisting beyond retry budget
  # ---------------------------------------------------------------------------

  describe "Burble.Store.Migrations.InitialSetup.up/1 — retries exhausted" do
    # @create_max_attempts = 3, @create_retry_delay_ms = 1_000 → ~2s of sleep.
    @tag timeout: 15_000
    test "returns {:error, {:not_found, _}} when 404 persists beyond retry budget" do
      migration_mod = load_migration()

      lsock = start_tcp_stub([
        # already_applied? search: empty
        http_200_json("[]"),
        # do_create attempt 1: 404
        "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n",
        # do_create attempt 2: 404
        "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n",
        # do_create attempt 3 (last): 404 — budget exhausted
        "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"
      ])

      {:ok, client} = client_for(lsock)
      result = migration_mod.up(client)
      stop_tcp_stub(lsock)

      assert match?({:error, {:not_found, _}}, result),
             "Expected {:error, {:not_found, _}} when retries exhausted, got: #{inspect(result)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers — TCP stub server
  # ---------------------------------------------------------------------------

  # Build a minimal HTTP 200 response with a JSON body.
  defp http_200_json(body) do
    len = byte_size(body)
    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{len}\r\n\r\n#{body}"
  end

  defp http_500_json(body) do
    len = byte_size(body)
    "HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\nContent-Length: #{len}\r\n\r\n#{body}"
  end

  # Build a VeriSimClient pointing at the port of a listening socket.
  defp client_for(lsock) do
    {:ok, port} = :inet.port(lsock)
    VeriSimClient.new("http://127.0.0.1:#{port}", timeout: 5_000)
  end

  # Spawn a TCP listener that accepts connections sequentially and replies with
  # the pre-canned responses in order.  Each connection gets one response.
  defp start_tcp_stub(responses) do
    {:ok, lsock} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    parent = self()

    Task.start(fn ->
      serve_all(lsock, responses, parent)
    end)

    lsock
  end

  defp serve_all(_lsock, [], _parent), do: :ok

  defp serve_all(lsock, [response | rest], parent) do
    case :gen_tcp.accept(lsock, 10_000) do
      {:ok, sock} ->
        # Drain the HTTP request bytes (we don't care about the content).
        drain_request(sock)
        :gen_tcp.send(sock, response)
        :gen_tcp.close(sock)
        serve_all(lsock, rest, parent)

      {:error, :closed} ->
        :ok

      {:error, _} ->
        :ok
    end
  end

  # Drain a raw HTTP request from the socket.
  # We just read until there's nothing left (or timeout) and discard everything.
  defp drain_request(sock) do
    case :gen_tcp.recv(sock, 0, 1_000) do
      {:ok, _data} -> drain_request(sock)
      {:error, :timeout} -> :ok
      {:error, _} -> :ok
    end
  end

  defp stop_tcp_stub(lsock) do
    :gen_tcp.close(lsock)
  end

  # Load and return the migration module.  The .exs file is compiled once;
  # subsequent calls return the already-loaded module.
  defp load_migration do
    unless Code.ensure_loaded?(Burble.Store.Migrations.InitialSetup) do
      path =
        Path.join([
          __DIR__,
          "..",
          "..",
          "..",
          "priv",
          "repo",
          "migrations",
          "001_initial_setup.exs"
        ])
        |> Path.expand()

      Code.compile_file(path)
    end

    Burble.Store.Migrations.InitialSetup
  end
end
