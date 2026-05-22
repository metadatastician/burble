# SPDX-License-Identifier: MPL-2.0
#
# Burble.Bolt — public API for the Burble Bolt feature.
#
# Burble Bolt is a network-layer "poke": send a magic packet to an IP address
# and, if Burble is running there, it flashes a desktop/browser incoming-call
# notification. Similar to Wake-on-LAN (WoL) in structure; triggered like a
# ringing phone in effect.
#
# Usage (from release CLI):
#   bin/burble bolt 192.168.1.100
#   bin/burble bolt 192.168.1.100/aa:bb:cc:dd:ee:ff
#   bin/burble bolt fe80::1
#   bin/burble bolt user@example.com          # NAPTR/SRV DNS lookup
#   bin/burble bolt --broadcast               # LAN broadcast
#
# The bolt travels via:
#   Primary:  QUIC datagram (RFC 9221) on UDP port 7373  — TLS-authenticated
#   Fallback: Raw UDP on port 7373
#   WoL compat: Raw UDP also sent to port 9 (IANA discard / WoL port)

defmodule Burble.Bolt do
  @moduledoc """
  Burble Bolt — fire a magic incoming-call packet at any Burble-enabled host.

  ## Quick examples

      # Direct IP
      Burble.Bolt.send("192.168.1.100")

      # IP + MAC (stronger WoL compat)
      Burble.Bolt.send("192.168.1.100/aa:bb:cc:dd:ee:ff")

      # IPv6
      Burble.Bolt.send("fe80::1")

      # DNS (NAPTR / SRV / A fallback)
      Burble.Bolt.send("user@example.com")

      # LAN broadcast
      Burble.Bolt.broadcast()

  ## What happens on the receiving end

  If Burble is running on the target host and the browser/desktop client is
  connected:
    1. A desktop notification flashes: "Incoming Bolt from <sender>"
    2. An incoming-call overlay appears in the UI with Accept / Dismiss.
    3. If accepted, a voice room is created or the sender's room URL is opened.
  """

  alias Burble.Bolt.{Sender, NAPTR}

  @doc """
  Send a Burble Bolt to `target`.

  `target` can be:
  - An IPv4 string: `"192.168.1.100"`
  - An IPv4+MAC string: `"192.168.1.100/aa:bb:cc:dd:ee:ff"`
  - An IPv6 string: `"fe80::1"`
  - A domain or user@domain: `"user@example.com"` (DNS NAPTR/SRV lookup)

  Options:
  - `:payload` — extra map merged into the bolt JSON payload
  - `:request_ack` — ask recipient to send a bolt back (default: false)
  - `:wol_compat` — also send to WoL port 9 (default: true)
  - `:display_name` — name shown in the recipient's notification
  """
  @spec send(String.t(), keyword()) :: :ok | {:error, term()}
  def send(target_str, opts \\ []) do
    opts = inject_display_name(opts)

    cond do
      String.contains?(target_str, "@") or
        (not String.contains?(target_str, ".") and not String.contains?(target_str, ":")) ->
        # Looks like a domain or user@domain — use NAPTR
        NAPTR.send(target_str, opts)

      true ->
        # IP address (v4 or v6, optionally with /MAC)
        case Sender.parse_target(target_str) do
          {:ok, target} -> Sender.send(target, opts)
          {:error, _} = err -> err
        end
    end
  end

  @doc """
  Broadcast a Bolt on the local network.

  Every Burble node on the LAN segment receives it.
  """
  @spec broadcast(keyword()) :: :ok | {:error, term()}
  def broadcast(opts \\ []) do
    Sender.broadcast(inject_display_name(opts))
  end

  # ---------------------------------------------------------------------------
  # Release CLI entry point
  # ---------------------------------------------------------------------------

  @doc false
  def cli_main(args) do
    case args do
      ["--broadcast" | rest] ->
        opts = parse_cli_opts(rest)
        case broadcast(opts) do
          :ok -> IO.puts("Bolt broadcast sent.")
          {:error, reason} -> IO.puts("Error: #{inspect(reason)}"); System.halt(1)
        end

      [target | rest] ->
        opts = parse_cli_opts(rest)
        case __MODULE__.send(target, opts) do
          :ok -> IO.puts("Bolt sent to #{target}.")
          {:error, reason} -> IO.puts("Error: #{inspect(reason)}"); System.halt(1)
        end

      [] ->
        IO.puts("""
        Usage: burble bolt <target> [options]

        Targets:
          192.168.1.100                   IPv4 address
          192.168.1.100/aa:bb:cc:dd:ee:ff  IPv4 + MAC (WoL compat)
          fe80::1                         IPv6 address
          user@example.com                DNS NAPTR/SRV lookup
          --broadcast                     LAN broadcast

        Options:
          --name "Alice"                  Display name shown on recipient
          --ack                           Request acknowledgement bolt back
          --no-wol                        Skip WoL port-9 send
        """)
    end
  end

  defp parse_cli_opts(args) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce([], fn
      ["--name", name], acc -> Keyword.put(acc, :display_name, name)
      ["--ack"], acc -> Keyword.put(acc, :request_ack, true)
      ["--no-wol"], acc -> Keyword.put(acc, :wol_compat, false)
      _, acc -> acc
    end)
  end

  defp inject_display_name(opts) do
    if opts[:display_name] do
      payload = Map.put(opts[:payload] || %{}, "display_name", opts[:display_name])
      Keyword.put(opts, :payload, payload)
    else
      opts
    end
  end
end
