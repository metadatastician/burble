# SPDX-License-Identifier: MPL-2.0
#
# Behavioural tests for Burble.Presence.BleSpa (BLE wire format v1, ADR-0015).
# Byte-level freeze is enforced separately by ble_spa_vectors_test.exs.
#
# async: false — the replay tests exercise the shared :ble_spa_nonces ETS table.

defmodule Burble.Presence.BleSpaTest do
  use ExUnit.Case, async: false

  alias Burble.Presence.BleSpa

  @rs BleSpa.derive_room_secret("room-invite-token")
  @ps :crypto.strong_rand_bytes(32)
  @nowbase 1_800_000_000

  defp fresh_nonce, do: :crypto.strong_rand_bytes(6)

  describe "room secret" do
    test "is 32 deterministic bytes" do
      assert byte_size(@rs) == 32
      assert BleSpa.derive_room_secret("x") == BleSpa.derive_room_secret("x")
      assert BleSpa.derive_room_secret("x") != BleSpa.derive_room_secret("y")
    end
  end

  describe "knock encode/verify" do
    test "round-trips and is exactly 24 bytes" do
      payload = BleSpa.encode_knock(@rs, @nowbase, fresh_nonce())
      assert byte_size(payload) == 24
      assert <<0x42, 0x11, _::binary>> = payload
      assert BleSpa.verify_knock(payload, @rs, @nowbase, check_replay: false) == :ok
    end

    test "wrong secret -> :bad_mac" do
      payload = BleSpa.encode_knock(@rs, @nowbase, fresh_nonce())
      other = BleSpa.derive_room_secret("someone-else")
      assert BleSpa.verify_knock(payload, other, @nowbase, check_replay: false) == {:error, :bad_mac}
    end

    test "each tampered region fails with the right error" do
      p = BleSpa.encode_knock(@rs, @nowbase, fresh_nonce())

      assert BleSpa.verify_knock(binary_part(p, 0, 23), @rs, @nowbase, check_replay: false) ==
               {:error, :bad_length}

      assert BleSpa.verify_knock(set_byte(p, 0, 0x00), @rs, @nowbase, check_replay: false) ==
               {:error, :bad_magic}

      # version nibble -> 2
      assert BleSpa.verify_knock(set_byte(p, 1, 0x21), @rs, @nowbase, check_replay: false) ==
               {:error, :bad_version}

      # frame nibble -> presence
      assert BleSpa.verify_knock(set_byte(p, 1, 0x12), @rs, @nowbase, check_replay: false) ==
               {:error, :bad_frame_type}

      # flip a MAC byte
      assert BleSpa.verify_knock(set_byte(p, 23, xor1(p, 23)), @rs, @nowbase, check_replay: false) ==
               {:error, :bad_mac}
    end

    test "±30s window accepted, ±31s rejected" do
      p = BleSpa.encode_knock(@rs, @nowbase, fresh_nonce())
      assert BleSpa.verify_knock(p, @rs, @nowbase + 30, check_replay: false) == :ok
      assert BleSpa.verify_knock(p, @rs, @nowbase - 30, check_replay: false) == :ok
      assert BleSpa.verify_knock(p, @rs, @nowbase + 31, check_replay: false) == {:error, :stale_timestamp}
      assert BleSpa.verify_knock(p, @rs, @nowbase - 31, check_replay: false) == {:error, :stale_timestamp}
    end

    test "one-shot nonce: replay of the same nonce is rejected" do
      BleSpa.init_replay_table()
      nonce = fresh_nonce()
      p = BleSpa.encode_knock(@rs, @nowbase, nonce)
      assert BleSpa.verify_knock(p, @rs, @nowbase) == :ok
      assert BleSpa.verify_knock(p, @rs, @nowbase) == {:error, :replayed_nonce}
    end
  end

  describe "response" do
    test "match succeeds for the addressed knock and returns the psm" do
      kts = @nowbase
      kn = fresh_nonce()
      resp = BleSpa.encode_response(@rs, kts, kn, kts + 1, 129)
      assert byte_size(resp) == 24
      assert BleSpa.match_response(resp, @rs, kts, kn, kts + 2) == {:ok, 129}
    end

    test "non-holder of the room secret cannot match" do
      kts = @nowbase
      kn = fresh_nonce()
      resp = BleSpa.encode_response(@rs, kts, kn, kts + 1, 0)
      other = BleSpa.derive_room_secret("outsider")
      assert BleSpa.match_response(resp, other, kts, kn, kts + 2) == {:error, :bad_token}
    end

    test "wrong knock identity cannot match" do
      kts = @nowbase
      resp = BleSpa.encode_response(@rs, kts, fresh_nonce(), kts + 1, 0)
      assert BleSpa.match_response(resp, @rs, kts, fresh_nonce(), kts + 2) == {:error, :bad_token}
    end
  end

  describe "presence beacon" do
    test "resolves only for the holding contact" do
      ep = BleSpa.epoch(@nowbase)
      beacon = BleSpa.encode_presence(@ps, ep)
      assert byte_size(beacon) == 24
      other = :crypto.strong_rand_bytes(32)

      assert BleSpa.resolve_presence(beacon, [{"alice", @ps}], @nowbase) == {:ok, "alice"}
      assert BleSpa.resolve_presence(beacon, [{"bob", other}], @nowbase) == :unknown
      assert BleSpa.resolve_presence(beacon, [{"bob", other}, {"alice", @ps}], @nowbase) == {:ok, "alice"}
    end

    test "epoch rotation changes the beacon id" do
      ep = BleSpa.epoch(@nowbase)
      assert BleSpa.beacon_id(@ps, ep) != BleSpa.beacon_id(@ps, ep + 1)
    end

    test "resolves within ±1 epoch, not beyond" do
      ep = BleSpa.epoch(@nowbase)
      beacon = BleSpa.encode_presence(@ps, ep)
      # now one epoch later still resolves (clock skew tolerance)
      assert BleSpa.resolve_presence(beacon, [{"alice", @ps}], @nowbase + 900) == {:ok, "alice"}
      # two epochs later does not
      assert BleSpa.resolve_presence(beacon, [{"alice", @ps}], @nowbase + 1800) == :unknown
    end
  end

  # ── helpers ──

  defp set_byte(bin, i, b),
    do: binary_part(bin, 0, i) <> <<b>> <> binary_part(bin, i + 1, byte_size(bin) - i - 1)

  defp xor1(bin, i), do: Bitwise.bxor(:binary.at(bin, i), 0x01)
end
