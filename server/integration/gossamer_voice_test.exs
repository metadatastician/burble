# SPDX-License-Identifier: MPL-2.0
defmodule Burble.GossamerVoiceTest do
  use ExUnit.Case, async: false
  alias Burble.Protocol.VoiceSignal

  @tag timeout: 35_000
  test "real native voice adapter exchanges Bebop with authenticated WebSocket peer" do
    driver = System.fetch_env!("GOSSAMER_VOICE_DRIVER")
    assert File.regular?(driver)
    assert Burble.Groove.connection_status() == %{}
    start_supervised!({Bandit, plug: BurbleWeb.Endpoint, ip: {127, 0, 0, 1}, port: 6473})
    room = "native-voice-room"

    for id <- ["alice", "bob"],
        do: assert({:ok, _} = Burble.Rooms.RoomManager.join_room(room, id, id))

    on_exit(fn -> for id <- ["alice", "bob"], do: Burble.Rooms.Room.leave(room, id) end)

    token = fn id ->
      {:ok, value, _} = Burble.Auth.Guardian.create_guest_token(%{id: id, display_name: id})
      value
    end

    {:ok, refresh, _} =
      Burble.Auth.Guardian.create_refresh_token(%{id: "alice", display_name: "alice"})

    sdp = %{sdp: "v=0\r\ns=offer\r\n", media_type: "audio"}
    offer = {:offer, %{room_id: room, user_id: "alice", sdp: sdp}}

    answer =
      {:answer,
       %{room_id: room, user_id: "bob", sdp: %{sdp: "v=0\r\ns=answer\r\n", media_type: "audio"}}}

    ice = fn who ->
      {:ice_candidate,
       %{
         room_id: room,
         user_id: who,
         candidate: %{
           candidate: "candidate:" <> who,
           sdp_m_line_index: 0,
           sdp_mid: "audio",
           username_fragment: "ufrag"
         }
       }}
    end

    hex = fn signal -> Base.encode16(VoiceSignal.encode(signal), case: :lower) end

    env = [
      {"VOICE_ROOM", room},
      {"VOICE_ALICE_TOKEN", token.("alice")},
      {"VOICE_BOB_TOKEN", token.("bob")},
      {"VOICE_REFRESH_TOKEN", refresh},
      {"VOICE_SDP_B64", Base.encode64(VoiceSignal.encode_sdp_payload(sdp))},
      {"VOICE_OFFER", hex.(offer)},
      {"VOICE_ANSWER", hex.(answer)},
      {"VOICE_ICE", hex.(ice.("alice"))},
      {"VOICE_PEER_ICE", hex.(ice.("bob"))},
      {"VOICE_BAD_ROOM", hex.({:offer, %{room_id: "wrong-room", user_id: "alice", sdp: sdp}})}
    ]

    {output, code} =
      System.cmd("bun", ["integration/gossamer_voice_peer.mjs"], env: env, stderr_to_stdout: true)

    # Never expose credentials even if a dependency unexpectedly echoes them.
    redacted =
      Enum.reduce(
        Enum.filter(env, fn {key, _} -> String.ends_with?(key, "TOKEN") end),
        output,
        fn {_, secret}, acc -> String.replace(acc, secret, "[REDACTED]") end
      )

    assert code == 0, redacted
    IO.puts(redacted)
    assert String.contains?(redacted, "PASS real WebSocket Bebop delivery")
    assert Burble.Groove.connection_status() == %{}
  end
end
