# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
defmodule BurbleWeb.Channels.SessionAdmissionTest do
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest, except: [join: 3, join: 4]
  import ExUnit.CaptureLog

  alias Burble.Auth.Guardian
  alias Burble.Sessions.Admission
  alias BurbleWeb.{GameChannel, UserSocket}

  @endpoint BurbleWeb.Endpoint
  @remote %{peer_data: %{address: {192, 0, 2, 20}}}
  @local %{peer_data: %{address: {127, 0, 0, 1}}}

  setup do
    previous = Application.get_env(:burble, :game_session_mode)
    Application.put_env(:burble, :game_session_mode, :scoped)
    on_exit(fn -> Application.put_env(:burble, :game_session_mode, previous) end)
    :ok
  end

  defp provision(opts \\ []) do
    id = "admission-#{System.unique_integer([:positive])}"

    {:ok, provision} =
      Admission.create(id, "idaptik", %{"infiltrator" => "alice", "hacker" => "bob"}, opts)

    on_exit(fn -> Admission.close(id) end)
    provision
  end

  defp authenticated(subject, type \\ "guest", ttl \\ {1, :hour}) do
    {:ok, token, _claims} =
      Guardian.encode_and_sign(%{id: subject}, %{"gst" => true, "dn" => subject},
        token_type: type,
        ttl: ttl
      )

    {:ok, socket} = connect(UserSocket, %{"token" => token}, connect_info: @remote)
    socket
  end

  defp params(provision, role, changes \\ %{}) do
    %{
      "game" => "idaptik",
      "role" => role,
      "protocol" => Admission.protocol(),
      "epoch" => provision.epoch,
      "ticket" => provision.grants[role].ticket
    }
    |> Map.merge(changes)
  end

  defp join(socket, provision, role, changes \\ %{}) do
    result =
      subscribe_and_join(
        socket,
        GameChannel,
        "game:" <> provision.session_id,
        params(provision, role, changes)
      )

    if match?({:ok, _, _}, result), do: Process.unlink(elem(result, 2).channel_pid)
    result
  end

  defp rejoin(socket, provision, role, token) do
    payload = params(provision, role) |> Map.delete("ticket") |> Map.put("rejoin_token", token)
    result = subscribe_and_join(socket, GameChannel, "game:" <> provision.session_id, payload)
    if match?({:ok, _, _}, result), do: Process.unlink(elem(result, 2).channel_pid)
    result
  end

  test "two authenticated participants exchange typed payloads with acceptance-only receipts" do
    provision = provision()
    {:ok, alice_receipt, alice} = join(authenticated("alice"), provision, "infiltrator")
    {:ok, _bob_receipt, bob} = join(authenticated("bob"), provision, "hacker")

    assert alice_receipt.protocol == "admission-v1"
    assert alice_receipt.participant_id == "alice"
    assert alice_receipt.epoch == provision.epoch
    assert alice_receipt.evidence == "accepted"

    command = %{"cmd" => "Jump", "dx" => 1, "dy" => 0}
    ref = push(alice, "command", Map.put(command, "seq", 1))
    assert_reply(ref, :ok, receipt)
    assert receipt["evidence"] == "accepted"
    assert receipt["epoch"] == provision.epoch
    refute Map.has_key?(receipt, "durable")
    refute Map.has_key?(receipt, "delivered")
    refute Map.has_key?(receipt, "applied")
    assert_push("command", ^command)

    event = %{"event" => "fixture-event", "value" => 7}
    ref = push(bob, "event", event)
    assert_reply(ref, :ok, %{"evidence" => "accepted"})
    assert_push("event", ^event)
  end

  test "acceptance with no peer does not assert delivery" do
    provision = provision()
    {:ok, _, alice} = join(authenticated("alice"), provision, "infiltrator")
    ref = push(alice, "command", %{"cmd" => "Jump", "seq" => 1})
    assert_reply(ref, :ok, %{"relayed" => true, "evidence" => "accepted"})
    refute_push("command", _)
  end

  test "unsigned guests and refresh tokens cannot consume a valid scoped ticket" do
    provision = provision()

    {:ok, guest} =
      connect(UserSocket, %{"guest" => "true", "display_name" => "alice"}, connect_info: @remote)

    assert {:error, %{reason: "unauthenticated"}} = join(guest, provision, "infiltrator")

    assert {:error, %{reason: "unauthenticated"}} =
             join(authenticated("alice", "refresh"), provision, "infiltrator")

    assert {:ok, _, _} = join(authenticated("alice"), provision, "infiltrator")
  end

  test "ticket is bound to principal, role, audience, session and epoch" do
    provision = provision()
    socket = authenticated("alice")

    assert {:error, %{reason: "scope_mismatch"}} =
             join(authenticated("mallory"), provision, "infiltrator")

    assert {:error, %{reason: "scope_mismatch"}} = join(socket, provision, "hacker")

    assert {:error, %{reason: "invalid_ticket"}} =
             join(socket, provision, "infiltrator", %{"ticket" => String.duplicate("x", 43)})

    assert {:error, %{reason: "stale_epoch"}} =
             join(socket, provision, "infiltrator", %{"epoch" => "old-epoch"})

    other = provision()

    assert {:error, %{reason: "invalid_ticket"}} =
             join(socket, other, "infiltrator", %{
               "ticket" => provision.grants["infiltrator"].ticket
             })

    id = "foreign-#{System.unique_integer([:positive])}"
    {:ok, foreign} = Admission.create(id, "unrelated-consumer", %{"infiltrator" => "alice"})
    on_exit(fn -> Admission.close(id) end)
    assert {:error, %{reason: "scope_mismatch"}} = join(socket, foreign, "infiltrator")
    assert {:ok, _, _} = join(socket, provision, "infiltrator")
  end

  test "unsupported 0.8 or binary negotiation cannot silently downgrade" do
    provision = provision()

    for protocol <- [nil, "0.8", "0.8-binary", "legacy-json-v1"] do
      assert {:error, %{reason: "unsupported_protocol"}} =
               join(authenticated("alice"), provision, "infiltrator", %{"protocol" => protocol})
    end

    for encoding <- [%{"encoding" => "binary"}, %{"binary_format" => "bebop"}] do
      assert {:error, %{reason: "unsupported_protocol"}} =
               join(authenticated("alice"), provision, "infiltrator", encoding)
    end

    payload = params(provision, "infiltrator") |> Map.delete("ticket")

    assert {:error, %{reason: "ticket_required"}} =
             subscribe_and_join(
               authenticated("alice"),
               GameChannel,
               "game:" <> provision.session_id,
               payload
             )
  end

  test "scoped receivers discard unscoped and foreign-epoch PubSub traffic" do
    provision = provision()
    {:ok, _, alice} = join(authenticated("alice"), provision, "infiltrator")
    topic = "game:" <> provision.session_id
    payload = %{"event" => "must-not-cross-epoch"}
    @endpoint.broadcast(topic, "event", payload)
    @endpoint.broadcast(topic, "event", %{admission_epoch: "other-instance", payload: payload})
    refute_push("event", _)
    ref = push(alice, "ping", %{})
    assert_reply(ref, :ok, %{"pong" => true})
  end

  test "simultaneous claims for one seat have exactly one winner" do
    provision = provision()
    parent = self()

    contenders =
      for n <- 1..2 do
        socket = authenticated("alice")

        Task.async(fn ->
          send(parent, {:contender_ready, self()})
          receive do: (:claim -> :ok)
          result = join(socket, provision, "infiltrator")
          send(parent, {:claim_result, n, result})
          receive do: (:finish -> :ok)
        end)
      end

    for _ <- 1..2, do: assert_receive({:contender_ready, _})
    Enum.each(contenders, &send(&1.pid, :claim))

    results =
      for _ <- 1..2 do
        assert_receive {:claim_result, _n, result}, 2_000
        result
      end

    assert Enum.count(results, &match?({:ok, _, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, %{reason: "ticket_consumed"}}, &1)) == 1
    Enum.each(contenders, &send(&1.pid, :finish))
    Enum.each(contenders, &Task.await/1)
  end

  test "owner rejoin fences the old channel and rotates the rejoin credential" do
    provision = provision()
    {:ok, receipt, old} = join(authenticated("alice"), provision, "infiltrator")
    {:ok, _, _bob} = join(authenticated("bob"), provision, "hacker")
    ref = push(old, "command", %{"cmd" => "Jump", "seq" => 7})
    assert_reply(ref, :ok)
    assert_push("command", %{"cmd" => "Jump"})

    assert {:error, %{reason: "scope_mismatch"}} =
             rejoin(authenticated("mallory"), provision, "infiltrator", receipt.rejoin_token)

    assert {:error, %{reason: "invalid_rejoin"}} =
             rejoin(authenticated("alice"), provision, "infiltrator", String.duplicate("x", 43))

    monitor = Process.monitor(old.channel_pid)

    {:ok, next_receipt, current} =
      rejoin(authenticated("alice"), provision, "infiltrator", receipt.rejoin_token)

    assert_receive {:DOWN, ^monitor, :process, _, {:shutdown, :session_fenced}}
    refute next_receipt.rejoin_token == receipt.rejoin_token

    assert {:error, %{reason: "invalid_rejoin"}} =
             rejoin(authenticated("alice"), provision, "infiltrator", receipt.rejoin_token)

    assert {:error, %{reason: "ticket_consumed"}} =
             join(authenticated("alice"), provision, "infiltrator")

    ref = push(current, "command", %{"cmd" => "Jump", "seq" => 7})
    assert_reply(ref, :ok, %{"relayed" => false, "reason" => "stale_or_duplicate"})
    refute_push("command", _)
    ref = push(current, "command", %{"cmd" => "Jump", "seq" => 8})
    assert_reply(ref, :ok, %{"evidence" => "accepted"})
    assert_push("command", %{"cmd" => "Jump"})
  end

  test "fresh epoch revokes old tickets, rejoin tokens and live channels" do
    provision = provision()
    {:ok, receipt, old} = join(authenticated("alice"), provision, "infiltrator")
    monitor = Process.monitor(old.channel_pid)
    {:ok, next} = Admission.rotate(provision.session_id)
    refute next.epoch == provision.epoch
    assert next.roster_revision == provision.roster_revision + 1
    assert_receive {:DOWN, ^monitor, :process, _, {:shutdown, :session_fenced}}
    assert {:error, %{reason: "stale_epoch"}} = join(authenticated("bob"), provision, "hacker")

    assert {:error, %{reason: "stale_epoch"}} =
             rejoin(authenticated("alice"), provision, "infiltrator", receipt.rejoin_token)

    assert {:error, %{reason: "invalid_ticket"}} =
             join(authenticated("bob"), next, "hacker", %{
               "ticket" => provision.grants["hacker"].ticket
             })

    assert {:ok, _, _} = join(authenticated("alice"), next, "infiltrator")
  end

  test "authority restart rejects stale state instead of manufacturing a durable resume" do
    provision = provision()
    {:ok, receipt, old} = join(authenticated("alice"), provision, "infiltrator")
    :ok = Supervisor.terminate_child(Burble.Supervisor, Admission)
    assert {:error, :authority_unavailable} = Admission.rotate(provision.session_id)
    {:ok, _pid} = Supervisor.restart_child(Burble.Supervisor, Admission)

    assert {:error, %{reason: "unknown_session"}} =
             rejoin(authenticated("alice"), provision, "infiltrator", receipt.rejoin_token)

    assert {:error, %{reason: "unknown_session"}} =
             join(authenticated("bob"), provision, "hacker")

    ref = push(old, "ping", %{})
    assert_reply(ref, :error, %{"reason" => "unknown_session"})
  end

  test "scoped lane rejects unsequenced commands and bounded-size violations" do
    provision = provision()
    {:ok, _, alice} = join(authenticated("alice"), provision, "infiltrator")

    for seq <- [nil, -1, "1", 9_007_199_254_740_992] do
      ref = push(alice, "command", %{"cmd" => "Jump", "seq" => seq})
      assert_reply(ref, :error, %{"reason" => "invalid_sequence"})
    end

    ref =
      push(alice, "command", %{
        "cmd" => "Jump",
        "seq" => 1,
        "body" => String.duplicate("x", 8_192)
      })

    assert_reply(ref, :error, %{"reason" => "payload_too_large"})
    ref = push(alice, "command", %{"cmd" => "Jump", "seq" => 1})
    assert_reply(ref, :ok, %{"evidence" => "accepted"})
  end

  test "session expiry removes authority and a used invite cannot reopen the seat" do
    provision = provision(ttl_seconds: 1)
    {:ok, _, alice} = join(authenticated("alice"), provision, "infiltrator")
    Process.sleep(1_050)
    ref = push(alice, "command", %{"cmd" => "Jump", "seq" => 1})
    assert_reply(ref, :error, %{"reason" => "unknown_session"})

    assert {:error, %{reason: "unknown_session"}} =
             join(authenticated("bob"), provision, "hacker")
  end

  test "local legacy admission uses actual peer_data, never forwarded claims" do
    Application.put_env(:burble, :game_session_mode, :local_legacy)
    provision = provision()
    legacy = %{"game" => "idaptik", "role" => "infiltrator", "protocol" => "legacy-json-v1"}
    guest = %{"guest" => "true", "display_name" => "local"}
    {:ok, local} = connect(UserSocket, guest, connect_info: @local)

    {:ok, reply, socket} =
      subscribe_and_join(local, GameChannel, "game:" <> provision.session_id, legacy)

    Process.unlink(socket.channel_pid)
    assert reply.protocol == "legacy-json-v1"

    for info <- [@remote, %{}, Map.put(@remote, :x_headers, [{"x-forwarded-for", "127.0.0.1"}])] do
      {:ok, remote} = connect(UserSocket, guest, connect_info: info)

      assert {:error, %{reason: "legacy_requires_loopback"}} =
               subscribe_and_join(remote, GameChannel, "game:" <> provision.session_id, legacy)
    end

    assert {:error, %{reason: "unsupported_protocol"}} =
             subscribe_and_join(
               local,
               GameChannel,
               "game:" <> provision.session_id,
               Map.put(legacy, "protocol", "0.8")
             )

    Application.put_env(:burble, :game_session_mode, :scoped)
    ref = push(socket, "command", %{"cmd" => "Jump"})
    assert_reply(ref, :error, %{"reason" => "session_mode_changed"})
  end

  test "real join logging and authority diagnostics redact bearer credentials" do
    provision = provision()
    previous_level = Logger.level()
    on_exit(fn -> Logger.configure(level: previous_level) end)
    Logger.configure(level: :debug)

    log =
      capture_log(fn ->
        assert {:ok, _, _} = join(authenticated("alice"), provision, "infiltrator")
      end)

    assert log =~ "JOINED game:"
    refute log =~ provision.grants["infiltrator"].ticket
    assert log =~ "[FILTERED]"
    status = inspect(:sys.get_status(Admission))
    refute status =~ "ticket_digest"
    refute status =~ "rejoin_digest"
    refute status =~ "lease_id"
  end
end
