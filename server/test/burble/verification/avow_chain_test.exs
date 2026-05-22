# SPDX-License-Identifier: MPL-2.0
#
# Avow attestation chain property tests.
#
# These tests verify the Avow hash-chain implementation satisfies the
# non-circularity invariant proved in src/Burble/ABI/Avow.idr — that
# attestation chains form a strictly monotonic sequence with no loops.
#
# Property 1: chain_non_circular — no attestation's `previous_attestation`
#   points to itself or to any attestation later in the chain.
# Property 2: chain_verifiable — every chain produced by attest_join/leave
#   passes verify_chain/1.
# Property 3: hash_integrity — tampering with any field in an attestation
#   causes verify_attestation to fail.

defmodule Burble.Verification.AvowChainTest do
  use ExUnit.Case, async: false

  alias Burble.Verification.Avow

  setup do
    Avow.init_store()
    :ok
  end

  # ── Chain linkage ──────────────────────────────────────────────────

  describe "chain linkage" do
    test "first attestation has nil previous_attestation" do
      {:ok, att} = Avow.attest_join("u1", "r1", :direct_join)
      assert att.previous_attestation == nil
    end

    test "second attestation links to first" do
      {:ok, first} = Avow.attest_join("u2", "r2", :direct_join)
      {:ok, second} = Avow.attest_leave("u2", "r2", :voluntary)

      assert second.previous_attestation == first.id
    end

    test "chain of 10 attestations has strictly ordered linkage" do
      room_id = "chain-test-room"
      user_id = "chain-test-user"

      attestations =
        for i <- 1..10 do
          action = if rem(i, 2) == 1, do: :direct_join, else: :voluntary
          {:ok, att} =
            if action == :direct_join do
              Avow.attest_join(user_id, room_id, :direct_join)
            else
              Avow.attest_leave(user_id, room_id, :voluntary)
            end
          att
        end

      # First has nil previous.
      assert hd(attestations).previous_attestation == nil

      # Each subsequent points to the one before.
      attestations
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [prev, curr] ->
        assert curr.previous_attestation == prev.id,
               "attestation #{curr.id} should link to #{prev.id}"
      end)
    end
  end

  # ── Non-circularity ────────────────────────────────────────────────

  describe "non-circularity property (mirrors Avow.idr proof)" do
    test "no attestation links to itself" do
      {:ok, att} = Avow.attest_join("u3", "r3", :direct_join)
      refute att.previous_attestation == att.id
    end

    test "no attestation links to a later attestation in the chain" do
      room_id = "nocircle-room"
      user_id = "nocircle-user"

      attestations =
        for _ <- 1..5 do
          {:ok, att} = Avow.attest_join(user_id, room_id, :direct_join)
          att
        end

      ids = Enum.map(attestations, & &1.id)

      Enum.with_index(attestations)
      |> Enum.each(fn {att, idx} ->
        later_ids = Enum.drop(ids, idx + 1)

        refute att.previous_attestation in later_ids,
               "attestation at index #{idx} must not link forward"
      end)
    end

    test "stored chain matches verify_chain/1" do
      room_id = "verify-room"
      user_id = "verify-user"

      Avow.attest_join(user_id, room_id, :direct_join)
      Avow.attest_leave(user_id, room_id, :voluntary)
      Avow.attest_join(user_id, room_id, :invite_link, invite_token: "tok123")

      chain = Avow.get_chain(:membership, "room:#{room_id}|user:#{user_id}")
      assert length(chain) == 3

      assert {:ok, _last_id} = Avow.verify_chain(chain)
    end
  end

  # ── Hash integrity ─────────────────────────────────────────────────

  describe "hash integrity" do
    test "verify_attestation passes on untampered attestation" do
      {:ok, att} = Avow.attest_join("u4", "r4", :direct_join)
      assert {:ok, :verified} = Avow.verify_attestation(att)
    end

    test "verify_attestation fails on tampered subject_id" do
      {:ok, att} = Avow.attest_join("u5", "r5", :direct_join)
      tampered = %{att | subject_id: "evil_user"}

      assert {:error, :hash_mismatch} = Avow.verify_attestation(tampered)
    end

    test "verify_attestation fails on tampered action" do
      {:ok, att} = Avow.attest_join("u6", "r6", :direct_join)
      tampered = %{att | action: :room_leave}

      assert {:error, :hash_mismatch} = Avow.verify_attestation(tampered)
    end

    test "verify_chain fails on broken linkage" do
      {:ok, a1} = Avow.attest_join("u7", "r7", :direct_join)
      {:ok, a2} = Avow.attest_leave("u7", "r7", :voluntary)

      # Break the link by inserting a wrong previous_attestation.
      broken = %{a2 | previous_attestation: "wrong_id"}

      assert {:error, :chain_broken, _id} = Avow.verify_chain([a1, broken])
    end
  end
end
