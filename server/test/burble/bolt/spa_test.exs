# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Tests for Burble.Bolt.Spa — Single-Packet-Authorisation for bolts.

defmodule Burble.Bolt.SpaTest do
  use ExUnit.Case, async: false

  alias Burble.Bolt.Spa

  @secret "test-bolt-secret-please-change"

  setup do
    Spa.init_replay_table()
    :ok
  end

  defp base_payload, do: %{"from" => "alice@node", "server" => "https://x", "ts" => 1}

  test "sign then verify round-trips" do
    signed = Spa.sign(base_payload(), @secret)
    assert %{"ts" => _, "nonce" => _, "mac" => _} = signed["spa"]
    assert :ok = Spa.verify(signed, @secret)
  end

  test "a wrong secret fails with :bad_mac" do
    signed = Spa.sign(base_payload(), @secret)
    assert {:error, :bad_mac} = Spa.verify(signed, "the-wrong-secret")
  end

  test "a tampered sender ('from') fails with :bad_mac" do
    signed = Spa.sign(base_payload(), @secret)
    forged = Map.put(signed, "from", "mallory@node")
    assert {:error, :bad_mac} = Spa.verify(forged, @secret)
  end

  test "a missing spa tag fails with :missing_spa" do
    assert {:error, :missing_spa} = Spa.verify(base_payload(), @secret)
  end

  test "a stale timestamp (outside ±30s) fails with :stale_timestamp" do
    signed = Spa.sign(base_payload(), @secret)
    stale = put_in(signed, ["spa", "ts"], System.os_time(:millisecond) - 60_000)
    assert {:error, :stale_timestamp} = Spa.verify(stale, @secret)
  end

  test "replaying the same nonce fails the second time" do
    signed = Spa.sign(base_payload(), @secret)
    assert :ok = Spa.verify(signed, @secret)
    assert {:error, :replayed_nonce} = Spa.verify(signed, @secret)
  end

  test "enabled?/0 reflects the configured secret" do
    original = Application.get_env(:burble, :bolt_secret)
    on_exit(fn -> Application.put_env(:burble, :bolt_secret, original) end)

    Application.put_env(:burble, :bolt_secret, nil)
    refute Spa.enabled?()

    Application.put_env(:burble, :bolt_secret, "")
    refute Spa.enabled?()

    Application.put_env(:burble, :bolt_secret, "s3cret")
    assert Spa.enabled?()
  end
end
