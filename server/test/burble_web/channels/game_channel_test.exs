# SPDX-License-Identifier: MPL-2.0
#
# BurbleWeb.GameChannel — join/announce tests, ported from IDApTIK's
# session_channel_test.exs (the parity source, per the fabric spec) and
# extended for the multi-game platform shape (join names its game).
#
# async: false — shares the named endpoint/PubSub with the other channel
# suites, mirroring room_channel_text_test.exs.
defmodule BurbleWeb.Channels.GameChannelTest do
  use ExUnit.Case, async: false
  use Phoenix.ChannelTest

  import Burble.TestHelpers

  alias BurbleWeb.GameChannel

  @endpoint BurbleWeb.Endpoint

  setup do
    Application.ensure_all_started(:phoenix_pubsub)
    ensure_started({Phoenix.PubSub, name: Burble.PubSub})

    case BurbleWeb.Endpoint.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  defp game_socket do
    socket(BurbleWeb.UserSocket, nil, %{
      user_id: "test-user-#{System.unique_integer([:positive])}",
      display_name: "TestSeat",
      is_guest: true,
      # Actual transport-origin and scoped admission checks are tested separately.
      legacy_game_local: true
    })
  end

  defp join!(session, role, game \\ "idaptik") do
    {:ok, reply, socket} =
      game_socket()
      |> subscribe_and_join(GameChannel, "game:" <> session, %{
        "role" => role,
        "game" => game
      })

    {reply, socket}
  end

  # The cross-language wire fixtures are vendored VERBATIM from the IDApTIK
  # repo (fixtures/session_relay/*.json), where the Rust side round-trips
  # the same files (crates/idaptik-core/tests/session_relay_fixture.rs).
  # If they drift, slice 2's Rust-vs-burble parity run will say so.
  @fixtures Path.expand("../../fixtures/game_session/idaptik", __DIR__)

  defp fixture!(name) do
    @fixtures |> Path.join(name) |> File.read!() |> Jason.decode!()
  end

  describe "join" do
    test "accepts each role and announces it to the peer" do
      {reply, _infil} = join!("j1", "infiltrator")
      assert reply == %{role: "infiltrator", game: "idaptik", protocol: "legacy-json-v1"}

      {reply, _hacker} = join!("j1", "hacker")
      assert reply == %{role: "hacker", game: "idaptik", protocol: "legacy-json-v1"}
      assert_broadcast "peer_joined", %{"role" => "hacker"}
    end

    test "rejects a join without a role" do
      assert {:error, %{reason: reason}} =
               game_socket()
               |> subscribe_and_join(GameChannel, "game:j2", %{"game" => "idaptik"})

      assert reason =~ "role"
    end

    test "rejects a role the game does not declare" do
      assert {:error, %{reason: reason}} =
               game_socket()
               |> subscribe_and_join(GameChannel, "game:j3", %{
                 "role" => "billy",
                 "game" => "idaptik"
               })

      assert reason =~ "role"
    end

    test "rejects an unknown game" do
      assert {:error, %{reason: reason}} =
               game_socket()
               |> subscribe_and_join(GameChannel, "game:j4", %{
                 "role" => "infiltrator",
                 "game" => "pong"
               })

      assert reason =~ "unknown game"
    end

    test "rejects a join without a game" do
      assert {:error, %{reason: reason}} =
               game_socket()
               |> subscribe_and_join(GameChannel, "game:j5", %{"role" => "hacker"})

      assert reason =~ "game"
    end

    test "rejects a non-binary role, naming the field" do
      assert {:error, %{reason: reason}} =
               game_socket()
               |> subscribe_and_join(GameChannel, "game:j6b", %{
                 "role" => 7,
                 "game" => "idaptik"
               })

      assert reason =~ "role"
    end

    test "rejects a non-binary game, naming the field" do
      assert {:error, %{reason: reason}} =
               game_socket()
               |> subscribe_and_join(GameChannel, "game:j6c", %{
                 "role" => "hacker",
                 "game" => 7
               })

      assert reason =~ "game"
    end

    test "a leaving peer is announced" do
      {_reply, infil} = join!("j6", "infiltrator")
      {_reply, _hacker} = join!("j6", "hacker")
      assert_broadcast "peer_joined", %{"role" => "hacker"}

      Process.unlink(infil.channel_pid)
      leave(infil)
      assert_broadcast "peer_left", %{"role" => "infiltrator"}
    end
  end

  describe "ping" do
    test "answers pong" do
      {_reply, socket} = join!("p1", "hacker")
      ref = push(socket, "ping", %{})
      assert_reply ref, :ok, %{"pong" => true}
    end
  end

  describe "unknown messages" do
    test "an unrecognized push is refused, not a crash" do
      {_reply, socket} = join!("u1", "hacker")
      ref = push(socket, "intent", %{"move" => "left"})
      assert_reply ref, :error, %{"reason" => reason}
      assert reason =~ "unknown message"
      # The channel survives: ping still answers.
      ref = push(socket, "ping", %{})
      assert_reply ref, :ok, %{"pong" => true}
    end
  end

  describe "command relay" do
    test "delivers a hacker Pivot to the infiltrator verbatim" do
      {_reply, _infil} = join!("c1", "infiltrator")
      {_reply, hacker} = join!("c1", "hacker")

      payload = %{"cmd" => "Pivot", "target" => "Bridge"}
      ref = push(hacker, "command", payload)
      assert_reply ref, :ok, %{"relayed" => true}
      assert_push "command", ^payload
    end

    test "delivers the hacker's Net View verbs (absent from the old IDApTIK table)" do
      {_reply, _infil} = join!("c2", "infiltrator")
      {_reply, hacker} = join!("c2", "hacker")

      for payload <- [
            %{"cmd" => "NetSsh", "node" => 0},
            %{"cmd" => "NetHack", "node" => 3}
          ] do
        ref = push(hacker, "command", payload)
        assert_reply ref, :ok, %{"relayed" => true}
        assert_push "command", ^payload
      end
    end

    test "delivers infiltrator body verbs to the hacker verbatim" do
      {_reply, infil} = join!("c3", "infiltrator")

      payload = %{"cmd" => "SetButton", "button" => "Right", "down" => true}
      ref = push(infil, "command", payload)
      assert_reply ref, :ok, %{"relayed" => true}
      assert_broadcast "command", ^payload
    end

    test "either seat may send session immediates" do
      {_reply, infil} = join!("c4", "infiltrator")
      {_reply, hacker} = join!("c4", "hacker")

      for {sender, payload} <- [
            {infil, %{"cmd" => "Pause", "on" => true}},
            {hacker, %{"cmd" => "Restart"}},
            {infil, %{"cmd" => "ForceExtract", "method" => "ServiceExit"}}
          ] do
        ref = push(sender, "command", payload)
        assert_reply ref, :ok, %{"relayed" => true}
        assert_broadcast "command", ^payload
      end
    end
  end

  describe "role enforcement" do
    test "the infiltrator cannot pivot" do
      {_reply, infil} = join!("r1", "infiltrator")

      ref = push(infil, "command", %{"cmd" => "Pivot", "target" => "GridJump"})
      assert_reply ref, :error, %{"reason" => reason}
      assert reason =~ "hacker"
      refute_broadcast "command", _
    end

    test "the hacker has no body" do
      {_reply, hacker} = join!("r2", "hacker")

      for payload <- [
            %{"cmd" => "Jump"},
            %{"cmd" => "Interact"},
            %{"cmd" => "ThrowUsb"},
            %{"cmd" => "SetButton", "button" => "Left", "down" => true}
          ] do
        ref = push(hacker, "command", payload)
        assert_reply ref, :error, %{"reason" => reason}
        assert reason =~ "infiltrator"
      end

      refute_broadcast "command", _
    end

    test "an unknown or untagged command is refused, not relayed" do
      {_reply, hacker} = join!("r3", "hacker")

      ref = push(hacker, "command", %{"cmd" => "BecomeAdmin"})
      assert_reply ref, :error, %{"reason" => reason}
      assert reason =~ "unknown command"

      ref = push(hacker, "command", %{"target" => "Bridge"})
      assert_reply ref, :error, %{"reason" => reason2}
      assert reason2 =~ "cmd"

      ref = push(hacker, "command", "not-a-map")
      assert_reply ref, :error, %{"reason" => reason3}
      assert reason3 =~ "object"

      refute_broadcast "command", _
    end
  end

  describe "sequence handling" do
    test "a duplicate command is acknowledged but dropped, and seq is stripped" do
      {_reply, hacker} = join!("s1", "hacker")
      payload = %{"cmd" => "Unpivot", "seq" => 7}

      ref = push(hacker, "command", payload)
      assert_reply ref, :ok, %{"relayed" => true}
      assert_broadcast "command", %{"cmd" => "Unpivot"} = relayed
      refute Map.has_key?(relayed, "seq")

      ref = push(hacker, "command", payload)
      assert_reply ref, :ok, %{"relayed" => false, "reason" => "stale_or_duplicate"}
      refute_broadcast "command", _
    end

    test "an out-of-order command is acknowledged but dropped" do
      {_reply, hacker} = join!("s2", "hacker")

      ref = push(hacker, "command", %{"cmd" => "Pivot", "target" => "IspOps", "seq" => 5})
      assert_reply ref, :ok, %{"relayed" => true}
      assert_broadcast "command", %{"cmd" => "Pivot"}

      ref = push(hacker, "command", %{"cmd" => "Unpivot", "seq" => 3})
      assert_reply ref, :ok, %{"relayed" => false}
      refute_broadcast "command", _
    end

    test "each seat's sequence is independent" do
      {_reply, infil} = join!("s3", "infiltrator")
      {_reply, hacker} = join!("s3", "hacker")

      ref = push(hacker, "command", %{"cmd" => "Unpivot", "seq" => 9})
      assert_reply ref, :ok, %{"relayed" => true}

      ref = push(infil, "command", %{"cmd" => "Jump", "seq" => 1})
      assert_reply ref, :ok, %{"relayed" => true}
    end
  end

  describe "event relay" do
    test "delivers a typed Event to the other seat verbatim" do
      {_reply, _infil} = join!("e1", "infiltrator")
      {_reply, hacker} = join!("e1", "hacker")

      payload = %{"event" => "PivotOpened", "host" => "ops.isp.net", "hops" => 1}
      ref = push(hacker, "event", payload)
      assert_reply ref, :ok, %{"relayed" => true}
      assert_push "event", ^payload
    end

    test "an untagged event is refused" do
      {_reply, hacker} = join!("e2", "hacker")

      ref = push(hacker, "event", %{"hops" => 1})
      assert_reply ref, :error, %{"reason" => reason}
      assert reason =~ "event"
      refute_broadcast "event", _
    end
  end

  describe "cross-language fixture pass-through" do
    test "every fixture Command relays byte-preserving from its allowed seat" do
      {_reply, infil} = join!("f1", "infiltrator")
      {_reply, hacker} = join!("f1", "hacker")
      assert_broadcast "peer_joined", %{"role" => "hacker"}

      for command <- fixture!("commands.json") do
        sender =
          case Burble.Games.sender_for(Burble.Games.Idaptik, command["cmd"]) do
            "infiltrator" -> infil
            "hacker" -> hacker
            :either -> hacker
          end

        ref = push(sender, "command", command)
        assert_reply ref, :ok, %{"relayed" => true}
        assert_broadcast "command", ^command
      end
    end

    test "every captured Event relays byte-preserving" do
      {_reply, _infil} = join!("f2", "infiltrator")
      {_reply, hacker} = join!("f2", "hacker")
      assert_broadcast "peer_joined", %{"role" => "hacker"}

      for event <- fixture!("events.json") do
        ref = push(hacker, "event", event)
        assert_reply ref, :ok, %{"relayed" => true}
        assert_push "event", ^event
      end
    end
  end
end
