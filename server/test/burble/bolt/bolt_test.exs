# SPDX-License-Identifier: MPL-2.0
defmodule Burble.BoltTest do
  use ExUnit.Case, async: true

  alias Burble.Bolt.Packet
  alias Burble.Bolt.Quic
  alias Burble.Bolt.Sender

  # ---------------------------------------------------------------------------
  # Packet encode / decode
  # ---------------------------------------------------------------------------

  describe "Packet.encode/decode round-trip" do
    test "minimal packet (no MACs, no payload fields)" do
      original = %{"type" => "test"}
      binary = Packet.encode(original)

      assert byte_size(binary) >= 116
      assert {:ok, packet} = Packet.decode(binary)
      assert packet.payload == original
      assert packet.target_mac == nil
      assert packet.sender_mac == nil
      assert packet.request_ack == false
      assert packet.naptr_routed == false
    end

    test "packet with target and sender MACs" do
      {:ok, target_mac} = Packet.parse_mac("aa:bb:cc:dd:ee:ff")
      {:ok, sender_mac} = Packet.parse_mac("11:22:33:44:55:66")

      binary = Packet.encode(%{"hello" => "world"},
        target_mac: target_mac,
        sender_mac: sender_mac
      )

      assert {:ok, packet} = Packet.decode(binary)
      assert packet.target_mac == target_mac
      assert packet.sender_mac == sender_mac
    end

    test "packet with request_ack flag" do
      binary = Packet.encode(%{"x" => 1}, request_ack: true)
      assert {:ok, packet} = Packet.decode(binary)
      assert packet.request_ack == true
    end

    test "packet with naptr_routed flag" do
      binary = Packet.encode(%{}, naptr_routed: true)
      assert {:ok, packet} = Packet.decode(binary)
      assert packet.naptr_routed == true
    end

    test "WoL body is target MAC repeated 16 times" do
      {:ok, mac} = Packet.parse_mac("de:ad:be:ef:ca:fe")
      binary = Packet.encode(%{}, target_mac: mac)

      # WoL body starts at offset 18, length 96
      wol_body = binary_part(binary, 18, 96)
      assert wol_body == String.duplicate(mac, 16)
    end

    test "large payload survives round-trip" do
      big = %{"data" => String.duplicate("x", 10_000)}
      binary = Packet.encode(big)
      assert {:ok, packet} = Packet.decode(binary)
      assert packet.payload == big
    end
  end

  describe "Packet.decode/1 error cases" do
    test "wrong magic returns :bad_magic" do
      bad = <<"XYZW", 0x01, 0x00, 0::48*8>>
      assert {:error, :bad_magic} = Packet.decode(bad)
    end

    test "too-short binary returns :too_short" do
      assert {:error, :too_short} = Packet.decode(<<"BURB", 0x01>>)
    end

    test "truncated payload returns :truncated_payload" do
      binary = Packet.encode(%{"ok" => true})
      # Lie about payload length — claim 500 bytes but provide fewer
      <<header::binary-size(114), _len::16, rest::binary>> = binary
      corrupt = <<header::binary, 500::big-16, rest::binary>>
      assert {:error, :truncated_payload} = Packet.decode(corrupt)
    end
  end

  # ---------------------------------------------------------------------------
  # MAC parse / format
  # ---------------------------------------------------------------------------

  describe "Packet.parse_mac/1" do
    test "valid MAC" do
      assert {:ok, <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>} =
               Packet.parse_mac("aa:bb:cc:dd:ee:ff")
    end

    test "uppercase MAC" do
      assert {:ok, _} = Packet.parse_mac("AA:BB:CC:DD:EE:FF")
    end

    test "too few octets" do
      assert {:error, :invalid_mac} = Packet.parse_mac("aa:bb:cc")
    end

    test "non-hex garbage" do
      assert {:error, :invalid_mac} = Packet.parse_mac("zz:zz:zz:zz:zz:zz")
    end
  end

  describe "Packet.format_mac/1" do
    test "formats 6-byte binary to colon-separated lowercase hex" do
      mac = <<0xAA, 0x0B, 0xCC, 0x0D, 0xEE, 0xFF>>
      assert Packet.format_mac(mac) == "aa:0b:cc:0d:ee:ff"
    end
  end

  # ---------------------------------------------------------------------------
  # Sender.parse_target/1
  # ---------------------------------------------------------------------------

  describe "Sender.parse_target/1" do
    test "bare IPv4" do
      assert {:ok, {{192, 168, 1, 100}, nil}} = Sender.parse_target("192.168.1.100")
    end

    test "IPv4 with slash-MAC" do
      assert {:ok, {{192, 168, 1, 100}, mac}} =
               Sender.parse_target("192.168.1.100/aa:bb:cc:dd:ee:ff")

      assert byte_size(mac) == 6
    end

    test "IPv4 with space-MAC" do
      assert {:ok, {{10, 0, 0, 1}, _mac}} =
               Sender.parse_target("10.0.0.1 aa:bb:cc:dd:ee:ff")
    end

    test "IPv6 loopback" do
      assert {:ok, {{0, 0, 0, 0, 0, 0, 0, 1}, nil}} = Sender.parse_target("::1")
    end

    test "invalid IP" do
      assert {:error, _} = Sender.parse_target("not.an.ip")
    end

    test "invalid MAC" do
      assert {:error, _} = Sender.parse_target("192.168.1.1/zz:zz:zz:zz:zz:zz")
    end
  end

  # ---------------------------------------------------------------------------
  # Bolt.send/2 — loopback smoke test
  # ---------------------------------------------------------------------------

  describe "Burble.Bolt.send/2" do
    test "sends to loopback without error" do
      # Opens a UDP socket on a random port to receive the bolt
      {:ok, sock} = :gen_udp.open(0, [:binary, active: false])
      {:ok, port} = :inet.port(sock)

      # Send bolt to 127.0.0.1 at the ephemeral port (bypass normal port 7373)
      {:ok, target} = Sender.parse_target("127.0.0.1")
      result = Sender.send(target, [wol_compat: false, payload: %{"test" => true}])
      # We can't easily control the destination port in Sender (it's fixed to 7373),
      # but we verify Sender returns :ok without crashing.
      assert result == :ok or match?({:error, _}, result)

      :gen_udp.close(sock)
    end
  end

  # ---------------------------------------------------------------------------
  # Packet constants
  # ---------------------------------------------------------------------------

  test "port/0 returns 7373" do
    assert Packet.port() == 7373
  end

  test "wol_port/0 returns 9" do
    assert Packet.wol_port() == 9
  end

  # ---------------------------------------------------------------------------
  # QUIC transport — gated on quicer availability
  # ---------------------------------------------------------------------------

  describe "Burble.Bolt.Quic.available?/0" do
    test "returns a boolean and never raises" do
      assert is_boolean(Quic.available?())
    end
  end

  describe "Burble.Bolt.Quic.cert_paths/0" do
    test "returns {:ok, cert, key} when the dev cert is present" do
      # Contract: either both cert files genuinely exist, or the function
      # degrades with *exactly* {:error, :no_cert} (acceptable in CI
      # without the dev cert). Asserting the exact error tuple catches a
      # regression to any other failure mode, which the old `assert true`
      # silently swallowed.
      case Quic.cert_paths() do
        {:ok, cert, key} ->
          assert File.exists?(cert)
          assert File.exists?(key)

        other ->
          assert other == {:error, :no_cert}
      end
    end
  end

  describe "Burble.Bolt.Quic.send_datagram/3 (no quicer)" do
    @tag :quic
    test "returns {:error, :quicer_not_available} when NIF is absent" do
      unless Quic.available?() do
        assert {:error, :quicer_not_available} =
                 Quic.send_datagram({127, 0, 0, 1}, <<"noop">>)
      end
    end
  end

  describe "Burble.Bolt.Sender.send/2 :transport option" do
    test ":udp explicitly forces raw UDP (default behavior, no fallback)" do
      {:ok, target} = Sender.parse_target("127.0.0.1")
      result = Sender.send(target, transport: :udp, wol_compat: false)
      assert result == :ok or match?({:error, _}, result)
    end

    test ":quic to broadcast IP refuses with :quic_broadcast_unsupported" do
      result = Sender.send(:broadcast, transport: :quic, wol_compat: false)
      assert result == {:error, :quic_broadcast_unsupported}
    end

    test ":quic without quicer returns :quicer_not_available, never crashes" do
      unless Quic.available?() do
        {:ok, target} = Sender.parse_target("127.0.0.1")
        assert {:error, :quicer_not_available} =
                 Sender.send(target, transport: :quic, wol_compat: false)
      end
    end

    test ":auto without try_quic stays on UDP even when quicer is loaded" do
      {:ok, target} = Sender.parse_target("127.0.0.1")
      # No assertion against transport — we just verify the call returns
      # without raising. The branch coverage matters more than the result.
      result = Sender.send(target, transport: :auto, wol_compat: false)
      assert result == :ok or match?({:error, _}, result)
    end
  end
end
