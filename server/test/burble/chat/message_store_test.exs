# SPDX-License-Identifier: PMPL-1.0-or-later
#
# Tests for Burble.Chat.MessageStore — in-memory ETS-backed message store.
#
# Covers:
#   - Basic store and retrieve
#   - Message cap (501st message evicts the oldest)
#   - clear_room removes all messages for a room
#   - get_messages respects the limit parameter
#   - Isolation between rooms

defmodule Burble.Chat.MessageStoreTest do
  use ExUnit.Case, async: false

  alias Burble.Chat.MessageStore

  # Shared-app strategy (burble#62): the application owns MessageStore.
  # Every test uses a unique random room id (room_id/0) so ETS state
  # cannot bleed between tests without restarting the process.
  setup do
    :ok
  end

  # ── Helper ──

  defp make_msg(n) do
    %{
      id: "msg-#{n}",
      from: "user-1",
      body: "Message number #{n}",
      timestamp: DateTime.utc_now()
    }
  end

  defp room_id, do: "test-room-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

  # ── Store and retrieve ──

  describe "store_message / get_messages" do
    test "stores a message and retrieves it" do
      rid = room_id()
      msg = make_msg(1)

      :ok = MessageStore.store_message(rid, msg)

      [retrieved] = MessageStore.get_messages(rid)
      assert retrieved.id == "msg-1"
      assert retrieved.body == "Message number 1"
    end

    test "returns an empty list for a room with no messages" do
      assert MessageStore.get_messages(room_id()) == []
    end

    test "messages are returned newest first" do
      rid = room_id()

      MessageStore.store_message(rid, make_msg(1))
      MessageStore.store_message(rid, make_msg(2))
      MessageStore.store_message(rid, make_msg(3))

      [first | _] = MessageStore.get_messages(rid)
      assert first.id == "msg-3", "expected newest message first"
    end

    test "multiple messages can be stored and retrieved" do
      rid = room_id()
      for n <- 1..10, do: MessageStore.store_message(rid, make_msg(n))

      messages = MessageStore.get_messages(rid)
      assert length(messages) == 10
    end
  end

  # ── Limit ──

  describe "get_messages limit" do
    test "get_messages respects the limit parameter" do
      rid = room_id()
      for n <- 1..20, do: MessageStore.store_message(rid, make_msg(n))

      messages = MessageStore.get_messages(rid, 5)
      assert length(messages) == 5
    end

    test "limit larger than store size returns all messages" do
      rid = room_id()
      for n <- 1..3, do: MessageStore.store_message(rid, make_msg(n))

      messages = MessageStore.get_messages(rid, 100)
      assert length(messages) == 3
    end

    test "default limit is 50" do
      rid = room_id()
      for n <- 1..60, do: MessageStore.store_message(rid, make_msg(n))

      messages = MessageStore.get_messages(rid)
      assert length(messages) == 50
    end
  end

  # ── Message cap ──

  describe "message cap" do
    test "501st message evicts the oldest" do
      rid = room_id()

      # Store 500 messages (the cap).
      for n <- 1..500, do: MessageStore.store_message(rid, make_msg(n))

      messages_at_cap = MessageStore.get_messages(rid, 500)
      assert length(messages_at_cap) == 500

      # The oldest message (msg-1) should still be present.
      ids = Enum.map(messages_at_cap, & &1.id)
      assert "msg-1" in ids, "msg-1 should still be present before cap is exceeded"

      # Store the 501st message — this evicts msg-1.
      MessageStore.store_message(rid, make_msg(501))

      messages_after = MessageStore.get_messages(rid, 500)
      assert length(messages_after) == 500

      ids_after = Enum.map(messages_after, & &1.id)
      refute "msg-1" in ids_after, "oldest message (msg-1) must be evicted after cap is exceeded"
      assert "msg-501" in ids_after, "newly inserted message must be present"
    end

    test "cap is enforced at exactly 500 messages" do
      rid = room_id()
      for n <- 1..510, do: MessageStore.store_message(rid, make_msg(n))

      # Even with 510 inserts the store must not exceed 500.
      messages = MessageStore.get_messages(rid, 600)
      assert length(messages) == 500
    end
  end

  # ── clear_room ──

  describe "clear_room" do
    test "clears all messages for the room" do
      rid = room_id()
      for n <- 1..5, do: MessageStore.store_message(rid, make_msg(n))

      :ok = MessageStore.clear_room(rid)

      assert MessageStore.get_messages(rid) == []
    end

    test "clear_room does not affect other rooms" do
      rid_a = room_id()
      rid_b = room_id()

      MessageStore.store_message(rid_a, make_msg(1))
      MessageStore.store_message(rid_b, make_msg(2))

      :ok = MessageStore.clear_room(rid_a)

      assert MessageStore.get_messages(rid_a) == []
      assert length(MessageStore.get_messages(rid_b)) == 1
    end

    test "clear_room on empty room returns :ok without error" do
      assert :ok == MessageStore.clear_room(room_id())
    end
  end

  # ── Room isolation ──

  describe "room isolation" do
    test "messages are scoped to their room" do
      rid_a = room_id()
      rid_b = room_id()

      MessageStore.store_message(rid_a, %{id: "a1", from: "u1", body: "hello from A", timestamp: DateTime.utc_now()})
      MessageStore.store_message(rid_b, %{id: "b1", from: "u2", body: "hello from B", timestamp: DateTime.utc_now()})

      [msg_a] = MessageStore.get_messages(rid_a)
      [msg_b] = MessageStore.get_messages(rid_b)

      assert msg_a.id == "a1"
      assert msg_b.id == "b1"
    end
  end
end
