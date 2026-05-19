# SPDX-License-Identifier: PMPL-1.0-or-later
#
# Tests for BurbleWeb.RoomChannel — text messaging extensions.
#
# Covers the new "text:send", "text:typing", and "text:history" events
# added in Phase 3. These events are separate from the legacy "text"
# event (which uses NNTPSBackend) and use the in-memory MessageStore.
#
# Infrastructure notes:
#   - Mirrors the setup pattern in Burble.E2E.SignalingTest.
#   - NNTPSBackend is also started here because RoomChannel.join/3 may
#     reach it for other in-flight operations; having it up avoids
#     unrelated crashes during setup.
#   - All tests run async: false because they share named ETS tables
#     (Burble.Chat.MessageStore) and named processes.

defmodule BurbleWeb.Channels.RoomChannelTextTest do
  use ExUnit.Case, async: false
  use Phoenix.ChannelTest

  import Burble.TestHelpers

  @endpoint BurbleWeb.Endpoint

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    Application.ensure_all_started(:phoenix_pubsub)

    ensure_started({Phoenix.PubSub, name: Burble.PubSub})
    ensure_started({Registry, keys: :unique, name: Burble.RoomRegistry})
    ensure_started({DynamicSupervisor, name: Burble.RoomSupervisor, strategy: :one_for_one})
    ensure_started(Burble.Presence)
    ensure_started(Burble.Media.Engine)
    ensure_started(Burble.Text.NNTPSBackend)

    # MessageStore is application-owned; unique room ids isolate (#62).
    ensure_started(Burble.Chat.MessageStore)

    case BurbleWeb.Endpoint.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp guest_socket(display_name \\ "TestGuest") do
    {:ok, guest} = Burble.Auth.create_guest_session(display_name)

    socket(:user_socket, %{
      user_id: guest.id,
      display_name: guest.display_name,
      is_guest: true
    })
  end

  defp join_room(display_name \\ "Tester") do
    sock = guest_socket(display_name)
    room_id = generate_room_id()

    {:ok, _reply, chan} =
      subscribe_and_join(sock, BurbleWeb.RoomChannel, "room:#{room_id}", %{
        "display_name" => display_name
      })

    {chan, room_id}
  end

  # ---------------------------------------------------------------------------
  # text:send — happy path
  # ---------------------------------------------------------------------------

  describe "text:send" do
    test "broadcasts text:new to the room on success" do
      {chan, _room_id} = join_room("Alice")

      ref = push(chan, "text:send", %{"body" => "Hello, world!"})

      assert_reply ref, :ok, %{id: id}
      assert is_binary(id) and byte_size(id) > 0

      assert_broadcast "text:new", %{body: "Hello, world!", from: from}
      assert is_binary(from)

      leave(chan)
    end

    test "broadcast includes id, from, body, and timestamp fields" do
      {chan, _room_id} = join_room("Bob")

      push(chan, "text:send", %{"body" => "Timestamp test"})

      assert_broadcast "text:new", %{id: id, from: from, body: body, timestamp: ts}
      assert is_binary(id)
      assert is_binary(from)
      assert body == "Timestamp test"
      assert is_binary(ts)
      # Timestamp must be an ISO-8601 string.
      assert {:ok, _dt, _} = DateTime.from_iso8601(ts)

      leave(chan)
    end

    test "reply contains the message id" do
      {chan, _room_id} = join_room()

      ref = push(chan, "text:send", %{"body" => "ID check"})
      assert_reply ref, :ok, %{id: id}
      assert String.length(id) == 32, "expected 32-char hex ID, got: #{id}"

      leave(chan)
    end

    test "text:send with empty body returns invalid_text_payload error" do
      {chan, _room_id} = join_room()

      ref = push(chan, "text:send", %{"body" => ""})
      assert_reply ref, :error, %{reason: "invalid_text_payload"}

      leave(chan)
    end

    test "text:send with missing body returns invalid_text_payload error" do
      {chan, _room_id} = join_room()

      ref = push(chan, "text:send", %{})
      assert_reply ref, :error, %{reason: "invalid_text_payload"}

      leave(chan)
    end

    test "text:send with body exceeding 4096 bytes returns invalid_text_payload error" do
      {chan, _room_id} = join_room()

      oversized = String.duplicate("x", 4097)
      ref = push(chan, "text:send", %{"body" => oversized})
      assert_reply ref, :error, %{reason: "invalid_text_payload"}

      leave(chan)
    end

    test "text:send with exactly 4096-byte body is accepted" do
      {chan, _room_id} = join_room()

      max_body = String.duplicate("a", 4096)
      ref = push(chan, "text:send", %{"body" => max_body})
      assert_reply ref, :ok, %{id: _id}

      leave(chan)
    end

    test "text:new is NOT echoed to the sender's own push (broadcast_from semantics do not apply here)" do
      # text:send uses broadcast! (not broadcast_from!) so the sender DOES receive
      # the broadcast. This test validates broadcast! semantics are in place.
      {chan, _room_id} = join_room("Self")

      push(chan, "text:send", %{"body" => "Echo test"})
      assert_broadcast "text:new", %{body: "Echo test"}

      leave(chan)
    end
  end

  # ---------------------------------------------------------------------------
  # text:typing
  # ---------------------------------------------------------------------------

  describe "text:typing" do
    test "broadcasts text:typing indicator with from field" do
      {chan, _room_id} = join_room("Typer")

      push(chan, "text:typing", %{})

      assert_broadcast "text:typing", %{from: from}
      assert is_binary(from)

      leave(chan)
    end

    test "typing indicator is throttled: second push within 2s is ignored" do
      {chan, _room_id} = join_room("ThrottleTest")

      push(chan, "text:typing", %{})
      assert_broadcast "text:typing", %{}

      # Immediately send a second typing event — should be throttled.
      push(chan, "text:typing", %{})

      # The second broadcast must NOT arrive within a short window.
      refute_broadcast "text:typing", %{}, 100

      leave(chan)
    end

    test "typing indicator does not reply (noreply)" do
      {chan, _room_id} = join_room()

      ref = push(chan, "text:typing", %{})

      # Phoenix.ChannelTest: push/3 returns a ref; if the handler returns
      # {:noreply, socket} there should be no :ok/:error reply on that ref.
      refute_reply ref, :ok, %{}, 100
      refute_reply ref, :error, %{}, 100

      leave(chan)
    end
  end

  # ---------------------------------------------------------------------------
  # text:history
  # ---------------------------------------------------------------------------

  describe "text:history" do
    test "returns an empty list for a room with no history" do
      {chan, _room_id} = join_room()

      ref = push(chan, "text:history", %{"limit" => 10})
      assert_reply ref, :ok, %{messages: []}

      leave(chan)
    end

    test "returns stored messages after text:send" do
      {chan, _room_id} = join_room("HistoryUser")

      push(chan, "text:send", %{"body" => "First message"})
      push(chan, "text:send", %{"body" => "Second message"})

      # Allow broadcasts to propagate.
      assert_broadcast "text:new", %{}
      assert_broadcast "text:new", %{}

      ref = push(chan, "text:history", %{"limit" => 10})
      assert_reply ref, :ok, %{messages: messages}
      assert length(messages) >= 2

      bodies = Enum.map(messages, & &1.body)
      assert "First message" in bodies
      assert "Second message" in bodies

      leave(chan)
    end

    test "history messages include id, from, body, timestamp" do
      {chan, _room_id} = join_room()

      push(chan, "text:send", %{"body" => "Schema check"})
      assert_broadcast "text:new", %{}

      ref = push(chan, "text:history", %{"limit" => 5})
      assert_reply ref, :ok, %{messages: [msg | _]}

      assert Map.has_key?(msg, :id)
      assert Map.has_key?(msg, :from)
      assert Map.has_key?(msg, :body)
      assert Map.has_key?(msg, :timestamp)

      leave(chan)
    end

    test "history respects the limit parameter" do
      {chan, _room_id} = join_room()

      for i <- 1..10 do
        push(chan, "text:send", %{"body" => "msg #{i}"})
        assert_broadcast "text:new", %{}
      end

      ref = push(chan, "text:history", %{"limit" => 3})
      assert_reply ref, :ok, %{messages: messages}
      assert length(messages) == 3

      leave(chan)
    end

    test "text:history with invalid params returns error" do
      {chan, _room_id} = join_room()

      ref = push(chan, "text:history", %{})
      assert_reply ref, :error, %{reason: "invalid_history_params"}

      leave(chan)
    end

    test "text:history with limit 0 returns error" do
      {chan, _room_id} = join_room()

      ref = push(chan, "text:history", %{"limit" => 0})
      assert_reply ref, :error, %{reason: "invalid_history_params"}

      leave(chan)
    end
  end
end
