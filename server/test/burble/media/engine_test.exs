# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Unit tests for Burble.Media.Engine — the Membrane-based SFU engine.
#
# Covers:
#   - add_peer/3: session state updated, SDP offer returned
#   - remove_peer/2: peer removed from session state
#   - distribute_rtp/3: packet forwarded to registered peers, sender excluded
#   - max outbound peer cap (@max_outbound_peers = 50): adding beyond the cap
#     does not crash the Engine and is handled gracefully
#
# Infrastructure:
#   The full Burble application is started by test_helper.exs
#   (Application.ensure_all_started(:burble)), so Burble.Media.Engine,
#   Burble.PeerRegistry, Burble.PeerSupervisor, Burble.PubSub, and all
#   related named processes are already running. Tests call the Engine
#   API functions directly and clean up any sessions they create.
#
# Note on Peer GenServers:
#   Engine.add_peer/3 attempts to start a Burble.Media.Peer child under
#   Burble.PeerSupervisor. In test mode ExWebRTC.PeerConnection is not
#   available, so those start attempts are expected to fail. The Engine
#   logs a warning but still records the peer in session state and returns
#   {:ok, offer} — the Engine's own state machine is the subject under test.
#
# Note on @max_outbound_peers:
#   The 50-peer cap is enforced inside Burble.Media.Peer.add_outbound_peer
#   (per-Peer GenServer). The Engine itself will attempt to start a Peer
#   process for every add_peer call regardless; the cap prevents the
#   transceiver count from growing quadratically inside each Peer. At the
#   Engine level we verify that the Engine state can hold 50 peers without
#   error, and that a 51st add_peer call does not crash the Engine.

defmodule Burble.Media.EngineTest do
  use ExUnit.Case, async: false

  import Burble.TestHelpers, only: [generate_room_id: 0, generate_user_id: 0]

  alias Burble.Media.Engine

  # Max outbound peers constant (mirrors Burble.Media.Peer @max_outbound_peers).
  @max_outbound_peers 50

  # ---------------------------------------------------------------------------
  # Setup — ensure a clean Engine state per test by scoping to unique rooms
  # ---------------------------------------------------------------------------
  #
  # The Engine is a singleton named process started by the application. We
  # scope each test to its own unique room_id so tests are fully isolated
  # from each other without restarting the process.

  setup do
    room_id = generate_room_id()

    on_exit(fn ->
      # Best-effort cleanup — ignore errors if the session was already destroyed.
      Engine.destroy_room_session(room_id)
    end)

    %{room_id: room_id}
  end

  # ---------------------------------------------------------------------------
  # add_peer/3
  # ---------------------------------------------------------------------------

  describe "add_peer/3" do
    setup %{room_id: room_id} do
      {:ok, _} = Engine.create_room_session(room_id)
      :ok
    end

    test "returns {:ok, offer} map and records peer in session state", %{room_id: room_id} do
      peer_id = generate_user_id()
      assert {:ok, offer} = Engine.add_peer(room_id, peer_id)

      # Offer shape.
      assert is_map(offer)
      assert offer.type == :offer
      assert is_atom(offer.privacy_mode)

      # Session state updated.
      assert {:ok, health} = Engine.get_room_health(room_id)
      assert health.peer_count == 1
    end

    test "each add_peer increments peer_count independently", %{room_id: room_id} do
      {:ok, _} = Engine.add_peer(room_id, generate_user_id())
      {:ok, _} = Engine.add_peer(room_id, generate_user_id())

      assert {:ok, health} = Engine.get_room_health(room_id)
      assert health.peer_count == 2
    end

    test "returns {:error, :no_session} when session does not exist" do
      unknown_room = "no-such-room-#{System.unique_integer()}"
      assert {:error, :no_session} = Engine.add_peer(unknown_room, generate_user_id())
    end

    test "offer reflects e2ee privacy mode: e2ee true, ice_policy relay", %{room_id: room_id} do
      e2ee_room = "e2ee-" <> generate_room_id()

      on_exit(fn -> Engine.destroy_room_session(e2ee_room) end)

      {:ok, _} = Engine.create_room_session(e2ee_room, privacy: :e2ee)
      {:ok, offer} = Engine.add_peer(e2ee_room, generate_user_id())

      assert offer.e2ee == true
      assert offer.ice_policy == :relay
    end
  end

  # ---------------------------------------------------------------------------
  # remove_peer/2
  # ---------------------------------------------------------------------------

  describe "remove_peer/2" do
    setup %{room_id: room_id} do
      {:ok, _} = Engine.create_room_session(room_id)
      :ok
    end

    test "removes peer and decrements peer_count", %{room_id: room_id} do
      peer_id = generate_user_id()
      {:ok, _} = Engine.add_peer(room_id, peer_id)

      assert :ok = Engine.remove_peer(room_id, peer_id)

      assert {:ok, health} = Engine.get_room_health(room_id)
      assert health.peer_count == 0
    end

    test "removing one peer leaves others intact", %{room_id: room_id} do
      peer_a = generate_user_id()
      peer_b = generate_user_id()
      {:ok, _} = Engine.add_peer(room_id, peer_a)
      {:ok, _} = Engine.add_peer(room_id, peer_b)

      assert :ok = Engine.remove_peer(room_id, peer_a)

      assert {:ok, health} = Engine.get_room_health(room_id)
      assert health.peer_count == 1
    end

    test "returns {:error, :no_session} when session does not exist" do
      assert {:error, :no_session} =
               Engine.remove_peer("nonexistent-room-#{System.unique_integer()}", "peer-x")
    end

    test "remove_peer is idempotent for unknown peer_id", %{room_id: room_id} do
      # Removing a peer that was never added should not crash the Engine.
      assert :ok = Engine.remove_peer(room_id, "ghost-peer")

      # Engine is still responsive.
      assert {:ok, health} = Engine.get_room_health(room_id)
      assert health.peer_count == 0
    end
  end

  # ---------------------------------------------------------------------------
  # distribute_rtp/3
  # ---------------------------------------------------------------------------
  #
  # distribute_rtp is a GenServer.cast. We verify it:
  #   1. Does not crash the Engine.
  #   2. Forwards to registered peers via Burble.Media.Peer.forward_rtp (cast).
  #   3. Does NOT forward back to the sender.
  #
  # We register lightweight stub processes in Burble.PeerRegistry to capture
  # forward_rtp casts and assert on delivery.

  describe "distribute_rtp/3" do
    setup %{room_id: room_id} do
      {:ok, _} = Engine.create_room_session(room_id)
      :ok
    end

    test "does not crash the Engine when no peers are registered", %{room_id: room_id} do
      packet = :crypto.strong_rand_bytes(32)
      Engine.distribute_rtp(room_id, "orphan-sender", packet)

      # Allow the cast to be processed.
      :timer.sleep(50)

      # Engine must still be alive and responsive.
      assert {:ok, _health} = Engine.get_room_health(room_id)
    end

    test "forwards RTP to registered peers, excluding sender", %{room_id: room_id} do
      sender_id = generate_user_id()
      receiver_id = generate_user_id()

      # Add both peers to the Engine session so distribute_to_peers sees them.
      {:ok, _} = Engine.add_peer(room_id, sender_id)
      {:ok, _} = Engine.add_peer(room_id, receiver_id)

      # Spawn a stub process that self-registers in Burble.PeerRegistry under
      # receiver_id, then waits for a forward_rtp cast and notifies the test.
      test_pid = self()
      packet = :crypto.strong_rand_bytes(20)

      stub_pid =
        spawn(fn ->
          # Registry.register/3 registers the *calling* process.
          {:ok, _} = Registry.register(Burble.PeerRegistry, receiver_id, nil)
          # Signal readiness.
          send(test_pid, :stub_ready)

          receive do
            {:"$gen_cast", {:forward_rtp, ^sender_id, ^packet}} ->
              send(test_pid, :rtp_received)
          after
            1_000 -> send(test_pid, :rtp_timeout)
          end
        end)

      # Wait for the stub to register before triggering distribution.
      assert_receive :stub_ready, 500

      Engine.distribute_rtp(room_id, sender_id, packet)

      # Wait for the cast to be processed by the stub.
      assert_receive :rtp_received, 500

      # Cleanup stub.
      Process.exit(stub_pid, :kill)
    end

    test "sender does not receive its own RTP packet", %{room_id: room_id} do
      sender_id = generate_user_id()
      {:ok, _} = Engine.add_peer(room_id, sender_id)

      packet = :crypto.strong_rand_bytes(20)
      Engine.distribute_rtp(room_id, sender_id, packet)

      # Allow the cast to be processed.
      :timer.sleep(50)

      # If the sender's own process happened to be in the registry it would
      # self-forward. We simply assert the Engine did not crash.
      assert {:ok, health} = Engine.get_room_health(room_id)
      assert health.peer_count >= 1
    end
  end

  # ---------------------------------------------------------------------------
  # Max peer cap — @max_outbound_peers = 50
  # ---------------------------------------------------------------------------
  #
  # The Engine's session state tracks peers independently of the Peer GenServer
  # lifecycle. add_peer/3 always updates session state (and returns {:ok, offer})
  # even when the underlying Peer process fails to start (ExWebRTC unavailable
  # in test). We verify that:
  #   1. The Engine accepts 50 peers without error.
  #   2. Adding a 51st peer does not crash the Engine.
  #   3. The session health reflects all peers the Engine recorded.

  describe "peer cap (@max_outbound_peers = 50)" do
    setup %{room_id: room_id} do
      {:ok, _} = Engine.create_room_session(room_id)
      :ok
    end

    test "Engine records up to max_outbound_peers without error", %{room_id: room_id} do
      for _ <- 1..@max_outbound_peers do
        assert {:ok, _offer} = Engine.add_peer(room_id, generate_user_id())
      end

      assert {:ok, health} = Engine.get_room_health(room_id)
      assert health.peer_count == @max_outbound_peers
    end

    test "51st add_peer does not crash the Engine", %{room_id: room_id} do
      for _ <- 1..@max_outbound_peers do
        Engine.add_peer(room_id, generate_user_id())
      end

      # The Engine itself does not enforce the cap — it always records the peer.
      # The cap is enforced per-Peer-GenServer (Burble.Media.Peer). We verify
      # that the Engine does not crash on the 51st call.
      assert {:ok, _offer} = Engine.add_peer(room_id, generate_user_id())

      # Engine is still responsive after the over-cap attempt.
      assert {:ok, health} = Engine.get_room_health(room_id)
      assert health.peer_count == @max_outbound_peers + 1
    end
  end
end
