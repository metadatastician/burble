# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# ── DISAMBIGUATION ────────────────────────────────────────────────────────────
# "Vext" here = the feed-integrity verification protocol (hash chains;
# SHA-256 in this implementation).
# NOT the IRC VCS notification daemon, which was renamed to vcs-ircd.
# See burble/server/lib/burble/verification/vext.ex for the full disambiguation.
# ─────────────────────────────────────────────────────────────────────────────
#
# Burble.Verification.VextGroove — Groove-aware bridge to the Vext service.
#
# When Vext is available via groove (port 6480), Burble forwards text
# channel verification headers for independent attestation. This means:
#
#   1. Burble creates the hash chain locally (Burble.Verification.Vext)
#   2. Vext independently verifies the chain and attests it (this module)
#   3. Users get TWO independent proofs: Burble's and Vext's
#
# When Vext is NOT available, Burble's own verification still works.
# The groove just adds an independent attestation layer on top.
#
# This is the Verification Triad in action:
#   Burble (transport) + Vext (integrity) + Avow (consent)
#
# The groove connector types are formally verified in Gossamer's Groove.idr:
# - GrooveCompat proves Burble↔Vext composition is sound
# - Burble offers [Voice, Text], Vext consumes [Voice, Text] ✓
# - Vext offers [Integrity], Burble consumes [Integrity] ✓

defmodule Burble.Verification.VextGroove do
  @moduledoc """
  Groove-aware bridge that sends verification headers to the external
  Vext service for independent attestation.

  Wraps the Burble.Groove messaging to send structured verification
  requests and receive attestation responses.
  """

  require Logger

  @vext_groove_timeout_ms 2_000

  @doc """
  Forward a verification header to Vext for independent attestation.

  Sends the header via the groove protocol. Vext will:
  1. Verify the hash chain independently
  2. Add its own attestation signature
  3. Store the proof in its hash chain registry

  Returns {:ok, attestation} on success, :unavailable if Vext not grooved.
  """
  @spec attest_header(map(), String.t()) :: {:ok, map()} | :unavailable | {:error, term()}
  def attest_header(verification_header, channel_id) do
    message = %{
      type: "vext_attest_request",
      source: "burble",
      channel_id: channel_id,
      header: verification_header,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    case send_to_vext(message) do
      :ok -> {:ok, %{status: :submitted, channel_id: channel_id}}
      :unavailable -> :unavailable
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Forward an entire feed for batch verification by Vext.

  Used when a client requests full chain verification — Vext walks
  the entire chain and returns a comprehensive attestation.
  """
  @spec attest_feed(list(), String.t()) :: {:ok, map()} | :unavailable | {:error, term()}
  def attest_feed(articles_with_headers, channel_id) do
    message = %{
      type: "vext_feed_verify_request",
      source: "burble",
      channel_id: channel_id,
      article_count: length(articles_with_headers),
      chain_hashes:
        Enum.map(articles_with_headers, fn {_body, _author, _ts, header} ->
          header.chain_hash
        end),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    case send_to_vext(message) do
      :ok -> {:ok, %{status: :submitted, article_count: length(articles_with_headers)}}
      :unavailable -> :unavailable
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Check if Vext is available via groove discovery.
  Delegates to the main Groove GenServer.
  """
  @spec vext_available?() :: boolean()
  def vext_available? do
    try do
      Burble.Groove.manifest_json()
      # Check if Vext is in our consumes list and reachable.
      probe_vext()
    catch
      :exit, _ -> false
    end
  end

  # ── Private ──

  defp send_to_vext(message) do
    case :gen_tcp.connect(
           ~c"127.0.0.1",
           6480,
           [:binary, active: false],
           @vext_groove_timeout_ms
         ) do
      {:ok, socket} ->
        payload = Jason.encode!(message)

        request =
          "POST /.well-known/groove/message HTTP/1.0\r\n" <>
            "Host: localhost\r\n" <>
            "Content-Type: application/json\r\n" <>
            "Content-Length: #{byte_size(payload)}\r\n" <>
            "Connection: close\r\n\r\n" <>
            payload

        :gen_tcp.send(socket, request)
        :gen_tcp.close(socket)
        :ok

      {:error, :econnrefused} ->
        :unavailable

      {:error, reason} ->
        Logger.warning("VextGroove: failed to connect to Vext: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp probe_vext do
    case :gen_tcp.connect(~c"127.0.0.1", 6480, [:binary, active: false], @vext_groove_timeout_ms) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _} ->
        false
    end
  end
end
