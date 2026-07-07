# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
# Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# Failure-mode tests for BurbleWeb.SignalingChannel.
#
# Companion to signaling_channel_test.exs — that file covers the happy
# paths; this one covers realtime-path failure modes flagged in #106
# concern 4 (no chaos / failure-injection coverage on the signaling
# channel).
#
# Each test asserts the signaling channel either degrades gracefully
# or fails loudly in a way the caller can recover from. None of these
# scenarios should crash the channel or take down the room.

defmodule BurbleWeb.Channels.SignalingFailureModesTest do
  use ExUnit.Case, async: false
  use Phoenix.ChannelTest

  @endpoint BurbleWeb.Endpoint

  setup do
    Application.ensure_all_started(:phoenix_pubsub)

    case start_supervised({Phoenix.PubSub, name: Burble.PubSub}) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      # start_supervised wraps the child-start error: {:error, {reason, child_spec}}
      {:error, {{:already_started, _}, _}} -> :ok
    end

    case BurbleWeb.Endpoint.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    user_id = "user-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    room_id = "room-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

    socket =
      socket(:user_socket, %{user_id: user_id, display_name: "Tester", is_guest: false})

    {:ok, user_id: user_id, room_id: room_id, socket: socket}
  end

  defp join_signaling(socket, room_id) do
    subscribe_and_join(socket, BurbleWeb.SignalingChannel, "signaling:#{room_id}", %{})
  end

  # ---------------------------------------------------------------------------
  # Group 1: malformed payload — must not crash the channel process
  # ---------------------------------------------------------------------------

  describe "malformed payload" do
    test "unknown event returns error tuple, channel stays alive",
         %{socket: socket, room_id: room_id} do
      {:ok, _reply, chan} = join_signaling(socket, room_id)

      ref = push(chan, "definitely-not-a-real-event", %{"to" => "peer-x"})
      assert_reply ref, :error, %{reason: "unknown_event"}

      # The channel must still respond to ping after handling the unknown event.
      ref2 = push(chan, "ping", %{})
      assert_reply ref2, :ok, %{pong: true}

      leave(chan)
    end

    test "ping with extra junk fields still pongs",
         %{socket: socket, room_id: room_id} do
      {:ok, _reply, chan} = join_signaling(socket, room_id)

      ref = push(chan, "ping", %{"unexpected" => "stuff", "nested" => %{"deep" => 1}})
      assert_reply ref, :ok, %{pong: true}

      leave(chan)
    end
  end

  # ---------------------------------------------------------------------------
  # Group 2: peer-drop mid-handshake — routing to a peer with no subscriber
  # ---------------------------------------------------------------------------

  describe "peer-drop mid-handshake" do
    test "sdp:offer to a non-subscribed peer does not raise",
         %{socket: socket, room_id: room_id} do
      {:ok, _reply, chan} = join_signaling(socket, room_id)

      orphan_peer = "user-orphan-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

      # Sending to a peer that no socket process subscribes to must be a no-op.
      # The channel uses Phoenix.PubSub.broadcast which drops messages with
      # no subscribers; we assert by verifying the channel survives and can
      # still process subsequent pings.
      push(chan, "sdp:offer", %{"to" => orphan_peer, "sdp" => "v=0\r\n"})

      ref = push(chan, "ping", %{})
      assert_reply ref, :ok, %{pong: true}

      leave(chan)
    end

    test "ice:candidate to a non-subscribed peer does not raise",
         %{socket: socket, room_id: room_id} do
      {:ok, _reply, chan} = join_signaling(socket, room_id)

      orphan_peer = "user-orphan-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      push(chan, "ice:candidate", %{"to" => orphan_peer, "candidate" => "candidate:1 1 UDP"})

      ref = push(chan, "ping", %{})
      assert_reply ref, :ok, %{pong: true}

      leave(chan)
    end
  end

  # ---------------------------------------------------------------------------
  # Group 3: client-side leave/rejoin — channel must clean up cleanly
  # ---------------------------------------------------------------------------

  describe "client leave/rejoin" do
    test "leave + immediate rejoin succeeds",
         %{socket: socket, room_id: room_id} do
      {:ok, _reply, chan1} = join_signaling(socket, room_id)
      leave(chan1)

      {:ok, _reply, chan2} = join_signaling(socket, room_id)
      ref = push(chan2, "ping", %{})
      assert_reply ref, :ok, %{pong: true}

      leave(chan2)
    end
  end

  # ---------------------------------------------------------------------------
  # Group 4: presence broadcast after leave — no stale messages
  # ---------------------------------------------------------------------------

  describe "presence after leave" do
    test "presence:leave triggers broadcast even after explicit leave",
         %{socket: socket, room_id: room_id, user_id: user_id} do
      {:ok, _reply, chan} = join_signaling(socket, room_id)

      push(chan, "presence:leave", %{})
      assert_broadcast "presence:leave", %{user_id: ^user_id}

      leave(chan)
    end
  end
end
