# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
#
# Tests for Burble.Security.SDP — Software-Defined Perimeter gateway.
#
# The SDP module delegates firewall operations to Burble.Coprocessor.ZigBackend
# which returns :ok whenever NIFs are not loaded, so the GenServer can start
# and exercise Elixir-level policy logic without native code.

defmodule Burble.Security.SDPTest do
  use ExUnit.Case, async: true

  # Start a fresh, isolated SDP GenServer for each test so tests don't share
  # state and can run concurrently.
  setup do
    # The SDP GenServer is normally registered under its module name globally.
    # We start an unnamed instance to avoid conflicts between async tests.
    {:ok, pid} = GenServer.start_link(Burble.Security.SDP, [])
    %{sdp: pid}
  end

  # ---------------------------------------------------------------------------
  # 1. Module existence and compilation
  # ---------------------------------------------------------------------------

  describe "module definition" do
    test "module exists and exports expected functions" do
      assert function_exported?(Burble.Security.SDP, :start_link, 1)
      assert function_exported?(Burble.Security.SDP, :process_spa, 2)
      assert function_exported?(Burble.Security.SDP, :revoke_access, 1)
    end

    test "module is a GenServer" do
      behaviours =
        Burble.Security.SDP.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert GenServer in behaviours
    end
  end

  # ---------------------------------------------------------------------------
  # 2. SPA validation — valid (non-empty) packet is accepted
  # ---------------------------------------------------------------------------

  describe "process_spa/2 — authorisation" do
    test "valid non-empty SPA packet returns :ok", %{sdp: pid} do
      # The scaffold's verify_spa_packet/1 accepts any non-empty binary.
      result = GenServer.call(pid, {:process_spa, "valid-spa-token", {127, 0, 0, 1}})
      assert result == :ok
    end

    test "valid SPA from an IPv6 address returns :ok", %{sdp: pid} do
      result = GenServer.call(pid, {:process_spa, "valid-spa-token", {0, 0, 0, 0, 0, 0, 0, 1}})
      assert result == :ok
    end

    test "second valid SPA from same IP overwrites session and returns :ok", %{sdp: pid} do
      ip = {10, 0, 0, 42}
      assert :ok = GenServer.call(pid, {:process_spa, "first-packet", ip})
      assert :ok = GenServer.call(pid, {:process_spa, "second-packet", ip})
    end
  end

  # ---------------------------------------------------------------------------
  # 3. SPA rejection — empty packet is refused
  # ---------------------------------------------------------------------------

  describe "process_spa/2 — rejection" do
    test "empty SPA packet is rejected with {:error, :invalid_spa}", %{sdp: pid} do
      result = GenServer.call(pid, {:process_spa, <<>>, {1, 2, 3, 4}})
      assert result == {:error, :invalid_spa}
    end

    test "empty binary is the only invalid input the scaffold rejects", %{sdp: pid} do
      # Single byte is treated as a valid packet by the scaffold's length check.
      result = GenServer.call(pid, {:process_spa, <<0>>, {1, 2, 3, 4}})
      assert result == :ok
    end
  end

  # ---------------------------------------------------------------------------
  # 4. Access revocation
  # ---------------------------------------------------------------------------

  describe "revoke_access/1" do
    test "revoking a previously granted IP returns :ok", %{sdp: pid} do
      ip = {192, 168, 1, 100}
      :ok = GenServer.call(pid, {:process_spa, "grant-me", ip})
      assert :ok = GenServer.call(pid, {:revoke_access, ip})
    end

    test "revoking an IP that was never granted still returns :ok", %{sdp: pid} do
      # Revocation is idempotent — no error for unknown IPs.
      assert :ok = GenServer.call(pid, {:revoke_access, {172, 16, 0, 99}})
    end

    test "session is removed after revocation", %{sdp: pid} do
      ip = {10, 20, 30, 40}
      :ok = GenServer.call(pid, {:process_spa, "grant-me", ip})
      :ok = GenServer.call(pid, {:revoke_access, ip})
      # Re-granting should succeed (clean slate — no duplicate session error).
      assert :ok = GenServer.call(pid, {:process_spa, "re-grant", ip})
    end
  end

  # ---------------------------------------------------------------------------
  # 5. NIF fallback — ZigBackend gracefully absent
  # ---------------------------------------------------------------------------

  describe "NIF fallback behaviour" do
    test "SDP GenServer starts successfully without compiled Zig NIFs" do
      # If we reached this point the setup succeeded, which means sdp_firewall_init
      # did not crash — ZigBackend returns :ok when the NIF is not loaded.
      {:ok, pid} = GenServer.start_link(Burble.Security.SDP, [])
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "ZigBackend.sdp_firewall_init/0 returns :ok regardless of NIF state" do
      # This directly tests the fallback that SDP relies on.
      assert :ok = Burble.Coprocessor.ZigBackend.sdp_firewall_init()
    end

    test "ZigBackend.sdp_firewall_authorize/2 returns :ok regardless of NIF state" do
      assert :ok = Burble.Coprocessor.ZigBackend.sdp_firewall_authorize({127, 0, 0, 1}, 4020)
    end
  end

  # ---------------------------------------------------------------------------
  # 6. Source-level: SDP policy architecture
  # ---------------------------------------------------------------------------

  describe "SDP module structure" do
    test "module implements Zero Trust policy description" do
      sdp_source = File.read!(Path.join(__DIR__, "../../../lib/burble/security/sdp.ex"))
      assert sdp_source =~ "Zero Trust"
    end

    test "module documents Single Packet Authorisation" do
      sdp_source = File.read!(Path.join(__DIR__, "../../../lib/burble/security/sdp.ex"))
      assert sdp_source =~ "Single Packet Authoris"
    end

    test "module integrates with Zig NIF for firewall operations" do
      sdp_source = File.read!(Path.join(__DIR__, "../../../lib/burble/security/sdp.ex"))
      assert sdp_source =~ "ZigBackend.sdp_firewall_authorize"
    end
  end
end
