# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# session_concurrency_test.exs — Concurrent session handling and supervision
# tree recovery tests.
#
# Validates that:
#   - Multiple rooms can be created and torn down in parallel
#   - Room processes survive isolated crashes without affecting peers
#   - Supervision tree removes crashed rooms from the registry
#   - Race-free participant counting under concurrent join/leave storms
#   - No cross-room information leakage when rooms run in parallel
#
# These tests start the exact named registries and supervisors that
# Burble.Rooms.Room expects (Burble.RoomRegistry and Burble.RoomSupervisor)
# so they work under `mix test --no-start` without the full OTP application.
#
# `async: false` — tests share BEAM process tables and named registries.

defmodule Burble.Concurrency.SessionConcurrencyTest do
  use ExUnit.Case, async: false

  alias Burble.Rooms.{Room, RoomManager}
  import Burble.TestHelpers

  # ---------------------------------------------------------------------------
  # Per-suite infrastructure setup
  # ---------------------------------------------------------------------------
  # Start the two named processes that Room/RoomManager require.  Using
  # `start_supervised!` ensures they are torn down after each test case.

  setup do
    # The phoenix_pubsub application must be started so its :pg scope exists.
    Application.ensure_all_started(:phoenix_pubsub)

    # Use start_supervised! so ExUnit owns the lifecycle and restarts these
    # processes between tests, giving each test a clean slate.
    ensure_started({Phoenix.PubSub, name: Burble.PubSub})
    ensure_started({Registry, keys: :unique, name: Burble.RoomRegistry})
    ensure_started({DynamicSupervisor, name: Burble.RoomSupervisor, strategy: :one_for_one})

    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp start_room(room_id, opts \\ []) do
    child_opts =
      Keyword.merge(opts, id: room_id)
      |> Keyword.put_new(:server_id, "test-server")
      |> Keyword.put_new(:name, "Room #{room_id}")

    DynamicSupervisor.start_child(Burble.RoomSupervisor, {Room, child_opts})
  end

  # ---------------------------------------------------------------------------
  # Test 1: Parallel room creation — 20 independent rooms concurrently
  # ---------------------------------------------------------------------------

  describe "parallel session creation" do
    test "20 rooms can be created concurrently without conflict" do
      room_ids = Enum.map(1..20, fn _ -> generate_room_id() end)

      results =
        room_ids
        |> Task.async_stream(
          fn room_id -> start_room(room_id) end,
          max_concurrency: 10,
          timeout: 10_000
        )
        |> Enum.to_list()

      alive_count =
        Enum.count(results, fn
          {:ok, {:ok, pid}} -> Process.alive?(pid)
          _ -> false
        end)

      assert alive_count == 20,
             "all 20 rooms must start successfully, got #{alive_count}"
    end

    test "each room is registered in RoomRegistry uniquely" do
      room_ids = Enum.map(1..10, fn _ -> generate_room_id() end)

      Enum.each(room_ids, fn room_id ->
        {:ok, _pid} = start_room(room_id)
      end)

      registered_ids =
        Registry.select(Burble.RoomRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])

      assert Enum.all?(room_ids, &(&1 in registered_ids)),
             "every created room must appear in RoomRegistry"
    end
  end

  # ---------------------------------------------------------------------------
  # Test 2: RoomManager concurrent ensure_room de-duplication
  # ---------------------------------------------------------------------------

  describe "RoomManager concurrency" do
    test "concurrent ensure_room calls for the same room_id produce one process" do
      room_id = generate_room_id()

      # Race 10 Tasks all trying to ensure_room simultaneously.
      pids =
        1..10
        |> Task.async_stream(
          fn _ -> RoomManager.ensure_room(room_id) end,
          max_concurrency: 10,
          timeout: 5_000
        )
        |> Enum.flat_map(fn
          {:ok, {:ok, pid}} -> [pid]
          _ -> []
        end)

      unique_pids = Enum.uniq(pids)

      assert length(unique_pids) == 1,
             "concurrent ensure_room for same ID must converge on one PID, got #{inspect(unique_pids)}"
    end

    test "concurrent ensure_room for distinct rooms produces distinct processes" do
      room_ids = Enum.map(1..8, fn _ -> generate_room_id() end)

      pids =
        room_ids
        |> Task.async_stream(
          fn room_id -> RoomManager.ensure_room(room_id) end,
          max_concurrency: 8,
          timeout: 5_000
        )
        |> Enum.map(fn {:ok, {:ok, pid}} -> pid end)

      assert length(Enum.uniq(pids)) == length(room_ids),
             "each room must have a distinct PID"
    end
  end

  # ---------------------------------------------------------------------------
  # Test 3: Supervision tree crash recovery
  # ---------------------------------------------------------------------------
  # Note: Room uses `restart: :transient`.  Under OTP's :transient policy,
  # the DynamicSupervisor restarts child processes on abnormal exits
  # (including :kill).  The registry is updated to point at the new PID.
  # "Recovery" here means the room remains accessible after a crash, not
  # that it stays dead.

  describe "supervision tree restart recovery" do
    test "a killed room process is replaced by a new process in the registry" do
      room_id = generate_room_id()
      {:ok, pid1} = start_room(room_id)
      assert Process.alive?(pid1)

      # Force-kill the room process (abnormal exit triggers :transient restart).
      Process.exit(pid1, :kill)

      # Allow supervisor to restart the process.
      Process.sleep(150)

      # The original PID must be dead.
      assert not Process.alive?(pid1),
             "killed process must be dead"

      # A new PID must be registered for the same room_id (supervisor restarted it).
      [{pid2, _}] = Registry.lookup(Burble.RoomRegistry, room_id)
      assert pid2 != pid1, "new PID must be different from the killed PID"
      assert Process.alive?(pid2), "restarted process must be alive"
    end

    test "sibling rooms survive when one room process crashes" do
      room_a = generate_room_id()
      room_b = generate_room_id()

      {:ok, pid_a} = start_room(room_a)
      {:ok, pid_b} = start_room(room_b)

      assert Process.alive?(pid_a)
      assert Process.alive?(pid_b)

      # Crash room A — DynamicSupervisor isolates children.
      Process.exit(pid_a, :kill)
      Process.sleep(50)

      # Room B must still be alive (DynamicSupervisor per-child isolation).
      assert Process.alive?(pid_b),
             "sibling room must survive a peer crash"
    end

    test "room is accessible via Registry after supervisor restarts it" do
      room_id = generate_room_id()
      {:ok, pid1} = start_room(room_id)

      Process.exit(pid1, :kill)
      Process.sleep(150)

      # Room must still be reachable via the Registry.
      assert [{_new_pid, _}] = Registry.lookup(Burble.RoomRegistry, room_id),
             "room must be re-registered after supervisor restart"
    end

    test "active_room_count stays the same after crash + restart" do
      room_id = generate_room_id()
      # Before: count a baseline after creating one new room.
      {:ok, pid} = start_room(room_id)
      count_after_create = RoomManager.active_room_count()

      # Kill and wait for restart.
      Process.exit(pid, :kill)
      Process.sleep(150)

      # Count must be the same — supervisor restarted the room.
      assert RoomManager.active_room_count() == count_after_create,
             "active_room_count must stay the same after crash+restart"
    end
  end

  # ---------------------------------------------------------------------------
  # Test 4: Concurrent join/leave storms — participant count invariant
  # ---------------------------------------------------------------------------

  describe "concurrent participant operations" do
    test "participant count is correct after parallel joins" do
      room_id = generate_room_id()
      {:ok, _pid} = start_room(room_id)

      n = 12
      user_ids =
        1..n
        |> Task.async_stream(
          fn _ ->
            user_id = generate_user_id()
            {:ok, _} = Room.join(room_id, user_id, %{display_name: "U"})
            user_id
          end,
          max_concurrency: n,
          timeout: 5_000
        )
        |> Enum.map(fn {:ok, uid} -> uid end)

      assert Room.participant_count(room_id) == n,
             "participant count must equal #{n} successful joins"

      # Leave all — count must return to zero.
      Enum.each(user_ids, fn uid -> Room.leave(room_id, uid) end)

      assert Room.participant_count(room_id) == 0,
             "participant count must be 0 after all leaves"
    end

    test "participant count never goes negative during a concurrent leave storm" do
      room_id = generate_room_id()
      {:ok, _pid} = start_room(room_id)

      # Join 10 users sequentially for a known initial state.
      user_ids =
        Enum.map(1..10, fn _ ->
          user_id = generate_user_id()
          {:ok, _} = Room.join(room_id, user_id, %{display_name: "U"})
          user_id
        end)

      # Leave all concurrently — include phantom IDs to test robustness.
      phantom_ids = Enum.map(1..5, fn _ -> generate_user_id() end)
      all_ids = user_ids ++ phantom_ids

      all_ids
      |> Task.async_stream(
        fn uid -> Room.leave(room_id, uid) end,
        max_concurrency: 15,
        timeout: 5_000
      )
      |> Enum.to_list()

      count = Room.participant_count(room_id)

      assert count >= 0,
             "participant count must never be negative, got #{count}"
    end
  end

  # ---------------------------------------------------------------------------
  # Test 5: Cross-room isolation — no state leakage
  # ---------------------------------------------------------------------------

  describe "cross-room isolation" do
    test "joining room A does not affect participant count in room B" do
      room_a = generate_room_id()
      room_b = generate_room_id()

      {:ok, _} = start_room(room_a)
      {:ok, _} = start_room(room_b)

      Enum.each(1..5, fn _ ->
        user_id = generate_user_id()
        Room.join(room_a, user_id, %{display_name: "A"})
      end)

      assert Room.participant_count(room_b) == 0,
             "room B must be unaffected by joins to room A"

      assert Room.participant_count(room_a) == 5,
             "room A must show 5 participants"
    end

    test "voice state change in room A does not affect room B participants" do
      room_a = generate_room_id()
      room_b = generate_room_id()

      {:ok, _} = start_room(room_a)
      {:ok, _} = start_room(room_b)

      user_a = generate_user_id()
      user_b = generate_user_id()

      {:ok, _} = Room.join(room_a, user_a, %{display_name: "InA"})
      {:ok, _} = Room.join(room_b, user_b, %{display_name: "InB"})

      :ok = Room.set_voice_state(room_a, user_a, :muted)

      {:ok, state_b} = Room.get_state(room_b)
      participant_b = Map.get(state_b.participants, user_b)

      assert participant_b.voice_state == :connected,
             "voice state in room B must not be modified by room A changes"
    end
  end

  # ---------------------------------------------------------------------------
  # Test 6: list_active_rooms/0 under concurrent load
  # ---------------------------------------------------------------------------

  describe "RoomManager.list_active_rooms/0 under load" do
    test "all newly created rooms appear in list_active_rooms" do
      initial_count = RoomManager.active_room_count()
      new_ids = Enum.map(1..10, fn _ -> generate_room_id() end)

      Enum.each(new_ids, fn id -> start_room(id) end)

      listed = RoomManager.list_active_rooms()

      assert Enum.all?(new_ids, &(&1 in listed)),
             "all newly created rooms must appear in list_active_rooms"

      assert RoomManager.active_room_count() >= initial_count + 10
    end
  end
end
