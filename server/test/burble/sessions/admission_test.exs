# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
defmodule Burble.Sessions.AdmissionTest do
  use ExUnit.Case, async: false
  alias Burble.Sessions.Admission

  setup do
    id = "generic-#{System.unique_integer([:positive])}"
    on_exit(fn -> Admission.close(id) end)

    %{
      id: id,
      identity: %{subject: "participant_17", expires_at: System.system_time(:second) + 60}
    }
  end

  test "generic scopes need no game profile; a lease is also bound to its owning process", %{
    id: id,
    identity: identity
  } do
    {:ok, provision} = Admission.create(id, "document-review", %{"editor" => identity.subject})

    {:ok, lease, receipt} =
      Admission.claim(
        identity,
        id,
        "document-review",
        "editor",
        provision.epoch,
        {:ticket, provision.grants["editor"].ticket}
      )

    parent = self()

    assert {:error, :stale_lease} =
             Task.async(fn ->
               Admission.with_current(lease, fn ->
                 send(parent, :foreign_effect)
                 :ok
               end)
             end)
             |> Task.await()

    refute_receive :foreign_effect

    assert :ok =
             Admission.with_current(lease, fn ->
               send(parent, :owner_effect)
               :ok
             end)

    assert_receive :owner_effect

    {:ok, next_lease, _} =
      Admission.claim(
        identity,
        id,
        "document-review",
        "editor",
        provision.epoch,
        {:rejoin, receipt.rejoin_token}
      )

    assert_receive :session_fenced

    assert {:error, :stale_lease} =
             Admission.with_current(lease, fn ->
               send(parent, :stale_effect)
               :ok
             end)

    refute_receive :stale_effect
    assert :ok = Admission.with_current(next_lease, fn -> :ok end)
  end

  test "provisioning rejects malformed identifiers, repeated identity and excessive capacity", %{
    id: id
  } do
    for {audience, roster, opts} <- [
          {"document-review", %{}, []},
          {"document-review", %{"left" => "same", "right" => "same"}, []},
          {"document-review", Map.new(1..17, fn n -> {"role_#{n}", "person_#{n}"} end), []},
          {"document review", %{"editor" => "participant_17"}, []},
          {"document-review", %{"editor" => <<255>>}, []},
          {"document-review", %{"editor" => "participant_17"}, [ttl_seconds: 0]},
          {"document-review", %{"editor" => "participant_17"}, [ttl_seconds: 3_601]}
        ] do
      assert {:error, :invalid_session} = Admission.create(id, audience, roster, opts)
    end

    assert {:ok, _} = Admission.create(id, "document-review", %{"editor" => "participant_17"})

    assert {:error, :session_exists} =
             Admission.create(id, "document-review", %{"editor" => "participant_17"})
  end

  test "expired identity cannot acquire or continue using a live session", %{
    id: id,
    identity: identity
  } do
    {:ok, provision} = Admission.create(id, "document-review", %{"editor" => identity.subject})
    ticket = {:ticket, provision.grants["editor"].ticket}
    expired = %{identity | expires_at: System.system_time(:second) - 1}

    assert {:error, :unauthenticated} =
             Admission.claim(expired, id, "document-review", "editor", provision.epoch, ticket)

    short = %{identity | expires_at: System.system_time(:second) + 1}

    {:ok, lease, _} =
      Admission.claim(short, id, "document-review", "editor", provision.epoch, ticket)

    Process.sleep(1_050)

    assert {:error, :stale_lease} =
             Admission.with_current(lease, fn -> flunk("expired writer executed") end)
  end

  test "session budget refuses additional allocation and frees it only after close", %{
    identity: identity
  } do
    prefix = "capacity-#{System.unique_integer([:positive])}"
    ids = Enum.map(1..256, &"#{prefix}-#{&1}")
    on_exit(fn -> Enum.each(ids, &Admission.close/1) end)

    for id <- ids do
      assert {:ok, _} = Admission.create(id, "document-review", %{"editor" => identity.subject})
    end

    extra = prefix <> "-extra"
    on_exit(fn -> Admission.close(extra) end)

    assert {:error, :session_capacity} =
             Admission.create(extra, "document-review", %{"editor" => identity.subject})

    assert :ok = Admission.close(hd(ids))
    assert {:ok, _} = Admission.create(extra, "document-review", %{"editor" => identity.subject})
  end
end
