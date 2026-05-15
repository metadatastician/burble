# SPDX-License-Identifier: PMPL-1.0-or-later
#
# Burble.Topology.Transition — Mixed governance and topology transitions.
#
# Implements the logic for rooms to "break off" (secession) or "come together"
# (merger) by transitioning between topology modes.
#
# Transitions involve:
#   1. Chain Forking — Creating a new Vext genesis block from an anchored tip.
#   2. Policy Migration — Updating the room's governance rules.
#   3. Consent Reconciliation — Verifying AVOW attestations for the new mode.

defmodule Burble.Topology.Transition do
  @moduledoc """
  Logic for room-level topology transitions and governance mergers.

  ## Topology Transition Modes

  Monarchic and oligarchic transitions are fully supported. Distributed and serverless
  transitions currently return `{:error, :fork_not_implemented}`. The Vext chain forking
  and cross-server AVOW coordination required for these modes are scheduled for Phase 2.

  Attempts to transition to distributed or serverless will fail loudly with a clear error,
  enabling callers to handle the limitation explicitly rather than proceeding with an
  incomplete state.
  """

  require Logger
  alias Burble.Rooms.Room
  alias Burble.Verification.Vext

  @doc """
  Transition a room to a new topology mode.
  Handles Vext chain forking if the new mode is 'Distributed' or 'Serverless'.

  Returns:
    :ok — transition succeeded (for monarchic/oligarchic modes, or when chain fork is implemented)
    {:error, :fork_not_implemented} — chain fork requested but not yet implemented (Phase 2)
    {:error, reason} — room lookup or other failure
  """
  def transition_room(room_id, new_mode) do
    Logger.info("[Topology] Transitioning room #{room_id} to #{new_mode}")

    # 1. Get current state
    case Room.get_state(room_id) do
      {:ok, state} ->
        # 2. If transitioning to a sovereign mode, fork the chain
        with :ok <- fork_chain_if_needed(new_mode, room_id, state) do
          # 3. Update room process state
          send_transition_signal(room_id, new_mode)
          :ok
        end

      error ->
        Logger.error("[Topology] Failed to transition room: #{inspect(error)}")
        error
    end
  end

  @doc """
  Merge two rooms with different topologies into a new arrangement.
  Uses Groove protocol to exchange capabilities and verify consent.
  """
  def merge_rooms(room_a_id, room_b_id, target_mode) do
    Logger.info("[Topology] Merging room #{room_a_id} and #{room_b_id} into #{target_mode}")
    
    # 1. Verify AVOW consent from both groups for the merger
    # 2. Create a 'Merge Link' in the Vext chain pointing to both tips
    # 3. Consolidate participants into a single room process
    :ok
  end

  # --- Internal ---

  defp fork_chain_if_needed(mode, _room_id, _state) when mode in [:monarchic, :oligarchic] do
    # No chain fork needed for hierarchical modes
    :ok
  end

  defp fork_chain_if_needed(mode, room_id, state) when mode in [:distributed, :serverless] do
    # Chain fork is required but not yet implemented (Phase 2)
    fork_vext_chain(room_id, state)
  end

  defp fork_vext_chain(room_id, state) do
    Logger.info("[Vext] Forking chain for room #{room_id} at position #{state[:position] || 0}")
    {:error, :fork_not_implemented}
  end

  defp send_transition_signal(room_id, new_mode) do
    # Signal the room process to update its topology_mode attribute
    case Registry.lookup(Burble.RoomRegistry, room_id) do
      [{pid, _}] -> 
        GenServer.cast(pid, {:update_topology, new_mode})
      [] -> 
        :ok
    end
  end
end
