# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Tests for Burble.Groove — connection lifecycle, capability manifest,
# health mesh probing, and endpoint format.

defmodule Burble.Groove.GrooveTest do
  use ExUnit.Case, async: false

  alias Burble.Groove
  alias Burble.Groove.HealthMesh

  # Disconnect any sessions created during a test.
  setup do
    on_exit(fn ->
      Groove.connection_status()
      |> Map.keys()
      |> Enum.each(&Groove.disconnect/1)
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # 1. Module starts and is available
  # ---------------------------------------------------------------------------

  describe "GenServer availability" do
    test "Burble.Groove is registered and alive" do
      pid = GenServer.whereis(Groove)
      assert is_pid(pid), "Burble.Groove is not registered"
      assert Process.alive?(pid), "Burble.Groove process is not alive"
    end

    test "Burble.Groove.HealthMesh is registered and alive" do
      pid = GenServer.whereis(HealthMesh)
      assert is_pid(pid), "Burble.Groove.HealthMesh is not registered"
      assert Process.alive?(pid), "Burble.Groove.HealthMesh process is not alive"
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Capability manifest contains expected capabilities
  # ---------------------------------------------------------------------------

  describe "capability manifest" do
    test "contains voice, text, and presence capabilities" do
      caps = Groove.manifest().capabilities
      assert Map.has_key?(caps, :voice)
      assert Map.has_key?(caps, :text)
      assert Map.has_key?(caps, :presence)
    end

    test "contains extended capabilities: spatial_audio, recording, tts, stt" do
      caps = Groove.manifest().capabilities
      assert Map.has_key?(caps, :spatial_audio)
      assert Map.has_key?(caps, :recording)
      assert Map.has_key?(caps, :tts)
      assert Map.has_key?(caps, :stt)
    end

    test "voice capability is panel_compatible and uses webrtc" do
      voice = Groove.manifest().capabilities.voice
      assert voice.protocol == "webrtc"
      assert voice.panel_compatible == true
      assert voice.requires_auth == false
    end

    test "applicability covers individual, team, and massive-open contexts" do
      applicability = Groove.manifest().applicability
      assert "individual" in applicability
      assert "team" in applicability
      assert "massive-open" in applicability
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Connection state machine: DISCOVERED -> NEGOTIATING -> CONNECTED -> ACTIVE
  # ---------------------------------------------------------------------------

  describe "connection lifecycle" do
    test "connect/1 returns {:ok, session_id} for a compatible peer" do
      peer = %{
        "service_id" => "gossamer",
        "groove_version" => "1",
        "consumes" => ["voice", "presence"]
      }

      assert {:ok, session_id} = Groove.connect(peer)
      assert is_binary(session_id)
      assert byte_size(session_id) > 0
      Groove.disconnect(session_id)
    end

    test "connect/1 transitions connection to :connected state" do
      peer = %{"service_id" => "panll", "consumes" => ["text"]}

      {:ok, session_id} = Groove.connect(peer)

      status = Groove.connection_status()
      assert Map.has_key?(status, session_id)
      assert status[session_id].state == :connected
      assert status[session_id].peer_id == "panll"

      Groove.disconnect(session_id)
    end

    test "heartbeat/1 transitions connection to :active state" do
      peer = %{"service_id" => "gsa", "consumes" => ["tts"]}
      {:ok, session_id} = Groove.connect(peer)

      assert :ok = Groove.heartbeat(session_id)

      status = Groove.connection_status()
      assert status[session_id].state == :active

      Groove.disconnect(session_id)
    end

    test "disconnect/1 removes the session" do
      peer = %{"service_id" => "ambient-ops", "consumes" => ["voice"]}
      {:ok, session_id} = Groove.connect(peer)

      assert :ok = Groove.disconnect(session_id)
      refute Map.has_key?(Groove.connection_status(), session_id)
    end

    test "disconnect/1 returns {:error, :not_found} for unknown session" do
      assert {:error, :not_found} = Groove.disconnect("nonexistent-session-id")
    end

    test "heartbeat/1 returns {:error, :not_found} for unknown session" do
      assert {:error, :not_found} = Groove.heartbeat("nonexistent-session-id")
    end

    test "connect/1 rejects peer with no matching capabilities" do
      peer = %{"service_id" => "alien-service", "consumes" => ["quantum-teleport"]}
      assert {:error, _reason} = Groove.connect(peer)
    end
  end

  # ---------------------------------------------------------------------------
  # 4. Health mesh probing
  # ---------------------------------------------------------------------------

  describe "HealthMesh" do
    test "mesh_status/0 returns a map with required keys" do
      status = HealthMesh.mesh_status()
      assert is_map(status)
      assert Map.has_key?(status, :service_id)
      assert Map.has_key?(status, :timestamp_ms)
      assert Map.has_key?(status, :peers)
      assert Map.has_key?(status, :peer_count)
    end

    test "mesh_status/0 reports service_id as 'burble'" do
      assert HealthMesh.mesh_status().service_id == "burble"
    end

    test "probe_now/0 completes without error" do
      assert :ok = HealthMesh.probe_now()
    end
  end

  # ---------------------------------------------------------------------------
  # 5. /.well-known/groove endpoint format validation
  # ---------------------------------------------------------------------------

  describe "manifest JSON for /.well-known/groove endpoint" do
    test "manifest_json/0 produces valid JSON with groove_version at top level" do
      json = Groove.manifest_json()
      assert is_binary(json)
      {:ok, decoded} = Jason.decode(json)
      assert decoded["groove_version"] == "1"
    end

    test "manifest JSON contains capabilities object with voice entry" do
      {:ok, decoded} = Jason.decode(Groove.manifest_json())
      caps = decoded["capabilities"]
      assert is_map(caps)
      assert Map.has_key?(caps, "voice")
      assert caps["voice"]["type"] == "voice"
    end

    test "manifest JSON has consumes list and endpoints map" do
      {:ok, decoded} = Jason.decode(Groove.manifest_json())
      assert is_list(decoded["consumes"])
      assert is_map(decoded["endpoints"])
      assert Map.has_key?(decoded["endpoints"], "voice_ws")
      assert Map.has_key?(decoded["endpoints"], "health")
    end
  end
end
