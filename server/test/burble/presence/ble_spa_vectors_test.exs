# SPDX-License-Identifier: MPL-2.0
#
# THE FREEZE. This test recomputes every committed BLE wire-format vector from
# Burble.Presence.BleSpa and asserts byte-for-byte agreement. If it fails, the
# on-air format has drifted — which per ADR-0015 D7 requires a superseding ADR,
# a major @version bump, a CHANGELOG "Protocol" entry, and regenerated vectors.
#
# Vectors: .machine_readable/test-vectors/ble-spa-v1.json (regen: mix burble.gen_ble_vectors)

defmodule Burble.Presence.BleSpaVectorsTest do
  use ExUnit.Case, async: true

  alias Burble.Presence.BleSpa

  @vectors_path Path.expand(
                  Path.join([
                    __DIR__,
                    "..",
                    "..",
                    "..",
                    "..",
                    ".machine_readable",
                    "test-vectors",
                    "ble-spa-v1.json"
                  ])
                )

  @covenant "WIRE FREEZE VIOLATED (ADR-0015 D7): committed BLE vectors no longer match " <>
              "Burble.Presence.BleSpa. Changing the wire bytes requires a superseding ADR + " <>
              "major @version bump + CHANGELOG Protocol entry + `mix burble.gen_ble_vectors`."

  setup_all do
    {:ok, vectors: @vectors_path |> File.read!() |> Jason.decode!()}
  end

  defp hx(b), do: Base.encode16(b, case: :lower)
  defp unhex(s), do: Base.decode16!(s, case: :mixed)

  test "spec identity is frozen", %{vectors: v} do
    assert v["spec"] == "burble-ble-spa"
    assert v["wire_version"] == 1
    assert v["spec_version"] == "1.0.0"
  end

  test "room secret derivation matches", %{vectors: v} do
    for row <- v["room_secret_derivation"] do
      assert hx(BleSpa.derive_room_secret(row["invite_token"])) == row["room_secret_hex"], @covenant
    end
  end

  test "knock payloads encode + verify exactly", %{vectors: v} do
    for row <- v["knock"] do
      rs = unhex(row["room_secret_hex"])
      payload = BleSpa.encode_knock(rs, row["ts"], unhex(row["nonce_hex"]))
      assert byte_size(payload) == 24
      assert hx(payload) == row["payload_hex"], @covenant <> " [knock #{row["name"]}]"

      assert BleSpa.verify_knock(unhex(row["payload_hex"]), rs, row["verify"]["now"], check_replay: false) ==
               :ok
    end
  end

  test "knock negatives verify to the frozen error atoms", %{vectors: v} do
    for row <- v["knock_negative"] do
      rs = unhex(row["room_secret_hex"])
      expected = {:error, String.to_atom(row["result"])}

      assert BleSpa.verify_knock(unhex(row["payload_hex"]), rs, row["now"], check_replay: false) ==
               expected,
             "knock_negative[#{row["name"]}] expected #{inspect(expected)}"
    end
  end

  test "response tokens + payloads encode + match exactly", %{vectors: v} do
    for row <- v["response"] do
      rs = unhex(row["room_secret_hex"])
      kn = unhex(row["knock_nonce_hex"])
      assert hx(BleSpa.response_token(rs, row["knock_ts"], kn)) == row["token_hex"], @covenant

      payload = BleSpa.encode_response(rs, row["knock_ts"], kn, row["resp_ts"], row["psm"])
      assert byte_size(payload) == 24
      assert hx(payload) == row["payload_hex"], @covenant <> " [response #{row["name"]}]"

      assert BleSpa.match_response(unhex(row["payload_hex"]), rs, row["knock_ts"], kn, row["match"]["now"]) ==
               {:ok, row["match"]["result_psm"]}
    end
  end

  test "presence beacons encode + resolve exactly", %{vectors: v} do
    for row <- v["presence"] do
      ps = unhex(row["presence_secret_hex"])
      assert BleSpa.epoch(row["unix_s"]) == row["epoch"]
      assert hx(BleSpa.beacon_id(ps, row["epoch"])) == row["beacon_id_hex"], @covenant

      payload = BleSpa.encode_presence(ps, row["epoch"])
      assert byte_size(payload) == 24
      assert hx(payload) == row["payload_hex"], @covenant <> " [presence #{row["name"]}]"

      assert BleSpa.resolve_presence(
               unhex(row["payload_hex"]),
               [{row["resolve"]["contact_id"], ps}],
               row["resolve"]["now"]
             ) == {:ok, row["resolve"]["contact_id"]}
    end
  end
end
