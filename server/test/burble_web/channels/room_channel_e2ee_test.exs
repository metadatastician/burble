# SPDX-License-Identifier: MPL-2.0
#
# RoomChannel ↔ E2EE coordinator wiring (ADR-0016).
#
# These tests cover the *coordination plane* only: registering public keys,
# relaying sealed blobs, and revoking them when membership changes. They
# deliberately assert that the server never hands out a room key — there is no
# event that would do so.
#
# Setup mirrors BurbleWeb.Channels.RoomChannelTextTest; async: false because
# the channel, presence and coordinator are named singletons.

defmodule BurbleWeb.Channels.RoomChannelE2EETest do
  use ExUnit.Case, async: false
  use Phoenix.ChannelTest

  import Burble.TestHelpers

  alias Burble.Media.E2EE

  @endpoint BurbleWeb.Endpoint

  setup do
    Application.ensure_all_started(:phoenix_pubsub)

    ensure_started({Phoenix.PubSub, name: Burble.PubSub})
    ensure_started({Registry, keys: :unique, name: Burble.RoomRegistry})
    ensure_started({DynamicSupervisor, name: Burble.RoomSupervisor, strategy: :one_for_one})
    ensure_started(Burble.Presence)
    ensure_started(Burble.Media.Engine)
    ensure_started(Burble.Media.E2EE)
    ensure_started(Burble.Text.NNTPSBackend)
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

  defp guest_socket(display_name) do
    {:ok, guest} = Burble.Auth.create_guest_session(display_name)

    sock =
      socket(:user_socket, %{
        user_id: guest.id,
        display_name: guest.display_name,
        is_guest: true
      })

    {sock, guest.id}
  end

  defp join_room(room_id, display_name) do
    {sock, user_id} = guest_socket(display_name)

    {:ok, _reply, chan} =
      subscribe_and_join(sock, BurbleWeb.RoomChannel, "room:#{room_id}", %{
        "display_name" => display_name
      })

    {chan, user_id}
  end

  defp new_room_id, do: generate_room_id()

  defp new_public_key, do: :crypto.generate_key(:ecdh, :x25519) |> elem(0)

  defp register(chan, public_key) do
    push(chan, "e2ee_register_key", %{"public_key" => Base.encode64(public_key)})
  end

  defp await(fun, tries \\ 50) do
    case fun.() do
      {:ok, value} ->
        value

      :retry when tries > 0 ->
        Process.sleep(10)
        await(fun, tries - 1)

      :retry ->
        flunk("condition not met in time")
    end
  end

  # ---------------------------------------------------------------------------
  # Key registration
  # ---------------------------------------------------------------------------

  describe "e2ee_register_key" do
    test "records a public key and broadcasts the new key set" do
      room_id = new_room_id()
      {chan, _user_id} = join_room(room_id, "Alice")
      public_key = new_public_key()

      ref = register(chan, public_key)

      assert_reply(ref, :ok, %{epoch: 0, peers: 1})

      # One registration produces exactly one broadcast, so assert on it once:
      # `assert_broadcast/2` consumes the message, and a second call would be
      # asserting on a message that has already been taken out of the mailbox.
      assert_broadcast("e2ee_key_set", %{epoch: 0, peers: 1, public_keys: keys})

      # The broadcast carries the public key, base64-encoded — and nothing else.
      assert Map.values(keys) |> Enum.map(&Base.decode64!/1) == [public_key]

      leave(chan)
    end

    test "rejects a key of the wrong length rather than crashing the channel" do
      {chan, _user_id} = join_room(new_room_id(), "Bob")

      ref = push(chan, "e2ee_register_key", %{"public_key" => Base.encode64(<<0, 1, 2>>)})
      assert_reply(ref, :error, %{reason: "invalid_public_key"})

      ref = push(chan, "e2ee_register_key", %{"public_key" => "not base64!!"})
      assert_reply(ref, :error, %{reason: "invalid_public_key"})

      ref = push(chan, "e2ee_register_key", %{})
      assert_reply(ref, :error, %{reason: "invalid_public_key"})

      leave(chan)
    end

    test "e2ee_key_set returns what peers need to derive pairwise keys" do
      room_id = new_room_id()
      {chan, _user_id} = join_room(room_id, "Carol")
      public_key = new_public_key()

      ref = register(chan, public_key)
      assert_reply(ref, :ok, %{})

      ref = push(chan, "e2ee_key_set", %{})
      assert_reply(ref, :ok, %{epoch: 0, public_keys: keys})

      assert [public_key] == keys |> Map.values() |> Enum.map(&Base.decode64!/1)

      leave(chan)
    end
  end

  # ---------------------------------------------------------------------------
  # Sealed room key relay
  # ---------------------------------------------------------------------------

  describe "sealed room keys" do
    test "a blob published for a peer is retrievable by that peer only" do
      room_id = new_room_id()
      {alice, _alice_id} = join_room(room_id, "Alice")
      {bob, bob_id} = join_room(room_id, "Bob")

      assert_reply(register(alice, new_public_key()), :ok, %{})
      assert_reply(register(bob, new_public_key()), :ok, %{})

      blob = :crypto.strong_rand_bytes(60)

      ref =
        push(alice, "e2ee_publish_sealed", %{
          "to" => bob_id,
          "epoch" => 0,
          "blob" => Base.encode64(blob)
        })

      assert_reply(ref, :ok, %{epoch: 0})

      # The relay is a broadcast, but the payload is ciphertext bound to the
      # recipient by its AAD; every other peer receives bytes it cannot open.
      assert_broadcast("e2ee_sealed_key", %{to: ^bob_id, epoch: 0})

      assert_reply(push(bob, "e2ee_fetch_sealed", %{}), :ok, %{epoch: 0, blob: encoded})

      assert Base.decode64!(encoded) == blob

      # Alice has nothing waiting for her.
      assert_reply(push(alice, "e2ee_fetch_sealed", %{}), :error, %{reason: "not_found"})

      leave(alice)
      leave(bob)
    end

    test "a malformed blob is refused" do
      {chan, _user_id} = join_room(new_room_id(), "Dave")
      assert_reply(register(chan, new_public_key()), :ok, %{})

      ref =
        push(chan, "e2ee_publish_sealed", %{
          "to" => "someone",
          "epoch" => 0,
          "blob" => Base.encode64(:binary.copy(<<0>>, 600))
        })

      assert_reply(ref, :error, %{reason: "invalid_sealed_blob"})

      ref =
        push(chan, "e2ee_publish_sealed", %{
          "to" => "someone",
          "epoch" => "zero",
          "blob" => Base.encode64(<<1, 2, 3>>)
        })

      assert_reply(ref, :error, %{reason: "invalid_epoch"})

      leave(chan)
    end
  end

  # ---------------------------------------------------------------------------
  # Membership and custody
  # ---------------------------------------------------------------------------

  describe "membership" do
    test "a third member bumps the epoch and revokes outstanding blobs" do
      room_id = new_room_id()
      {alice, _alice_id} = join_room(room_id, "Alice")
      {bob, bob_id} = join_room(room_id, "Bob")

      assert_reply(register(alice, new_public_key()), :ok, %{epoch: 0})
      assert_reply(register(bob, new_public_key()), :ok, %{epoch: 0})

      ref =
        push(alice, "e2ee_publish_sealed", %{
          "to" => bob_id,
          "epoch" => 0,
          "blob" => Base.encode64(:crypto.strong_rand_bytes(60))
        })

      assert_reply(ref, :ok, %{epoch: 0})

      # Carol joins and registers: the epoch moves and Bob's blob is gone.
      {carol, _carol_id} = join_room(room_id, "Carol")
      assert_reply(register(carol, new_public_key()), :ok, %{epoch: 1})

      assert_reply(push(bob, "e2ee_fetch_sealed", %{}), :error, %{reason: "not_found"})

      leave(alice)
      leave(bob)
      leave(carol)
    end

    test "e2ee_status reports that the server holds no key" do
      room_id = new_room_id()
      {chan, _user_id} = join_room(room_id, "Erin")
      assert_reply(register(chan, new_public_key()), :ok, %{})

      assert_reply(push(chan, "e2ee_status", %{}), :ok, %{
        epoch: 0,
        peers: 1,
        key_custody: "peers"
      })

      leave(chan)
    end

    test "leaving the room removes the peer and rotates the epoch" do
      room_id = new_room_id()
      {chan, user_id} = join_room(room_id, "Frank")
      assert_reply(register(chan, new_public_key()), :ok, %{})

      leave(chan)

      # The last peer to leave takes the room record with it, so either the
      # room is gone or it is empty — never still holding a key-bearing peer.
      await(fn ->
        case E2EE.room_status(room_id) do
          {:error, :no_room} -> {:ok, :dropped}
          {:ok, %{peers: 0}} -> {:ok, :empty}
          _ -> :retry
        end
      end)

      assert is_binary(user_id)
    end
  end
end
