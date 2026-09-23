# SPDX-License-Identifier: MPL-2.0
defmodule Burble.GrooveVoiceAdapterTest do
  use ExUnit.Case, async: false
  import Plug.Test
  alias Burble.{Groove, GrooveVoice}
  alias Burble.Protocol.VoiceSignal

  setup do
    room = "voice-" <> Integer.to_string(System.unique_integer([:positive]))
    for id <- ["alice", "bob", "mallory"], do: Burble.Rooms.RoomManager.join_room(room, id, id)

    tokens =
      Map.new(["alice", "bob", "mallory"], fn id ->
        {:ok, token, _} = Burble.Auth.Guardian.create_guest_token(%{id: id, display_name: id})
        {id, token}
      end)

    on_exit(fn ->
      :sys.replace_state(Groove, fn state -> %{state | connections: %{}} end)
      for id <- Map.keys(tokens), do: Burble.Rooms.Room.leave(room, id)
    end)

    %{room: room, tokens: tokens}
  end

  defp request(action, token, handle \\ "", peer \\ "bob", body \\ "") do
    method = if action in ["recv", "heartbeat"], do: :get, else: :post

    conn(method, "/.well-known/groove/voice/" <> action, body)
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> Plug.Conn.put_req_header("x-groove-handle", handle)
    |> Plug.Conn.put_req_header("x-groove-peer", peer)
    |> Plug.Conn.put_req_header(
      "content-type",
      if(action == "connect", do: "application/json", else: "application/octet-stream")
    )
    |> BurbleWeb.Plugs.GrooveVoicePlug.call([])
  end

  defp connect(ctx, mode \\ "hard", who \\ "alice", peer \\ "bob") do
    response =
      request(
        "connect",
        ctx.tokens[who],
        "",
        peer,
        Jason.encode!(%{room_id: ctx.room, peer_id: peer, lease: %{mode: mode, ttl_ms: 60_000}})
      )

    assert response.status == 200
    Jason.decode!(response.resp_body)["handle"]
  end

  defp frame(room, who \\ "alice", tag \\ :offer) do
    VoiceSignal.encode(
      {tag,
       %{room_id: room, user_id: who, sdp: %{sdp: "v=0\r\ns=voice\r\n", media_type: "audio"}}}
    )
  end

  test "valid scoped SDP reaches the real signaling topic in Bebop", ctx do
    h = connect(ctx)
    Phoenix.PubSub.subscribe(Burble.PubSub, GrooveVoice.peer_topic(ctx.room, "bob"))
    assert request("send", ctx.tokens["alice"], h, "bob", frame(ctx.room)).status == 204
    assert_receive {:signaling_msg, %{enc: "bebop", sdp_b64: bytes}}

    assert {%{sdp: "v=0\r\ns=voice\r\n"}, ""} =
             VoiceSignal.decode_sdp_payload(Base.decode64!(bytes))

    assert request("heartbeat", ctx.tokens["alice"], h).status == 204
    assert request("disconnect", ctx.tokens["alice"], h).status == 204
    assert request("heartbeat", ctx.tokens["alice"], h).status == 410
  end

  test "identity, peer and room are bound, with a valid-send positive control", ctx do
    h = connect(ctx)
    assert request("send", ctx.tokens["mallory"], h, "bob", frame(ctx.room)).status == 403
    assert request("send", ctx.tokens["alice"], h, "mallory", frame(ctx.room)).status == 403
    assert request("send", ctx.tokens["alice"], h, "bob", frame("other-room")).status == 403

    assert request("send", ctx.tokens["alice"], h, "bob", frame(ctx.room, "mallory")).status ==
             403

    assert request("send", ctx.tokens["alice"], "forged", "bob", frame(ctx.room)).status == 410
    assert request("send", ctx.tokens["alice"], h, "bob", frame(ctx.room)).status == 204
  end

  test "refresh and invalid JWTs do not authenticate; connect never creates membership", ctx do
    {:ok, refresh, _} =
      Burble.Auth.Guardian.create_refresh_token(%{id: "alice", display_name: "Alice"})

    for token <- [refresh, "not-a-jwt"] do
      assert request("connect", token).status == 401
    end

    body =
      Jason.encode!(%{room_id: "not-a-room", peer_id: "bob", lease: %{mode: "soft", ttl_ms: 1000}})

    assert request("connect", ctx.tokens["alice"], "", "bob", body).status == 403
    assert {:error, :room_not_found} == Burble.Rooms.Room.get_state("not-a-room")
    assert is_binary(connect(ctx))
  end

  test "malformed, trailing, oversized and non-signaling union variants fail closed", ctx do
    h = connect(ctx)

    for bytes <- [<<>>, <<9, 255>>, frame(ctx.room) <> <<0>>, :binary.copy(<<9>>, 16_385), <<99>>] do
      assert request("send", ctx.tokens["alice"], h, "bob", bytes).status == 400
    end

    assert request("send", ctx.tokens["alice"], h, "bob", frame(ctx.room)).status == 204
  end

  test "room departure blocks send, receive and renewal", ctx do
    h = connect(ctx)
    assert request("send", ctx.tokens["alice"], h, "bob", frame(ctx.room)).status == 204
    Burble.Rooms.Room.leave(ctx.room, "bob")

    for action <- ["send", "recv", "heartbeat"] do
      assert request(action, ctx.tokens["alice"], h, "bob", frame(ctx.room)).status == 403
    end
  end

  test "generic API cannot renew, disconnect or consume the scoped inbox", ctx do
    h = connect(ctx)
    assert {:error, :not_found} == Groove.heartbeat(h)
    assert {:error, :not_found} == Groove.disconnect(h)
    assert Groove.pop_messages() == []
    assert request("heartbeat", ctx.tokens["alice"], h).status == 204
  end

  test "same peer in another signaling room cannot observe this room's frame", ctx do
    h = connect(ctx)
    Phoenix.PubSub.subscribe(Burble.PubSub, GrooveVoice.peer_topic("another-room", "bob"))
    assert request("send", ctx.tokens["alice"], h, "bob", frame(ctx.room)).status == 204
    refute_receive {:signaling_msg, _}, 30
    Phoenix.PubSub.subscribe(Burble.PubSub, GrooveVoice.peer_topic(ctx.room, "bob"))
    assert request("send", ctx.tokens["alice"], h, "bob", frame(ctx.room)).status == 204
    assert_receive {:signaling_msg, %{from: "alice"}}
    refute GrooveVoice.peer_topic("a:b", "c") == GrooveVoice.peer_topic("a", "b:c")
  end

  test "delayed delivery cannot enter a later lease generation", ctx do
    old_epoch = System.unique_integer([:monotonic, :positive])
    h = connect(ctx)
    bytes = frame(ctx.room, "bob", :answer)
    send(Groove, {:voice_delivery, ctx.room, "bob", "alice", old_epoch, bytes})
    assert request("recv", ctx.tokens["alice"], h).status == 204
    current_epoch = System.unique_integer([:monotonic, :positive])
    send(Groove, {:voice_delivery, ctx.room, "bob", "alice", current_epoch, bytes})
    assert request("recv", ctx.tokens["alice"], h).resp_body == bytes
    assert request("disconnect", ctx.tokens["alice"], h).status == 204
    replacement = connect(ctx)
    send(Groove, {:voice_delivery, ctx.room, "bob", "alice", current_epoch, bytes})
    assert request("recv", ctx.tokens["alice"], replacement).status == 204
  end

  test "reverse WebSocket bridge rejects expired or absent authority", ctx do
    h = connect(ctx)
    {:ok, auth} = GrooveVoice.authenticate(ctx.tokens["bob"])
    payload = %{type: "sdp:answer", from: "bob", sdp: "v=0\r\ns=voice\r\n", mediaType: "audio"}

    assert {:error, :unauthorized} ==
             GrooveVoice.from_channel(ctx.room, "bob", "alice", payload, nil)

    expired = %{auth | expires: System.system_time(:second) - 1}

    assert {:error, :unauthorized} ==
             GrooveVoice.from_channel(ctx.room, "bob", "alice", payload, expired)

    assert request("recv", ctx.tokens["alice"], h).status == 204
    assert :ok == GrooveVoice.from_channel(ctx.room, "bob", "alice", payload, auth)
    assert request("recv", ctx.tokens["alice"], h).resp_body == frame(ctx.room, "bob", :answer)
  end

  @tag timeout: 15_000
  test "delayed room or provider operation cannot route after its caller deadline", ctx do
    h = connect(ctx)
    [{room_pid, _}] = Registry.lookup(Burble.RoomRegistry, ctx.room)
    Phoenix.PubSub.subscribe(Burble.PubSub, GrooveVoice.peer_topic(ctx.room, "bob"))

    for {pid, delay} <- [{room_pid, 4_100}, {Process.whereis(Groove), 5_100}] do
      :sys.suspend(pid)
      task = Task.async(fn -> request("send", ctx.tokens["alice"], h, "bob", frame(ctx.room)) end)

      try do
        # Exercise both a late room turn and a provider turn that only runs
        # AFTER the caller's timeout. Neither may publish the queued frame.
        Process.sleep(delay)
      after
        :sys.resume(pid)
      end

      assert Task.await(task).status == 410
      refute_receive {:signaling_msg, _}, 30
      assert request("send", ctx.tokens["alice"], h, "bob", frame(ctx.room)).status == 204
      assert_receive {:signaling_msg, _}
    end
  end

  test "both lease postures produce identical data bytes; expiry wipes bounded inbox", ctx do
    for mode <- ["soft", "hard"] do
      h = connect(ctx, mode)
      peer = connect(ctx, mode, "bob", "alice")
      bytes = frame(ctx.room, "bob", :answer)

      for _ <- 1..6,
          do: assert(request("send", ctx.tokens["bob"], peer, "alice", bytes).status == 204)

      for _ <- 1..4 do
        response = request("recv", ctx.tokens["alice"], h)
        assert response.status == 200
        assert response.resp_body == bytes
      end

      assert request("recv", ctx.tokens["alice"], h).status == 204

      :sys.replace_state(Groove, fn state ->
        put_in(
          state,
          [:connections, h, :lease_expires_at],
          System.monotonic_time(:millisecond) - 180_000
        )
      end)

      assert request("heartbeat", ctx.tokens["alice"], h).status == 410
      assert request("recv", ctx.tokens["alice"], h).status == 410
      refute Map.has_key?(Groove.connection_status(), h)
      assert request("disconnect", ctx.tokens["bob"], peer, "alice").status == 204
    end
  end
end
