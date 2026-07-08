# SPDX-License-Identifier: MPL-2.0
#
# Burble.Bolt.Sender — fire a Burble Bolt at an IPv4, IPv6, or domain target.
#
# Transport priority:
#   1. QUIC datagram (RFC 9221) on port 7373  — authenticated, 0-RTT
#   2. Raw UDP on port 7373                   — unauthenticated, WoL-style
#   3. Raw UDP on port 9  (WoL compat)        — simultaneously with #1 or #2
#
# Port 9 is the traditional Wake-on-LAN port (IANA discard). Burble sends
# the magic packet there too so that WoL-enabled NICs or existing WoL
# infrastructure treats the bolt as a wake event. Burble does not listen on
# port 9 (requires root on Linux); it only sends.

defmodule Burble.Bolt.Sender do
  require Logger

  alias Burble.Bolt.{Packet, Quic}

  @bolt_port Packet.port()
  @wol_port  Packet.wol_port()

  @typedoc """
  A bolt target. Accepted forms:
  - `{ip_tuple, nil}`              — IPv4 or IPv6, no MAC binding
  - `{ip_tuple, mac_binary}`       — IPv4 + MAC (strongest WoL compat)
  - `:broadcast`                   — LAN broadcast (255.255.255.255)
  """
  @type target :: {{byte(), byte(), byte(), byte()}, binary() | nil}
               | {{char()}, binary() | nil}
               | :broadcast

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Send a Burble Bolt to `target`.

  Options:
  - `:sender_mac`   — this host's MAC, embedded in packet (optional)
  - `:payload`      — extra JSON map merged into the bolt payload
  - `:request_ack`  — ask recipient to bolt back as acknowledgement
  - `:wol_compat`   — also send to WoL port 9 (default: true)
  - `:naptr_routed` — mark packet as NAPTR-resolved (for recipient info)
  - `:transport`    — `:auto` (default), `:udp`, or `:quic`:
      * `:auto` tries QUIC when `Burble.Bolt.Quic.available?/0` is true
        AND the caller opted in via `:try_quic` (default `false`);
        otherwise UDP. This keeps cold bolts cheap (no QUIC handshake
        burned on senders that have no reason to expect a listener).
      * `:udp` forces raw UDP (legacy behavior, always supported).
      * `:quic` forces QUIC and reports `{:error, …}` on failure rather
        than falling through to UDP — useful for tests and for callers
        that know the recipient supports it.
  - `:try_quic`     — when true with `:transport => :auto`, attempt QUIC
    first and silently fall back to UDP on any failure (default `false`).
  """
  @spec send(target(), keyword()) :: :ok | {:error, term()}
  def send(target, opts \\ []) do
    wol_compat  = Keyword.get(opts, :wol_compat, true)
    target_mac  = resolve_mac(target)
    sender_mac  = opts[:sender_mac]
    request_ack = opts[:request_ack] || false
    naptr_routed = opts[:naptr_routed] || false
    transport   = Keyword.get(opts, :transport, :auto)
    try_quic    = Keyword.get(opts, :try_quic, false)

    payload =
      Map.merge(%{
        "from"    => node_id(),
        "server"  => server_url(),
        "ts"      => System.os_time(:millisecond)
      }, opts[:payload] || %{})
      |> maybe_sign()

    packet = Packet.encode(payload,
      target_mac:   target_mac,
      sender_mac:   sender_mac,
      request_ack:  request_ack,
      naptr_routed: naptr_routed
    )

    ip = resolve_ip(target)

    result = dispatch(transport, try_quic, ip, packet)

    if wol_compat do
      # Best-effort WoL send to port 9 — don't fail the bolt if this fails
      _ = send_udp(ip, @wol_port, packet)
    end

    result
  end

  @doc """
  Send a bolt over QUIC explicitly. Returns `{:error, :quicer_not_available}`
  if the NIF is not loaded — callers should fall back to `send/2` with
  `transport: :udp` in that case.
  """
  @spec send_quic(target(), keyword()) :: :ok | {:error, term()}
  def send_quic(target, opts \\ []) do
    __MODULE__.send(target, Keyword.merge(opts, transport: :quic, wol_compat: false))
  end

  # ---------------------------------------------------------------------------
  # Transport dispatch
  # ---------------------------------------------------------------------------

  defp dispatch(:udp, _try_quic, ip, packet) do
    send_udp(ip, @bolt_port, packet)
  end

  defp dispatch(:quic, _try_quic, {255, 255, 255, 255}, _packet) do
    # QUIC has no notion of LAN broadcast — refuse explicitly so the caller
    # does not silently get unicast behavior.
    {:error, :quic_broadcast_unsupported}
  end

  defp dispatch(:quic, _try_quic, ip, packet) do
    Quic.send_datagram(ip, packet)
  end

  defp dispatch(:auto, true, ip, packet) when ip != {255, 255, 255, 255} do
    if Quic.available?() do
      case Quic.send_datagram(ip, packet) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.debug("[Bolt] QUIC send failed (#{inspect(reason)}), falling back to UDP")
          send_udp(ip, @bolt_port, packet)
      end
    else
      send_udp(ip, @bolt_port, packet)
    end
  end

  defp dispatch(:auto, _try_quic, ip, packet) do
    send_udp(ip, @bolt_port, packet)
  end

  @doc """
  Broadcast a bolt on the local network (255.255.255.255, port 7373 + port 9).
  Every Burble node on the LAN will receive it.
  """
  @spec broadcast(keyword()) :: :ok | {:error, term()}
  def broadcast(opts \\ []) do
    __MODULE__.send(:broadcast, Keyword.put(opts, :wol_compat, true))
  end

  @doc """
  Parse a target string into a `{ip_tuple, mac_or_nil}` pair.

  Accepted formats:
  - `"192.168.1.100"`
  - `"192.168.1.100/aa:bb:cc:dd:ee:ff"`
  - `"192.168.1.100 aa:bb:cc:dd:ee:ff"`
  - `"fe80::1"`
  - `"fe80::aabb:ccff:fedd:eeff"`   (EUI-64 — MAC extractable)
  """
  @spec parse_target(String.t()) :: {:ok, target()} | {:error, term()}
  def parse_target(str) do
    str = String.trim(str)

    {ip_str, mac_str} =
      cond do
        String.contains?(str, "/") ->
          [ip, mac] = String.split(str, "/", parts: 2)
          {String.trim(ip), String.trim(mac)}

        String.match?(str, ~r/\s+[0-9a-f]{2}:/i) ->
          [ip | rest] = String.split(str, ~r/\s+/, parts: 2)
          {ip, Enum.join(rest, " ")}

        true ->
          {str, nil}
      end

    with {:ok, ip} <- parse_ip(ip_str),
         {:ok, mac} <- parse_mac_opt(mac_str) do
      {:ok, {ip, mac}}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp send_udp(:broadcast, port, packet) do
    opts = [:binary, active: false, broadcast: true]
    with {:ok, sock} <- :gen_udp.open(0, opts),
         :ok <- :gen_udp.send(sock, {255, 255, 255, 255}, port, packet) do
      :gen_udp.close(sock)
      :ok
    end
  end

  defp send_udp(ip, port, packet) do
    opts = [:binary, active: false]
    with {:ok, sock} <- :gen_udp.open(0, opts),
         :ok <- :gen_udp.send(sock, ip, port, packet) do
      :gen_udp.close(sock)
      :ok
    else
      {:error, reason} = err ->
        Logger.warning("[Bolt] UDP send failed: #{inspect(reason)}")
        err
    end
  end

  defp resolve_ip(:broadcast), do: {255, 255, 255, 255}
  defp resolve_ip({ip, _mac}), do: ip

  defp resolve_mac(:broadcast), do: nil
  defp resolve_mac({_ip, mac}), do: mac

  defp parse_ip(str) do
    charlist = String.to_charlist(str)
    case :inet.parse_address(charlist) do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> {:error, {:invalid_ip, str}}
    end
  end

  defp parse_mac_opt(nil), do: {:ok, nil}
  defp parse_mac_opt(""), do: {:ok, nil}
  defp parse_mac_opt(str) do
    case Packet.parse_mac(str) do
      {:ok, mac} -> {:ok, mac}
      {:error, _} -> {:error, {:invalid_mac, str}}
    end
  end

  defp node_id do
    case node() do
      :nonode@nohost -> "unknown"
      n -> Atom.to_string(n)
    end
  end

  defp server_url do
    Application.get_env(:burble, :server_url, "unknown")
  end

  # Attach an SPA authentication tag when a bolt secret is configured;
  # otherwise send the payload as-is (unauthenticated, legacy behaviour).
  defp maybe_sign(payload) do
    case Burble.Bolt.Spa.enabled?() && Burble.Bolt.Spa.secret() do
      secret when is_binary(secret) -> Burble.Bolt.Spa.sign(payload, secret)
      _ -> payload
    end
  end
end
