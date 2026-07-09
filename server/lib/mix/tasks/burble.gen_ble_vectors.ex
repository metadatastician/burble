# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

defmodule Mix.Tasks.Burble.GenBleVectors do
  @shortdoc "Regenerate the BLE presence wire-format v1 test vectors (ADR-0015)"
  @moduledoc """
  Regenerates `.machine_readable/test-vectors/ble-spa-v1.json` from the
  canonical reference implementation `Burble.Presence.BleSpa`.

  The vectors are the machine-checkable freeze of the BLE wire format
  (ADR-0015): `test/burble/presence/ble_spa_vectors_test.exs` recomputes every
  row from `BleSpa` and fails CI on any byte drift. neurophone (and any other
  consumer) pins against this JSON.

  All inputs are fixed, obviously-non-production constants, so the output is
  deterministic. Run: `mix burble.gen_ble_vectors`.
  """
  use Mix.Task

  alias Burble.Presence.BleSpa

  @out "../.machine_readable/test-vectors/ble-spa-v1.json"

  # Fixed inputs (MUST match the committed vectors + the ble_spa_vectors_test).
  @base 1_767_225_600
  @inv_a "test-invite-room-alpha"
  @inv_b "test-invite-room-bravo"
  @ps_c Base.decode16!("00112233445566778899AABBCCDDEEFF0102030405060708090A0B0C0D0E0F10")

  @impl true
  def run(_args) do
    data = build()
    path = Path.expand(@out, File.cwd!())
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(data, pretty: true) <> "\n")
    Mix.shell().info("Wrote #{path}")
  end

  @doc false
  def build do
    rs_a = BleSpa.derive_room_secret(@inv_a)
    rs_b = BleSpa.derive_room_secret(@inv_b)
    valid = BleSpa.encode_knock(rs_a, @base, nonce("0102030405ff"))

    %{
      "spec" => "burble-ble-spa",
      "wire_version" => 1,
      "spec_version" => "1.0.0",
      "adr" => "docs/decisions/0015-ble-presence-wire-format-v1.adoc",
      "reference_impl" => "server/lib/burble/presence/ble_spa.ex",
      "generated_by" => "mix burble.gen_ble_vectors",
      "note" =>
        "Fixed non-production secrets. Any drift in these bytes is a v2 wire break (ADR-0015 D7).",
      "room_secret_derivation" => [
        %{"name" => "alpha", "invite_token" => @inv_a, "room_secret_hex" => hx(rs_a)},
        %{"name" => "bravo", "invite_token" => @inv_b, "room_secret_hex" => hx(rs_b)}
      ],
      "knock" => [
        knock_row("alpha_basic", rs_a, @base, "0102030405ff"),
        knock_row("alpha_offset", rs_a, @base + 900, "aabbccddeeff"),
        knock_row("bravo_basic", rs_b, @base + 7200, "101112131415")
      ],
      "knock_negative" => [
        neg("tampered_mac", flip_last(valid), rs_a, @base + 5, "bad_mac"),
        neg("wrong_secret", valid, rs_b, @base + 5, "bad_mac"),
        neg("bad_magic", set_byte(valid, 0, 0x43), rs_a, @base + 5, "bad_magic"),
        neg("bad_version", set_byte(valid, 1, 0x21), rs_a, @base + 5, "bad_version"),
        neg("bad_frame_type", set_byte(valid, 1, 0x12), rs_a, @base + 5, "bad_frame_type"),
        neg("stale_plus_31s", valid, rs_a, @base + 31, "stale_timestamp"),
        neg("stale_minus_31s", valid, rs_a, @base - 31, "stale_timestamp"),
        neg("truncated", binary_part(valid, 0, 23), rs_a, @base + 5, "bad_length")
      ],
      "response" => [
        resp_row("alpha_psm0", rs_a, @base, "0102030405ff", @base + 2, 0),
        resp_row("alpha_psm129", rs_a, @base, "0102030405ff", @base + 2, 129),
        resp_row("bravo_psm4097", rs_b, @base + 7200, "101112131415", @base + 7203, 4097)
      ],
      "presence" => [
        pres_row("contact_c_epoch0", @ps_c, @base),
        pres_row("contact_c_next", @ps_c, @base + 900),
        pres_row("contact_c_later", @ps_c, @base + 123_456)
      ]
    }
  end

  # ── row builders ──

  defp knock_row(name, rs, ts, nonce_hex) do
    payload = BleSpa.encode_knock(rs, ts, nonce(nonce_hex))

    %{
      "name" => name,
      "room_secret_hex" => hx(rs),
      "ts" => ts,
      "nonce_hex" => nonce_hex,
      "payload_hex" => hx(payload),
      "verify" => %{"now" => ts + 5, "result" => "ok"}
    }
  end

  defp neg(name, payload, rs, now, result) do
    %{
      "name" => name,
      "payload_hex" => hx(payload),
      "room_secret_hex" => hx(rs),
      "now" => now,
      "result" => result
    }
  end

  defp resp_row(name, rs, kts, kn_hex, rts, psm) do
    kn = nonce(kn_hex)
    payload = BleSpa.encode_response(rs, kts, kn, rts, psm)

    %{
      "name" => name,
      "room_secret_hex" => hx(rs),
      "knock_ts" => kts,
      "knock_nonce_hex" => kn_hex,
      "resp_ts" => rts,
      "psm" => psm,
      "token_hex" => hx(BleSpa.response_token(rs, kts, kn)),
      "payload_hex" => hx(payload),
      "match" => %{"now" => rts + 1, "result_psm" => psm}
    }
  end

  defp pres_row(name, ps, unix_s) do
    ep = BleSpa.epoch(unix_s)
    payload = BleSpa.encode_presence(ps, ep)

    %{
      "name" => name,
      "presence_secret_hex" => hx(ps),
      "unix_s" => unix_s,
      "epoch" => ep,
      "beacon_id_hex" => hx(BleSpa.beacon_id(ps, ep)),
      "payload_hex" => hx(payload),
      "resolve" => %{"now" => unix_s, "contact_id" => "contact-c", "result" => "ok"}
    }
  end

  # ── helpers ──

  defp nonce(hex), do: Base.decode16!(hex, case: :mixed)
  defp hx(bin), do: Base.encode16(bin, case: :lower)
  defp set_byte(bin, i, b),
    do: binary_part(bin, 0, i) <> <<b>> <> binary_part(bin, i + 1, byte_size(bin) - i - 1)

  defp flip_last(bin) do
    last = Bitwise.bxor(:binary.last(bin), 0x01)
    binary_part(bin, 0, byte_size(bin) - 1) <> <<last>>
  end
end
