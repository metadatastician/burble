# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Burble.Bolt.Spa — Single-Packet-Authorisation for Bolt magic packets.
#
# A raw-UDP bolt is trivially spoofable: anyone who can reach udp/7373 can
# forge an "incoming call" notification. Bolt's authenticated QUIC transport
# (ADR-0004) is the eventual answer, but msquic is a heavyweight native
# dependency and is parked (see the "help wanted" issue). SPA is the cheap
# interim that closes the actual hole with no native dependency: a shared
# `bolt_secret` + timestamp + one-shot nonce authenticates every bolt in pure
# Elixir — the same HMAC construction as the BLE-SPA design, applied at the
# IP layer (à la fwknop).
#
# Opt-in and switchable: with no secret configured, bolts behave exactly as
# before (unauthenticated). Set `config :burble, :bolt_secret` (or
# `BURBLE_BOLT_SECRET` at runtime) and every bolt must carry a valid,
# fresh, non-replayed SPA tag or it is dropped before dispatch.

defmodule Burble.Bolt.Spa do
  require Logger

  # Replay-protection table: nonce => expiry_ms. Owned by Burble.Bolt.Listener
  # (created in its init) so it lives for the app's lifetime.
  @nonce_table :bolt_spa_nonces

  # Accept ±30s of clock skew between sender and receiver.
  @window_ms 30_000

  # Truncate the HMAC-SHA256 to 128 bits — ample for a short-lived poke tag.
  @mac_bytes 16

  @doc "The configured bolt secret, or nil when SPA is disabled."
  @spec secret() :: binary() | nil
  def secret, do: Application.get_env(:burble, :bolt_secret)

  @doc "True when a non-empty bolt secret is configured."
  @spec enabled?() :: boolean()
  def enabled? do
    case secret() do
      s when is_binary(s) and byte_size(s) > 0 -> true
      _ -> false
    end
  end

  @doc """
  Create the replay-protection ETS table. Idempotent — safe to call from the
  Listener's init even if a prior instance already made it.
  """
  @spec init_replay_table() :: :ok
  def init_replay_table do
    case :ets.whereis(@nonce_table) do
      :undefined ->
        :ets.new(@nonce_table, [:named_table, :public, :set])
        :ok

      _ref ->
        :ok
    end
  end

  @doc """
  Attach an SPA tag to a bolt payload map. Returns the payload with an added
  `"spa"` object: `%{"ts" => ms, "nonce" => b64, "mac" => b64}`.
  """
  @spec sign(map(), binary()) :: map()
  def sign(payload, secret) when is_map(payload) and is_binary(secret) do
    ts = System.os_time(:millisecond)
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    from = to_string(Map.get(payload, "from", ""))
    mac = compute_mac(secret, ts, nonce, from)
    Map.put(payload, "spa", %{"ts" => ts, "nonce" => nonce, "mac" => mac})
  end

  @doc """
  Verify a decoded bolt payload's SPA tag against `secret`.

  Checks, in order: tag present and well-formed; timestamp within ±30s;
  HMAC matches (constant-time); nonce not seen before (one-shot). Returns
  `:ok` or `{:error, reason}`.
  """
  @spec verify(map(), binary()) ::
          :ok
          | {:error,
             :missing_spa | :malformed_spa | :stale_timestamp | :bad_mac | :replayed_nonce}
  def verify(payload, secret) when is_map(payload) and is_binary(secret) do
    init_replay_table()

    case Map.get(payload, "spa") do
      %{"ts" => ts, "nonce" => nonce, "mac" => mac}
      when is_integer(ts) and is_binary(nonce) and is_binary(mac) ->
        from = to_string(Map.get(payload, "from", ""))
        expected = compute_mac(secret, ts, nonce, from)

        cond do
          not within_window?(ts) -> {:error, :stale_timestamp}
          not constant_time_eq?(mac, expected) -> {:error, :bad_mac}
          true -> record_nonce(nonce, ts)
        end

      nil ->
        {:error, :missing_spa}

      _ ->
        {:error, :malformed_spa}
    end
  end

  # ---------------------------------------------------------------------------

  defp compute_mac(secret, ts, nonce, from) do
    :crypto.mac(:hmac, :sha256, secret, "#{ts}:#{nonce}:#{from}")
    |> binary_part(0, @mac_bytes)
    |> Base.url_encode64(padding: false)
  end

  defp within_window?(ts), do: abs(System.os_time(:millisecond) - ts) <= @window_ms

  # One-shot nonce: reject if seen and not yet expired; otherwise record.
  # Prunes opportunistically so the table can't grow unbounded.
  defp record_nonce(nonce, ts) do
    now = System.os_time(:millisecond)
    prune(now)
    expiry = ts + @window_ms

    case :ets.lookup(@nonce_table, nonce) do
      [{^nonce, exp}] when exp >= now ->
        {:error, :replayed_nonce}

      _ ->
        :ets.insert(@nonce_table, {nonce, expiry})
        :ok
    end
  end

  defp prune(now) do
    # Delete every entry whose expiry is in the past.
    :ets.select_delete(@nonce_table, [{{:_, :"$1"}, [{:<, :"$1", now}], [true]}])
  end

  defp constant_time_eq?(a, b) when byte_size(a) == byte_size(b),
    do: :crypto.hash_equals(a, b)

  defp constant_time_eq?(_, _), do: false
end
