# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Burble.Presence.BleSpa — BLE presence wire format v1 (ADR-0015).
#
# The canonical reference implementation of Burble's Bluetooth-LE presence
# layer: the bytes this module emits ARE the frozen wire format. neurophone
# (and any other consumer) pins against the committed test vectors
# (.machine_readable/test-vectors/ble-spa-v1.json), which are recomputed from
# this module by ble_spa_vectors_test.exs — so any drift here turns CI red.
#
# Three legacy-advertising frames, one 24-byte payload each, one primitive
# (HMAC-SHA256) with four frozen domain labels:
#
#   * Knock   (0x11) — one-shot Single-Packet-Authorisation "knock" (Silent zone)
#   * Presence(0x12) — rotating contact-resolvable beacon (Private/Trusted zones)
#   * Response(0x13) — connectable reply a knocker filters for (rendezvous)
#
# This is the SAME SPA construction as `Burble.Bolt.Spa` (HMAC-SHA256,
# one-shot nonce, ±30s window, constant-time compare) applied at the BLE
# advertising layer instead of the IP layer — "one SPA primitive, three
# layers" (ADR-0010). It is a sibling, not a refactor: Bolt.Spa is string/JSON
# encoded, this is raw binary. The Idris2 types in Burble.ABI.BleSpa are the
# design-assurance mirror (ADR-0008).
#
# All time-dependent functions take an explicit `now_s` (unix seconds) so the
# encoders/verifiers are pure and the vectors are deterministic.

defmodule Burble.Presence.BleSpa do
  import Bitwise

  # ── Frozen wire constants (ADR-0015; changing any is a v2 wire break) ──

  @magic 0x42
  @wire_version 0x1

  # Frame-type low nibbles.
  @ft_knock 0x1
  @ft_presence 0x2
  @ft_response 0x3

  # Composite ver_type bytes: (wire_version <<< 4) ||| frame_type.
  @knock_vt 0x11
  @presence_vt 0x12
  @response_vt 0x13

  # Manufacturer Specific Data envelope (SIG "internal use" company id).
  @company_id 0xFFFF
  @payload_bytes 24

  # HMAC-SHA256 domain-separation labels.
  @label_room "BRBL-ROOM-v1"
  @label_knock "BRBL-KNOCK-v1"
  @label_resp "BRBL-RESP-v1"
  @label_pres "BRBL-PRES-v1"

  # Truncation lengths.
  @knock_mac_bytes 12
  @resp_token_bytes 16
  @beacon_id_bytes 18

  # Behavioural constants.
  @window_s 30
  @epoch_seconds 900

  # One-shot nonce ledger (mirrors Bolt.Spa's :bolt_spa_nonces, kept separate).
  @nonce_table :ble_spa_nonces

  @type payload :: <<_::192>>
  @type verify_error ::
          :bad_length
          | :bad_magic
          | :bad_version
          | :bad_frame_type
          | :stale_timestamp
          | :bad_mac
          | :replayed_nonce

  # Expose the frozen constants for the descriptiles / doc cross-checks.
  @doc false
  def constants do
    %{
      magic: @magic,
      wire_version: @wire_version,
      company_id: @company_id,
      payload_bytes: @payload_bytes,
      knock_vt: @knock_vt,
      presence_vt: @presence_vt,
      response_vt: @response_vt,
      knock_mac_bytes: @knock_mac_bytes,
      resp_token_bytes: @resp_token_bytes,
      beacon_id_bytes: @beacon_id_bytes,
      window_s: @window_s,
      epoch_seconds: @epoch_seconds,
      labels: %{
        room: @label_room,
        knock: @label_knock,
        response: @label_resp,
        presence: @label_pres
      }
    }
  end

  # ── Room secret ──

  @doc """
  Derive the 32-byte room secret from a room invite token (one HMAC extract,
  no HKDF): `HMAC-SHA256(invite_token, "BRBL-ROOM-v1")`.
  """
  @spec derive_room_secret(binary()) :: <<_::256>>
  def derive_room_secret(invite_token) when is_binary(invite_token) do
    :crypto.mac(:hmac, :sha256, invite_token, @label_room)
  end

  # ── Knock (0x11) ──

  @doc """
  Encode a 24-byte knock: magic ‖ ver_type ‖ ts(u32 BE) ‖ nonce(6) ‖ mac(12).
  `nonce6` MUST be exactly 6 bytes and single-use.
  """
  @spec encode_knock(binary(), non_neg_integer(), <<_::48>>) :: payload()
  def encode_knock(room_secret, ts_s, nonce6)
      when is_binary(room_secret) and is_integer(ts_s) and ts_s >= 0 and
             is_binary(nonce6) and byte_size(nonce6) == 6 do
    prefix = <<@magic, @knock_vt, ts_s::32, nonce6::binary>>
    prefix <> knock_mac(room_secret, prefix)
  end

  @doc """
  Verify a knock payload. Checks, in order: length, magic, wire version, frame
  type, ±30s window, HMAC (constant-time), and (unless `check_replay: false`)
  one-shot nonce. Returns `:ok` or `{:error, reason}`.
  """
  @spec verify_knock(binary(), binary(), integer(), keyword()) :: :ok | {:error, verify_error()}
  def verify_knock(payload, room_secret, now_s, opts \\ [])
      when is_binary(payload) and is_binary(room_secret) and is_integer(now_s) do
    check_replay = Keyword.get(opts, :check_replay, true)

    if byte_size(payload) != @payload_bytes do
      {:error, :bad_length}
    else
      <<magic, ver_type, ts::32, nonce::binary-size(6), mac::binary-size(12)>> = payload

      cond do
        magic != @magic ->
          {:error, :bad_magic}

        ver_type >>> 4 != @wire_version ->
          {:error, :bad_version}

        (ver_type &&& 0x0F) != @ft_knock ->
          {:error, :bad_frame_type}

        not within_window?(ts, now_s) ->
          {:error, :stale_timestamp}

        not constant_time_eq?(mac, knock_mac(room_secret, binary_part(payload, 0, 12))) ->
          {:error, :bad_mac}

        check_replay ->
          record_nonce(nonce, ts, now_s)

        true ->
          :ok
      end
    end
  end

  defp knock_mac(room_secret, prefix12) do
    :crypto.mac(:hmac, :sha256, room_secret, @label_knock <> prefix12)
    |> binary_part(0, @knock_mac_bytes)
  end

  # ── Response (0x13) ──

  @doc """
  The 16-byte response token addressing a specific knock:
  `HMAC-SHA256(room_secret, "BRBL-RESP-v1" ‖ knock_ts(u32 BE) ‖ knock_nonce)[0..16]`.
  """
  @spec response_token(binary(), non_neg_integer(), <<_::48>>) :: <<_::128>>
  def response_token(room_secret, knock_ts, knock_nonce)
      when is_binary(room_secret) and is_integer(knock_ts) and knock_ts >= 0 and
             is_binary(knock_nonce) and byte_size(knock_nonce) == 6 do
    msg = @label_resp <> <<knock_ts::32>> <> knock_nonce
    :crypto.mac(:hmac, :sha256, room_secret, msg) |> binary_part(0, @resp_token_bytes)
  end

  @doc """
  Encode a 24-byte response: magic ‖ ver_type ‖ resp_ts(u32 BE) ‖ token(16) ‖ psm(u16 BE).
  `psm` is the responder's L2CAP CoC PSM (0 = none; Phase 3 fills it).
  """
  @spec encode_response(binary(), non_neg_integer(), <<_::48>>, non_neg_integer(), 0..0xFFFF) ::
          payload()
  def encode_response(room_secret, knock_ts, knock_nonce, resp_ts, psm)
      when is_integer(resp_ts) and resp_ts >= 0 and is_integer(psm) and psm in 0..0xFFFF do
    token = response_token(room_secret, knock_ts, knock_nonce)
    <<@magic, @response_vt, resp_ts::32>> <> token <> <<psm::16>>
  end

  @doc """
  Match a response payload against an outstanding knock's `(ts, nonce)`.
  Returns `{:ok, psm}` when the token matches, else `{:error, reason}`.
  """
  @spec match_response(binary(), binary(), non_neg_integer(), <<_::48>>, integer()) ::
          {:ok, 0..0xFFFF} | {:error, :bad_length | :bad_magic | :bad_version | :bad_frame_type | :bad_token}
  def match_response(payload, room_secret, knock_ts, knock_nonce, _now_s)
      when is_binary(payload) and is_binary(room_secret) do
    if byte_size(payload) != @payload_bytes do
      {:error, :bad_length}
    else
      <<magic, ver_type, _resp_ts::32, token::binary-size(16), psm::16>> = payload

      cond do
        magic != @magic -> {:error, :bad_magic}
        ver_type >>> 4 != @wire_version -> {:error, :bad_version}
        (ver_type &&& 0x0F) != @ft_response -> {:error, :bad_frame_type}
        not constant_time_eq?(token, response_token(room_secret, knock_ts, knock_nonce)) -> {:error, :bad_token}
        true -> {:ok, psm}
      end
    end
  end

  # ── Presence beacon (0x12) ──

  @doc "The 15-minute epoch index for a unix-seconds timestamp."
  @spec epoch(non_neg_integer()) :: non_neg_integer()
  def epoch(unix_s) when is_integer(unix_s) and unix_s >= 0, do: div(unix_s, @epoch_seconds)

  @doc """
  The 18-byte contact-resolvable beacon id:
  `HMAC-SHA256(presence_secret, "BRBL-PRES-v1" ‖ magic ‖ ver_type ‖ epoch(u32 BE))[0..18]`.
  """
  @spec beacon_id(binary(), non_neg_integer()) :: <<_::144>>
  def beacon_id(presence_secret, epoch)
      when is_binary(presence_secret) and is_integer(epoch) and epoch >= 0 do
    prefix = <<@magic, @presence_vt, epoch::32>>
    :crypto.mac(:hmac, :sha256, presence_secret, @label_pres <> prefix)
    |> binary_part(0, @beacon_id_bytes)
  end

  @doc "Encode a 24-byte presence beacon for `epoch`."
  @spec encode_presence(binary(), non_neg_integer()) :: payload()
  def encode_presence(presence_secret, epoch) do
    <<@magic, @presence_vt, epoch::32>> <> beacon_id(presence_secret, epoch)
  end

  @doc """
  Resolve a presence beacon against held contact secrets `[{id, secret}]`.
  Accepts the carried epoch within ±1 of `now_s`'s epoch. Returns `{:ok, id}`
  for the first matching contact, else `:unknown`.
  """
  @spec resolve_presence(binary(), [{term(), binary()}], integer()) :: {:ok, term()} | :unknown
  def resolve_presence(payload, contacts, now_s)
      when is_binary(payload) and is_list(contacts) and is_integer(now_s) do
    with true <- byte_size(payload) == @payload_bytes,
         <<@magic, ver_type, ep::32, beacon::binary-size(18)>> <- payload,
         true <- ver_type >>> 4 == @wire_version,
         true <- (ver_type &&& 0x0F) == @ft_presence,
         true <- abs(epoch(now_s) - ep) <= 1 do
      Enum.find_value(contacts, :unknown, fn {id, secret} ->
        if constant_time_eq?(beacon, beacon_id(secret, ep)), do: {:ok, id}
      end)
    else
      _ -> :unknown
    end
  end

  # ── Replay ledger (mirrors Burble.Bolt.Spa) ──

  @doc "Create the one-shot nonce ETS table. Idempotent."
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

  defp record_nonce(nonce, ts, now_s) do
    init_replay_table()
    prune(now_s)
    expiry = ts + @window_s

    case :ets.lookup(@nonce_table, nonce) do
      [{^nonce, exp}] when exp >= now_s ->
        {:error, :replayed_nonce}

      _ ->
        :ets.insert(@nonce_table, {nonce, expiry})
        :ok
    end
  end

  defp prune(now_s) do
    :ets.select_delete(@nonce_table, [{{:_, :"$1"}, [{:<, :"$1", now_s}], [true]}])
  end

  # ── Helpers ──

  defp within_window?(ts, now_s), do: abs(now_s - ts) <= @window_s

  defp constant_time_eq?(a, b) when byte_size(a) == byte_size(b), do: :crypto.hash_equals(a, b)
  defp constant_time_eq?(_, _), do: false
end
