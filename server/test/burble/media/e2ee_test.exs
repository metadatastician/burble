# SPDX-License-Identifier: MPL-2.0
#
# The peer-side functions are the protocol; the coordinator is only plumbing.
# These tests exercise both, and they deliberately assert the *absence* of a
# key-returning API (see ADR-0016) — a test that only checked behaviour would
# not notice a `get_frame_key/1` creeping back in.

defmodule Burble.Media.E2EETest do
  use ExUnit.Case, async: false

  alias Burble.Media.E2EE

  # ---------------------------------------------------------------------------
  # Peer-side primitives
  # ---------------------------------------------------------------------------

  describe "generate_keypair/0" do
    test "returns a 32-byte X25519 keypair, different every time" do
      {pub_a, priv_a} = E2EE.generate_keypair()
      {pub_b, priv_b} = E2EE.generate_keypair()

      assert byte_size(pub_a) == 32
      assert byte_size(priv_a) == 32
      assert byte_size(pub_b) == 32
      assert byte_size(priv_b) == 32
      assert pub_a != pub_b
      assert priv_a != priv_b
      assert pub_a != priv_a
    end
  end

  describe "pairwise_key/6" do
    test "both sides derive the same key, and the server is not involved" do
      {alice_pub, alice_priv} = E2EE.generate_keypair()
      {bob_pub, bob_priv} = E2EE.generate_keypair()

      assert {:ok, from_alice} =
               E2EE.pairwise_key(alice_priv, bob_pub, "room-1", 0, "alice", "bob")

      assert {:ok, from_bob} = E2EE.pairwise_key(bob_priv, alice_pub, "room-1", 0, "bob", "alice")

      assert from_alice == from_bob
      assert byte_size(from_alice) == 32
    end

    test "is separated by room and by epoch" do
      {_alice_pub, alice_priv} = E2EE.generate_keypair()
      {bob_pub, _bob_priv} = E2EE.generate_keypair()

      {:ok, k1} = E2EE.pairwise_key(alice_priv, bob_pub, "room-1", 0, "alice", "bob")
      {:ok, k2} = E2EE.pairwise_key(alice_priv, bob_pub, "room-1", 1, "alice", "bob")
      {:ok, k3} = E2EE.pairwise_key(alice_priv, bob_pub, "room-2", 0, "alice", "bob")

      assert k1 != k2
      assert k1 != k3
      assert k2 != k3
    end

    test "a third peer cannot derive the pair's key" do
      {alice_pub, alice_priv} = E2EE.generate_keypair()
      {bob_pub, _bob_priv} = E2EE.generate_keypair()
      {_eve_pub, eve_priv} = E2EE.generate_keypair()

      {:ok, honest} = E2EE.pairwise_key(alice_priv, bob_pub, "room-1", 0, "alice", "bob")

      # Eve knows both public keys but neither private key; her own private
      # key against Alice's public key is a different secret entirely.
      {:ok, eve_attempt} = E2EE.pairwise_key(eve_priv, alice_pub, "room-1", 0, "eve", "alice")

      assert honest != eve_attempt
    end

    test "rejects malformed input instead of raising" do
      {pub, priv} = E2EE.generate_keypair()

      assert {:error, :invalid_private_key} = E2EE.pairwise_key(<<0>>, pub, "r", 0, "a", "b")

      assert {:error, :invalid_public_key} =
               E2EE.pairwise_key(priv, <<0, 1, 2>>, "r", 0, "a", "b")

      assert {:error, :invalid_peer_id} = E2EE.pairwise_key(priv, pub, "r", 0, "", "b")
    end

    test "rejects a low-order (all-zero shared secret) public key" do
      # The canonical low-order point: everything zero. RFC 7748 §6.1 says the
      # shared secret must be rejected, not silently used.
      {_pub, priv} = E2EE.generate_keypair()
      low_order = :binary.copy(<<0>>, 32)

      assert {:error, _reason} = E2EE.pairwise_key(priv, low_order, "r", 0, "a", "b")
    end
  end

  describe "seal_group_key/6 + open_group_key/6" do
    setup do
      {_alice_pub, alice_priv} = E2EE.generate_keypair()
      {bob_pub, _bob_priv} = E2EE.generate_keypair()

      {:ok, pairwise} = E2EE.pairwise_key(alice_priv, bob_pub, "room-1", 3, "alice", "bob")

      %{pairwise: pairwise, room_key: E2EE.random_group_key()}
    end

    test "round-trips the room key for the intended recipient", ctx do
      assert {:ok, sealed} =
               E2EE.seal_group_key(ctx.room_key, ctx.pairwise, "room-1", 3, "alice", "bob")

      assert {:ok, opened} =
               E2EE.open_group_key(sealed, ctx.pairwise, "room-1", 3, "alice", "bob")

      assert opened == ctx.room_key
      assert byte_size(opened) == 32
      assert opened != ctx.pairwise
    end

    test "AAD binds the blob to room, epoch and direction", ctx do
      {:ok, sealed} = E2EE.seal_group_key(ctx.room_key, ctx.pairwise, "room-1", 3, "alice", "bob")

      assert {:error, :open_failed} =
               E2EE.open_group_key(sealed, ctx.pairwise, "room-2", 3, "alice", "bob")

      assert {:error, :open_failed} =
               E2EE.open_group_key(sealed, ctx.pairwise, "room-1", 4, "alice", "bob")

      # Swapping sender and recipient is a different AAD, so it must fail.
      assert {:error, :open_failed} =
               E2EE.open_group_key(sealed, ctx.pairwise, "room-1", 3, "bob", "alice")
    end

    test "a tampered blob does not open", ctx do
      {:ok, {ciphertext, iv, tag}} =
        E2EE.seal_group_key(ctx.room_key, ctx.pairwise, "room-1", 3, "alice", "bob")

      <<first, rest::binary>> = ciphertext
      tampered = <<Bitwise.bxor(first, 0xFF), rest::binary>>

      assert {:error, :open_failed} =
               E2EE.open_group_key({tampered, iv, tag}, ctx.pairwise, "room-1", 3, "alice", "bob")
    end

    test "the wrong key does not open", ctx do
      {:ok, sealed} = E2EE.seal_group_key(ctx.room_key, ctx.pairwise, "room-1", 3, "alice", "bob")

      assert {:error, :open_failed} =
               E2EE.open_group_key(sealed, E2EE.random_group_key(), "room-1", 3, "alice", "bob")
    end

    test "a non-tuple blob is rejected, not crashed on", ctx do
      assert {:error, :malformed_sealed_key} =
               E2EE.open_group_key(<<1, 2, 3>>, ctx.pairwise, "room-1", 3, "alice", "bob")

      assert {:error, :malformed_sealed_key} =
               E2EE.open_group_key(%{}, ctx.pairwise, "room-1", 3, "alice", "bob")
    end
  end

  describe "encode_sealed/1 + decode_sealed/1" do
    test "wire form is iv || tag || ciphertext and round-trips" do
      sealed =
        {:crypto.strong_rand_bytes(32), :crypto.strong_rand_bytes(12),
         :crypto.strong_rand_bytes(16)}

      wire = E2EE.encode_sealed(sealed)
      assert byte_size(wire) == 60
      assert {:ok, ^sealed} = E2EE.decode_sealed(wire)
    end

    test "rejects anything too short to be a sealed key" do
      assert {:error, :malformed_sealed_key} = E2EE.decode_sealed(<<>>)

      # 12 IV + 16 tag with no ciphertext is not a sealed key.
      assert {:error, :malformed_sealed_key} = E2EE.decode_sealed(:binary.copy(<<0>>, 28))
    end
  end

  describe "derive_frame_key/3" do
    test "is deterministic per counter and separated by counter and epoch" do
      room_key = E2EE.random_group_key()

      f0 = E2EE.derive_frame_key(room_key, 0, 0)
      f1 = E2EE.derive_frame_key(room_key, 0, 1)
      e1 = E2EE.derive_frame_key(room_key, 1, 0)

      assert f0 == E2EE.derive_frame_key(room_key, 0, 0)
      assert f0 != f1
      assert f0 != e1
      assert f0 != room_key
      assert byte_size(f0) == 32
    end

    test "refuses a key of the wrong size rather than deriving from it" do
      assert_raise FunctionClauseError, fn ->
        E2EE.derive_frame_key(<<0>>, 0, 0)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Coordinator (server side) — public keys, epochs, opaque blobs only
  # ---------------------------------------------------------------------------

  describe "coordinator" do
    setup do
      room_id = "e2ee-test-#{System.unique_integer([:positive])}"
      assert {:ok, %{epoch: 0}} = E2EE.init_room(room_id)
      on_exit(fn -> E2EE.destroy_room(room_id) end)

      %{room_id: room_id}
    end

    test "reports peer-held custody and never returns key material", %{room_id: room_id} do
      {pub_a, _priv_a} = E2EE.generate_keypair()
      {pub_b, _priv_b} = E2EE.generate_keypair()

      assert {:ok, %{epoch: 0, peer_count: 1}} = E2EE.register_peer_key(room_id, "a", pub_a)
      assert {:ok, %{epoch: 0, peer_count: 2}} = E2EE.register_peer_key(room_id, "b", pub_b)

      assert {:ok, status} = E2EE.room_status(room_id)
      assert status.key_custody == :peers
      assert status.peers == 2
      assert status.epoch == 0

      assert {:ok, key_set} = E2EE.key_set(room_id)
      assert key_set.peers == %{"a" => pub_a, "b" => pub_b}
    end

    test "re-registering the same public key is a no-op", %{room_id: room_id} do
      {pub, _priv} = E2EE.generate_keypair()

      assert {:ok, %{epoch: 0}} = E2EE.register_peer_key(room_id, "a", pub)
      assert {:ok, %{epoch: 0, peer_count: 1}} = E2EE.register_peer_key(room_id, "a", pub)
    end

    test "rejects malformed public keys and oversized peer ids", %{room_id: room_id} do
      assert {:error, :invalid_public_key} = E2EE.register_peer_key(room_id, "a", <<0>>)

      {pub, _priv} = E2EE.generate_keypair()
      long_id = String.duplicate("x", 129)
      assert {:error, :invalid_peer_id} = E2EE.register_peer_key(room_id, long_id, pub)
    end

    test "a sealed blob is retrievable for the current epoch only", %{room_id: room_id} do
      p1 = keypair!()
      p2 = keypair!()

      E2EE.register_peer_key(room_id, "a", p1)
      E2EE.register_peer_key(room_id, "b", p2)

      blob = :crypto.strong_rand_bytes(60)

      assert :ok = E2EE.publish_sealed(room_id, "a", 0, blob)
      assert {:ok, %{epoch: 0, blob: ^blob}} = E2EE.sealed_for(room_id, "a")
      assert {:error, :not_found} = E2EE.sealed_for(room_id, "b")

      # A blob addressed to a peer that is not in the room is refused.
      assert {:error, :invalid_peer_id} = E2EE.publish_sealed(room_id, "", 0, blob)
      assert {:error, :stale_epoch} = E2EE.publish_sealed(room_id, "a", 99, blob)
    end

    test "a new member bumps the epoch and revokes every blob", %{room_id: room_id} do
      p1 = keypair!()
      p2 = keypair!()
      p3 = keypair!()

      E2EE.register_peer_key(room_id, "a", p1)
      E2EE.register_peer_key(room_id, "b", p2)
      assert :ok = E2EE.publish_sealed(room_id, "a", 0, :crypto.strong_rand_bytes(60))

      # Before any blob exists the epoch is stable; once one exists a
      # membership change must invalidate it.
      assert {:ok, %{epoch: 1}} = E2EE.register_peer_key(room_id, "c", p3)
      assert {:error, :not_found} = E2EE.sealed_for(room_id, "a")
    end

    test "removing a peer bumps the epoch", %{room_id: room_id} do
      E2EE.register_peer_key(room_id, "a", keypair!())
      E2EE.register_peer_key(room_id, "b", keypair!())

      assert {:ok, epoch} = E2EE.request_rotation(room_id)
      assert epoch == 1

      assert {:ok, 2} = E2EE.remove_peer(room_id, "b")
      assert {:ok, %{epoch: 2, peers: 1}} = E2EE.room_status(room_id)
    end

    test "the last peer leaving drops the room record entirely", %{room_id: room_id} do
      E2EE.register_peer_key(room_id, "a", keypair!())

      assert {:ok, _epoch} = E2EE.remove_peer(room_id, "a")

      # Not merely empty: gone, so the coordinator's map cannot grow once per
      # room ever joined.
      assert {:error, :no_room} = E2EE.room_status(room_id)
    end

    test "unknown rooms are reported, not crashed on" do
      assert {:error, :no_room} = E2EE.room_status("no-such-room")
      assert {:error, :no_room} = E2EE.request_rotation("no-such-room")
      assert {:error, :no_room} = E2EE.key_set("no-such-room")
      assert {:error, :no_room} = E2EE.sealed_for("no-such-room", "a")
    end

    test "the module exposes no key-returning function" do
      names = Enum.map(E2EE.__info__(:functions), fn {name, _arity} -> name end)

      refute :get_frame_key in names
      refute :ratchet_key in names
      refute :encrypt_frame in names
      refute :decrypt_frame in names
    end
  end

  defp keypair! do
    {pub, _priv} = E2EE.generate_keypair()
    pub
  end
end
