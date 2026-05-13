# SPDX-License-Identifier: PMPL-1.0-or-later
#
# Burble.Bolt.Packet — wire format for Burble Bolt magic packets.
#
# Burble Bolt is a network-layer poke: send a magic UDP packet to an IPv4/IPv6
# address and, if Burble is running there, it triggers an incoming-call
# notification on the recipient's screen.
#
# Inspired by Wake-on-LAN (RFC 0009 / WoL magic packet) but over QUIC datagrams
# (RFC 9221) on port 7373, with raw-UDP fallback and WoL port-9 compatibility.
#
# Packet layout (all offsets in bytes):
#
#   0–3    Magic: "BURB"  (0x42 0x55 0x52 0x42)
#   4      Version: 0x01
#   5      Flags  (bit 0 = has_target_mac, bit 1 = has_sender_mac,
#                  bit 2 = naptr_routed,   bit 3 = request_ack)
#   6–11   Target MAC (6 bytes; 00:00:00:00:00:00 if absent)
#  12–17   Sender MAC (6 bytes; 00:00:00:00:00:00 if absent)
#  18–113  Target MAC × 16  (96 bytes; WoL-style body for compat)
# 114–115  Payload length, big-endian uint16
# 116+     Payload (UTF-8 JSON)
#
# Minimum packet size: 116 bytes (empty payload).
# Maximum payload:     65 419 bytes (UDP datagram limit minus header).

defmodule Burble.Bolt.Packet do
  @moduledoc """
  Binary encode/decode for Burble Bolt magic packets.

  The wire format is intentionally similar to Wake-on-LAN so that firewalls
  and network equipment that pass WoL traffic will also pass Bolt packets.
  """

  # Bitwise operators (&&&, |||) moved out of the Elixir prelude in 1.10.
  # The set_flag/3 and flag_set?/2 helpers use them.
  import Bitwise

  @magic "BURB"
  @version 0x01
  @port 7373
  @wol_port 9

  # Flag bits
  @flag_has_target_mac 0x01
  @flag_has_sender_mac 0x02
  @flag_naptr_routed   0x04
  @flag_request_ack    0x08

  defstruct [
    :target_mac,
    :sender_mac,
    :payload,
    flags: 0,
    naptr_routed: false,
    request_ack: false
  ]

  @type mac :: <<_::48>>
  @type t :: %__MODULE__{
    target_mac:   mac | nil,
    sender_mac:   mac | nil,
    payload:      map(),
    flags:        non_neg_integer(),
    naptr_routed: boolean(),
    request_ack:  boolean()
  }

  @doc "UDP port Burble Bolt listens on."
  def port, do: @port

  @doc "WoL compat port (port 9 / discard). Bolts are also sent here for WoL passthrough."
  def wol_port, do: @wol_port

  @doc """
  Encode a Bolt packet to binary.

  `payload` is a map that will be JSON-encoded and embedded in the packet.
  `target_mac` and `sender_mac` are optional 6-byte binaries.
  """
  @spec encode(map(), keyword()) :: binary()
  def encode(payload, opts \\ []) do
    target_mac = opts[:target_mac] || <<0, 0, 0, 0, 0, 0>>
    sender_mac = opts[:sender_mac] || <<0, 0, 0, 0, 0, 0>>
    naptr_routed = opts[:naptr_routed] || false
    request_ack  = opts[:request_ack]  || false

    flags =
      0
      |> set_flag(@flag_has_target_mac, target_mac != <<0, 0, 0, 0, 0, 0>>)
      |> set_flag(@flag_has_sender_mac, sender_mac != <<0, 0, 0, 0, 0, 0>>)
      |> set_flag(@flag_naptr_routed, naptr_routed)
      |> set_flag(@flag_request_ack, request_ack)

    # WoL-style body: target MAC repeated 16 times
    wol_body = String.duplicate(target_mac, 16)

    json = Jason.encode!(payload)
    payload_len = byte_size(json)

    <<
      @magic::binary,
      @version::8,
      flags::8,
      target_mac::binary-size(6),
      sender_mac::binary-size(6),
      wol_body::binary-size(96),
      payload_len::big-unsigned-16,
      json::binary
    >>
  end

  @doc """
  Decode a binary bolt packet.

  Returns `{:ok, packet}` or `{:error, reason}`.
  """
  @spec decode(binary()) :: {:ok, t()} | {:error, atom()}
  def decode(<<
    @magic,
    @version::8,
    flags::8,
    target_mac::binary-size(6),
    sender_mac::binary-size(6),
    _wol_body::binary-size(96),
    payload_len::big-unsigned-16,
    rest::binary
  >>) do
    with {:payload, json} when byte_size(json) == payload_len <- {:payload, rest},
         {:ok, payload} <- Jason.decode(json) do
      {:ok, %__MODULE__{
        target_mac:   (if flag_set?(flags, @flag_has_target_mac), do: target_mac),
        sender_mac:   (if flag_set?(flags, @flag_has_sender_mac), do: sender_mac),
        payload:      payload,
        flags:        flags,
        naptr_routed: flag_set?(flags, @flag_naptr_routed),
        request_ack:  flag_set?(flags, @flag_request_ack)
      }}
    else
      {:payload, _} -> {:error, :truncated_payload}
      {:error, _}   -> {:error, :invalid_json}
    end
  end

  def decode(<<magic::binary-size(4), _::binary>>) when magic != @magic,
    do: {:error, :bad_magic}

  def decode(_), do: {:error, :too_short}

  @doc "Parse a MAC address string (\"aa:bb:cc:dd:ee:ff\") to 6-byte binary."
  @spec parse_mac(String.t()) :: {:ok, mac()} | {:error, :invalid_mac}
  def parse_mac(str) do
    parts = String.split(str, ":")
    with 6 <- length(parts),
         bytes when length(bytes) == 6 <- Enum.map(parts, &Integer.parse(&1, 16)),
         true <- Enum.all?(bytes, fn {n, ""} -> n in 0..255; _ -> false end) do
      mac = for {n, ""} <- bytes, into: <<>>, do: <<n>>
      {:ok, mac}
    else
      _ -> {:error, :invalid_mac}
    end
  end

  @doc "Format a 6-byte MAC binary to \"aa:bb:cc:dd:ee:ff\" string."
  @spec format_mac(mac()) :: String.t()
  def format_mac(<<a, b, c, d, e, f>>),
    do: Enum.map_join([a, b, c, d, e, f], ":", &(Integer.to_string(&1, 16) |> String.pad_leading(2, "0")))

  # ---------------------------------------------------------------------------

  defp set_flag(flags, bit, true),  do: flags ||| bit
  defp set_flag(flags, _bit, false), do: flags

  defp flag_set?(flags, bit), do: (flags &&& bit) != 0
end
