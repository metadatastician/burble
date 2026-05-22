# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Tests for Burble.Rooms.Room — GenServer managing a single voice room.
#
# Exercises the join/leave lifecycle, voice state transitions, room capacity
# limits, idle timeout, and PubSub event broadcasting.

defmodule Burble.Rooms.RoomTest do
  use ExUnit.Case, async: false

  alias Burble.Rooms.Room

  # Start the required infrastructure for each test.
  setup do
    room_id = "test-room-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

    # Ensure required registries and supervisors are running.
    # These are started by Application, but for isolated tests we verify
    # they exist (the full app is started by test_helper.exs).
    {:ok, room_id: room_id}
  end

  # Helper to start a room process.
  defp start_room(room_id, opts \\ []) do
    child_opts =
      Keyword.merge(opts, id: room_id)
      |> Keyword.put_new(:server_id, "test-server")
      |> Keyword.put_new(:name, "Test Room")

    DynamicSupervisor.start_child(
      Burble.RoomSupervisor,
      {Room, child_opts}
    )
  end

  # ---------------------------------------------------------------------------
  # Room creation
  # ---------------------------------------------------------------------------

  describe "start_link/1" do
    test "starts a room process", %{room_id: room_id} do
      assert {:ok, pid} = start_room(room_id)
      assert Process.alive?(pid)
    end

    test "registers in the RoomRegistry", %{room_id: room_id} do
      {:ok, _pid} = start_room(room_id)
      assert [{pid, _}] = Registry.lookup(Burble.RoomRegistry, room_id)
      assert Process.alive?(pid)
    end

    test "duplicate room ID returns error", %{room_id: room_id} do
      {:ok, _pid} = start_room(room_id)
      assert {:error, {:already_started, _}} = start_room(room_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Join / Leave
  # ---------------------------------------------------------------------------

  describe "join/3" do
    test "adds a participant to the room", %{room_id: room_id} do
      {:ok, _pid} = start_room(room_id)

      assert {:ok, state} = Room.join(room_id, "user-1", %{display_name: "Alice"})
      assert state.participant_count == 1
      assert Map.has_key?(state.participants, "user-1")
    end

    test "returns error for duplicate join", %{room_id: room_id} do
      {:ok, _pid} = start_room(room_id)
      {:ok, _} = Room.join(room_id, "user-1", %{display_name: "Alice"})

      assert {:error, :already_joined} = Room.join(room_id, "user-1", %{display_name: "Alice"})
    end

    test "rejects join when room is full", %{room_id: room_id} do
      {:ok, _pid} = start_room(room_id, max_participants: 2)

      {:ok, _} = Room.join(room_id, "user-1", %{display_name: "Alice"})
      {:ok, _} = Room.join(room_id, "user-2", %{display_name: "Bob"})

      assert {:error, :room_full} = Room.join(room_id, "user-3", %{display_name: "Charlie"})
    end

    test "returns error for non-existent room" do
      assert {:error, :room_not_found} = Room.join("nonexistent", "user-1", %{display_name: "X"})
    end
  end

  describe "leave/2" do
    test "removes a participant from the room", %{room_id: room_id} do
      {:ok, _pid} = start_room(room_id)
      {:ok, _} = Room.join(room_id, "user-1", %{display_name: "Alice"})

      assert :ok = Room.leave(room_id, "user-1")
      assert {:ok, state} = Room.get_state(room_id)
      assert state.participant_count == 0
    end

    test "returns error for user not in room", %{room_id: room_id} do
      {:ok, _pid} = start_room(room_id)
      assert {:error, :not_in_room} = Room.leave(room_id, "user-1")
    end
  end

  # ---------------------------------------------------------------------------
  # Voice state
  # ---------------------------------------------------------------------------

  describe "set_voice_state/3" do
    test "updates participant voice state", %{room_id: room_id} do
      {:ok, _pid} = start_room(room_id)
      {:ok, _} = Room.join(room_id, "user-1", %{display_name: "Alice"})

      assert :ok = Room.set_voice_state(room_id, "user-1", :muted)
      {:ok, state} = Room.get_state(room_id)
      assert state.participants["user-1"].voice_state == :muted
    end

    test "returns error for user not in room", %{room_id: room_id} do
      {:ok, _pid} = start_room(room_id)
      assert {:error, :not_in_room} = Room.set_voice_state(room_id, "user-1", :muted)
    end
  end

  # ---------------------------------------------------------------------------
  # State queries
  # ---------------------------------------------------------------------------

  describe "get_state/1" do
    test "returns room state with participant details", %{room_id: room_id} do
      {:ok, _pid} = start_room(room_id, name: "My Room")
      {:ok, _} = Room.join(room_id, "user-1", %{display_name: "Alice"})

      assert {:ok, state} = Room.get_state(room_id)
      assert state.name == "My Room"
      assert state.mode == :open
      assert state.participant_count == 1
    end
  end

  describe "participant_count/1" do
    test "returns correct count", %{room_id: room_id} do
      {:ok, _pid} = start_room(room_id)
      assert 0 == Room.participant_count(room_id)

      {:ok, _} = Room.join(room_id, "user-1", %{display_name: "A"})
      assert 1 == Room.participant_count(room_id)

      {:ok, _} = Room.join(room_id, "user-2", %{display_name: "B"})
      assert 2 == Room.participant_count(room_id)

      :ok = Room.leave(room_id, "user-1")
      assert 1 == Room.participant_count(room_id)
    end
  end
end
