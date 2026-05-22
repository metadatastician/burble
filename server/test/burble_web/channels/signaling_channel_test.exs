# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Tests for BurbleWeb.SignalingChannel — the dedicated WebRTC signaling
# channel added in Phase 3.
#
# The channel handles peer-to-peer signaling (SDP offer/answer, ICE
# candidates) independently of the room voice channel.
#
# Test strategy:
#   - Join via a pre-authenticated socket (user_id already assigned) so we
#     don't need a real Guardian JWT in unit tests.
#   - Verify each incoming event dispatches correctly.
#   - Verify PubSub routing delivers messages to the target peer.
#   - Verify Phoenix.Token verification on join when no socket auth is present.
#
# All tests run async: false because they share the named PubSub process.

defmodule BurbleWeb.Channels.SignalingChannelTest do
  use ExUnit.Case, async: false
  use Phoenix.ChannelTest

  @endpoint BurbleWeb.Endpoint

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    Application.ensure_all_started(:phoenix_pubsub)

    # Start PubSub if not already running.
    case start_supervised({Phoenix.PubSub, name: Burble.PubSub}) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    # Start the Endpoint if not already running.
    case BurbleWeb.Endpoint.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    user_id = "user-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    peer_id = "user-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    room_id = "room-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

    # Build a pre-authenticated socket (mimics transport-level auth via
    # BurbleWeb.UserSocket) so channel tests don't require a real JWT.
    socket = socket(:user_socket, %{user_id: user_id, display_name: "Tester", is_guest: false})

    {:ok, user_id: user_id, peer_id: peer_id, room_id: room_id, socket: socket}
  end

  # ---------------------------------------------------------------------------
  # Helper: join the signaling channel for a given room
  # ---------------------------------------------------------------------------

  defp join_signaling(socket, room_id) do
    subscribe_and_join(socket, BurbleWeb.SignalingChannel, "signaling:#{room_id}", %{})
  end

  # ---------------------------------------------------------------------------
  # 1. Join succeeds for a pre-authenticated socket
  # ---------------------------------------------------------------------------

  describe "join/3" do
    test "succeeds when user_id is already on the socket", %{socket: socket, room_id: room_id} do
      assert {:ok, _reply, chan} = join_signaling(socket, room_id)
      leave(chan)
    end

    test "assigns room_id to the socket after join", %{socket: socket, room_id: room_id} do
      {:ok, _reply, chan} = join_signaling(socket, room_id)
      assert chan.assigns.room_id == room_id
      leave(chan)
    end

    test "join fails when neither socket user_id nor token is present" do
      unauthenticated = socket(:user_socket, %{})
      room_id = "room-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(
                 unauthenticated,
                 BurbleWeb.SignalingChannel,
                 "signaling:#{room_id}",
                 %{}
               )
    end

    test "join succeeds with a valid Phoenix.Token when socket has no user_id" do
      unauthenticated = socket(:user_socket, %{})
      room_id = "room-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      user_id = "token-user-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

      token = Phoenix.Token.sign(BurbleWeb.Endpoint, "signaling_channel", user_id)

      assert {:ok, _reply, chan} =
               subscribe_and_join(
                 unauthenticated,
                 BurbleWeb.SignalingChannel,
                 "signaling:#{room_id}",
                 %{"token" => token}
               )

      assert chan.assigns.user_id == user_id
      leave(chan)
    end

    test "join fails with an expired Phoenix.Token" do
      unauthenticated = socket(:user_socket, %{})
      room_id = "room-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      user_id = "old-user"

      # Sign the token with max_age 0 — it should be expired immediately.
      # We manipulate the signed_at to be in the past by using a fake system time.
      expired_token =
        Phoenix.Token.sign(
          BurbleWeb.Endpoint,
          "signaling_channel",
          user_id,
          signed_at: System.system_time(:second) - 90_000
        )

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(
                 unauthenticated,
                 BurbleWeb.SignalingChannel,
                 "signaling:#{room_id}",
                 %{"token" => expired_token}
               )
    end
  end

  # ---------------------------------------------------------------------------
  # 2. ping — synchronous health check
  # ---------------------------------------------------------------------------

  describe "ping" do
    test "replies with pong: true", %{socket: socket, room_id: room_id} do
      {:ok, _reply, chan} = join_signaling(socket, room_id)

      ref = push(chan, "ping", %{})
      assert_reply ref, :ok, %{"pong" => true}

      leave(chan)
    end
  end

  # ---------------------------------------------------------------------------
  # 3. sdp:offer — routed to target peer via PubSub
  # ---------------------------------------------------------------------------

  describe "sdp:offer" do
    test "delivers {:signaling_msg, payload} to the target peer's PubSub topic",
         %{socket: socket, room_id: room_id, user_id: user_id, peer_id: peer_id} do
      # Subscribe the test process to the target peer's PubSub topic so we
      # can assert that the channel publishes to the right topic.
      Phoenix.PubSub.subscribe(Burble.PubSub, "signaling_peer:#{peer_id}")

      {:ok, _reply, chan} = join_signaling(socket, room_id)

      sdp = "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\n"
      push(chan, "sdp:offer", %{"to" => peer_id, "sdp" => sdp})

      assert_receive {:signaling_msg, %{type: "sdp:offer", from: ^user_id, sdp: ^sdp}}, 500

      leave(chan)
    end

    test "does not reply to the sender (noreply)", %{socket: socket, room_id: room_id} do
      {:ok, _reply, chan} = join_signaling(socket, room_id)

      ref = push(chan, "sdp:offer", %{"to" => "some-peer", "sdp" => "v=0"})
      refute_reply ref, :ok, %{}, 200

      leave(chan)
    end
  end

  # ---------------------------------------------------------------------------
  # 4. sdp:answer — routed to target peer via PubSub
  # ---------------------------------------------------------------------------

  describe "sdp:answer" do
    test "delivers {:signaling_msg, payload} to the target peer",
         %{socket: socket, room_id: room_id, user_id: user_id, peer_id: peer_id} do
      Phoenix.PubSub.subscribe(Burble.PubSub, "signaling_peer:#{peer_id}")

      {:ok, _reply, chan} = join_signaling(socket, room_id)

      sdp = "v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\n"
      push(chan, "sdp:answer", %{"to" => peer_id, "sdp" => sdp})

      assert_receive {:signaling_msg, %{type: "sdp:answer", from: ^user_id, sdp: ^sdp}}, 500

      leave(chan)
    end
  end

  # ---------------------------------------------------------------------------
  # 5. ice:candidate — routed to target peer via PubSub
  # ---------------------------------------------------------------------------

  describe "ice:candidate" do
    test "delivers {:signaling_msg, payload} with candidate to the target peer",
         %{socket: socket, room_id: room_id, user_id: user_id, peer_id: peer_id} do
      Phoenix.PubSub.subscribe(Burble.PubSub, "signaling_peer:#{peer_id}")

      {:ok, _reply, chan} = join_signaling(socket, room_id)

      candidate = %{"candidate" => "candidate:0 1 UDP 2122252543 192.168.1.1 54321 typ host"}
      push(chan, "ice:candidate", %{"to" => peer_id, "candidate" => candidate})

      assert_receive {:signaling_msg,
                      %{type: "ice:candidate", from: ^user_id, candidate: ^candidate}},
                     500

      leave(chan)
    end
  end

  # ---------------------------------------------------------------------------
  # 6. presence:join — broadcast to all channel subscribers
  # ---------------------------------------------------------------------------

  describe "presence:join" do
    test "broadcasts presence:join event with user_id", %{socket: socket, room_id: room_id, user_id: user_id} do
      {:ok, _reply, chan} = join_signaling(socket, room_id)

      push(chan, "presence:join", %{})

      assert_broadcast "presence:join", %{user_id: ^user_id}

      leave(chan)
    end
  end

  # ---------------------------------------------------------------------------
  # 7. presence:leave — broadcast to all channel subscribers
  # ---------------------------------------------------------------------------

  describe "presence:leave" do
    test "broadcasts presence:leave event with user_id", %{socket: socket, room_id: room_id, user_id: user_id} do
      {:ok, _reply, chan} = join_signaling(socket, room_id)

      push(chan, "presence:leave", %{})

      assert_broadcast "presence:leave", %{user_id: ^user_id}

      leave(chan)
    end
  end

  # ---------------------------------------------------------------------------
  # 8. handle_info({:signaling_msg, payload}, socket) — push to client
  # ---------------------------------------------------------------------------

  describe "handle_info :signaling_msg" do
    test "forwards signaling_msg delivered via PubSub to the client as 'msg' push",
         %{socket: socket, room_id: room_id, user_id: user_id} do
      {:ok, _reply, chan} = join_signaling(socket, room_id)

      # Simulate a peer routing a message to this user's PubSub topic.
      payload = %{type: "sdp:offer", from: "remote-peer", sdp: "v=0"}
      Phoenix.PubSub.broadcast!(Burble.PubSub, "signaling_peer:#{user_id}", {:signaling_msg, payload})

      assert_push "msg", ^payload, 500

      leave(chan)
    end
  end

  # ---------------------------------------------------------------------------
  # 9. Unknown events return a structured error
  # ---------------------------------------------------------------------------

  describe "unhandled events" do
    test "returns {:error, reason: unknown_event} for an unrecognised event",
         %{socket: socket, room_id: room_id} do
      {:ok, _reply, chan} = join_signaling(socket, room_id)

      ref = push(chan, "not_a_real_event", %{})
      assert_reply ref, :error, %{reason: "unknown_event"}

      leave(chan)
    end
  end
end
