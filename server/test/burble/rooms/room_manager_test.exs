# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Tests for Burble.Rooms.RoomManager — room process lifecycle manager.
#
# Verifies ensure_room, start_room, join, and active room listing.

defmodule Burble.Rooms.RoomManagerTest do
  use ExUnit.Case, async: false

  alias Burble.Rooms.RoomManager

  # ---------------------------------------------------------------------------
  # Room creation and lookup
  # ---------------------------------------------------------------------------

  describe "ensure_room/2" do
    test "creates a new room when none exists" do
      room_id = "mgr-test-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      assert {:ok, pid} = RoomManager.ensure_room(room_id)
      assert Process.alive?(pid)
    end

    test "returns existing room when already started" do
      room_id = "mgr-test-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      {:ok, pid1} = RoomManager.ensure_room(room_id)
      {:ok, pid2} = RoomManager.ensure_room(room_id)
      assert pid1 == pid2
    end
  end

  describe "start_room/2" do
    test "starts a room under RoomSupervisor" do
      room_id = "mgr-start-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      assert {:ok, pid} = RoomManager.start_room(room_id)
      assert Process.alive?(pid)
    end
  end

  describe "list_active_rooms/0" do
    test "includes recently created rooms" do
      room_id = "mgr-list-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      {:ok, _pid} = RoomManager.ensure_room(room_id)
      rooms = RoomManager.list_active_rooms()
      assert room_id in rooms
    end
  end

  describe "active_room_count/0" do
    test "reflects the number of active rooms" do
      initial_count = RoomManager.active_room_count()
      room_id = "mgr-count-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      {:ok, _pid} = RoomManager.ensure_room(room_id)
      assert RoomManager.active_room_count() >= initial_count + 1
    end
  end

  # ---------------------------------------------------------------------------
  # Join via RoomManager
  # ---------------------------------------------------------------------------

  describe "join/4" do
    test "creates room on demand and joins" do
      room_id = "mgr-join-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      user_id = "user-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

      assert {:ok, state} = RoomManager.join(room_id, user_id, %{display_name: "Tester"})
      assert state.participant_count == 1
      assert Map.has_key?(state.participants, user_id)
    end
  end
end
