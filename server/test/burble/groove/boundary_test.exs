# SPDX-License-Identifier: MPL-2.0
defmodule Burble.GrooveBoundaryTest do
  use ExUnit.Case, async: false
  import Plug.Test
  alias Burble.Groove
  alias BurbleWeb.Plugs.GroovePlug

  setup do
    for {handle, _} <- Groove.connection_status(), do: Groove.disconnect(handle)
    Groove.pop_messages()
    :ok
  end

  defp peer(mode \\ "hard") do
    %{
      "service_id" => "boundary-peer",
      "consumes" => ["voice"],
      "lease" => %{"mode" => mode, "ttl_ms" => 60_000}
    }
  end

  defp request(method, path, body \\ nil) do
    conn(method, "/.well-known/groove" <> path, body && Jason.encode!(body))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> GroovePlug.call([])
  end

  test "canonical handle connects and disconnects, then returns Gone" do
    response = request(:post, "/connect", peer())
    assert response.status == 200
    body = Jason.decode!(response.resp_body)
    assert is_binary(body["handle"])
    assert body["handle"] == body["session_id"]
    assert body["lease"] == peer()["lease"]
    assert request(:post, "/disconnect", %{"handle" => body["handle"]}).status == 200
    assert request(:post, "/disconnect", %{"handle" => body["handle"]}).status == 410
  end

  test "status never discloses a bearer, with a real live-session positive control" do
    {:ok, handle, _} = Groove.connect(peer())
    response = request(:get, "/status")
    status = Jason.decode!(response.resp_body)
    assert map_size(status) == 1
    assert hd(Map.values(status))["peer_id"] == "boundary-peer"
    refute String.contains?(response.resp_body, handle)
  end

  test "elapsed hard lease cannot be resurrected before the sweep" do
    {:ok, handle, _} = Groove.connect(peer())
    assert :ok == Groove.heartbeat(handle)

    :sys.replace_state(Groove, fn state ->
      put_in(
        state,
        [:connections, handle, :lease_expires_at],
        System.monotonic_time(:millisecond) - 120_000
      )
    end)

    assert {:error, :not_found} == Groove.heartbeat(handle)
    refute Map.has_key?(Groove.connection_status(), handle)
  end

  test "disconnect wipes its queue but preserves unrelated messages" do
    {:ok, handle, _} = Groove.connect(peer("soft"))
    Groove.push_message(%{"session_id" => handle, "body" => "erase"})
    Groove.push_message(%{"from" => "unrelated", "body" => "keep"})
    assert :ok == Groove.disconnect(handle)
    assert Groove.pop_messages() == [%{"from" => "unrelated", "body" => "keep"}]
  end

  test "malformed manifests reject without crashing the server" do
    original = Process.whereis(Groove)

    for consumes <- ["voice", 17, nil, [%{"type" => "voice"}]] do
      assert {:error, _} = Groove.connect(Map.put(peer(), "consumes", consumes))
      assert Process.whereis(Groove) == original
    end

    assert {:ok, handle, _} = Groove.connect(peer())
    Groove.disconnect(handle)
  end

  test "invalid lease is 400 and conflicting token aliases are rejected" do
    assert request(
             :post,
             "/connect",
             Map.put(peer(), "lease", %{"mode" => "hard", "ttl_ms" => 0})
           ).status == 400

    {:ok, handle, _} = Groove.connect(peer())

    assert request(:post, "/disconnect", %{"handle" => handle, "session_id" => "forged"}).status ==
             400

    assert :ok == Groove.heartbeat(handle)
    Groove.disconnect(handle)
  end

  test "every requested capability must match and scalar JSON is rejected" do
    assert {:error, _} = Groove.connect(Map.put(peer(), "consumes", ["voice", "unavailable"]))

    for scalar <- [[], "voice", 17, nil] do
      assert request(:post, "/connect", scalar).status == 400
    end

    assert request(:get, "/heartbeat").status == 204
  end

  test "disconnect cannot wipe another explicit session sharing the same service id" do
    {:ok, first, _} = Groove.connect(peer())
    {:ok, second, _} = Groove.connect(peer())
    Groove.push_message(%{"session_id" => first, "from" => "boundary-peer"})
    keep = %{"session_id" => second, "from" => "boundary-peer"}
    Groove.push_message(keep)
    Groove.disconnect(first)
    assert Groove.pop_messages() == [keep]
    assert :ok == Groove.heartbeat(second)
    Groove.disconnect(second)
  end
end
