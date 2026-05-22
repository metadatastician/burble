# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
#
# Burble.Security.KeyRotation — Automatic E2EE key rotation scheduler.
#
# Forward secrecy requires periodic key ratcheting: even if a key is
# compromised, only a small window of frames can be decrypted. This
# GenServer orchestrates rotation across all active E2EE rooms.
#
# Rotation triggers:
#   - Time-based: every N seconds (default 20s, ~1000 Opus frames at 20ms)
#   - Frame-count-based: after N frames (tracked per room, future)
#   - Event-based: participant join/leave (handled by E2EE module directly)
#
# Room lifecycle integration:
#   - Subscribes to PubSub room events (room_created, room_destroyed)
#   - Only rotates keys for rooms with active E2EE
#   - Stops tracking destroyed rooms immediately
#
# Metrics tracked:
#   - Total rotations per room
#   - Last rotation timestamp per room
#   - Average rotation latency (time to complete ratchet_key/1)
#
# Author: Jonathan D.A. Jewell

defmodule Burble.Security.KeyRotation do
  @moduledoc """
  Automatic E2EE key rotation scheduler for Burble voice rooms.

  Ensures forward secrecy by periodically calling `Burble.Media.E2EE.ratchet_key/1`
  for every active room. Subscribes to room lifecycle events via Phoenix PubSub
  to track which rooms are active.

  ## Configuration

  Set in application config:

      config :burble, Burble.Security.KeyRotation,
        rotation_interval_ms: 20_000,       # 20 seconds (default)
        enabled: true                        # disable in tests

  ## Telemetry events

  Emits the following telemetry events:

    - `[:burble, :key_rotation, :complete]` — after each successful rotation
    - `[:burble, :key_rotation, :error]` — on rotation failure
  """

  use GenServer

  require Logger

  # ── Types ──

  @typedoc "Per-room rotation tracking state."
  @type room_rotation_state :: %{
          room_id: String.t(),
          rotation_count: non_neg_integer(),
          last_rotation_at: DateTime.t() | nil,
          last_rotation_latency_us: non_neg_integer() | nil,
          active: boolean()
        }

  # Default rotation interval: 20 seconds (~1000 Opus frames at 20ms per frame).
  @default_rotation_interval_ms 20_000

  # PubSub topic for room lifecycle events.
  @room_events_topic "room:events"

  # ── Client API ──

  @doc """
  Start the key rotation scheduler.

  Options:
    - `:rotation_interval_ms` — milliseconds between rotations (default: 20,000)
    - `:enabled` — set to false to disable (useful in tests)
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Manually trigger key rotation for a specific room.

  Useful for testing or when an admin needs to force a rotation
  (e.g. after a suspected key compromise).

  Returns `{:ok, new_epoch}` or `{:error, reason}`.
  """
  @spec rotate_now(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def rotate_now(room_id) do
    GenServer.call(__MODULE__, {:rotate_now, room_id})
  end

  @doc """
  Get rotation metrics for all tracked rooms.

  Returns a map of `room_id => room_rotation_state`.
  """
  @spec metrics() :: %{String.t() => room_rotation_state()}
  def metrics do
    GenServer.call(__MODULE__, :metrics)
  end

  @doc """
  Get rotation metrics for a specific room.

  Returns `{:ok, room_rotation_state}` or `{:error, :not_tracked}`.
  """
  @spec room_metrics(String.t()) :: {:ok, room_rotation_state()} | {:error, :not_tracked}
  def room_metrics(room_id) do
    GenServer.call(__MODULE__, {:room_metrics, room_id})
  end

  @doc """
  Manually register a room for rotation tracking.

  Normally rooms are tracked automatically via PubSub events.
  This is useful in tests or when PubSub events might be missed.
  """
  @spec track_room(String.t()) :: :ok
  def track_room(room_id) do
    GenServer.cast(__MODULE__, {:track_room, room_id})
  end

  @doc """
  Manually unregister a room from rotation tracking.

  Rotation will stop for this room immediately.
  """
  @spec untrack_room(String.t()) :: :ok
  def untrack_room(room_id) do
    GenServer.cast(__MODULE__, {:untrack_room, room_id})
  end

  # ── Server Callbacks ──

  @impl true
  def init(opts) do
    # Resolve configuration from opts and application env.
    app_config = Application.get_env(:burble, __MODULE__, [])

    rotation_interval_ms =
      Keyword.get(
        opts,
        :rotation_interval_ms,
        Keyword.get(app_config, :rotation_interval_ms, @default_rotation_interval_ms)
      )

    enabled =
      Keyword.get(
        opts,
        :enabled,
        Keyword.get(app_config, :enabled, true)
      )

    state = %{
      # Milliseconds between rotation sweeps.
      rotation_interval_ms: rotation_interval_ms,
      # Whether the scheduler is active.
      enabled: enabled,
      # Per-room rotation state: %{room_id => room_rotation_state}.
      rooms: %{},
      # Reference to the periodic timer (so we can cancel on shutdown).
      timer_ref: nil,
      # Global metrics.
      total_rotations: 0,
      total_errors: 0
    }

    # Subscribe to room lifecycle events via PubSub.
    Phoenix.PubSub.subscribe(Burble.PubSub, @room_events_topic)

    # Also subscribe to E2EE-specific events to auto-track rooms.
    Phoenix.PubSub.subscribe(Burble.PubSub, "e2ee:lifecycle")

    # Start the periodic rotation timer if enabled.
    state =
      if enabled do
        timer_ref = schedule_rotation(rotation_interval_ms)
        %{state | timer_ref: timer_ref}
      else
        Logger.info("[KeyRotation] Scheduler disabled")
        state
      end

    Logger.info(
      "[KeyRotation] Started (interval: #{rotation_interval_ms}ms, enabled: #{enabled})"
    )

    {:ok, state}
  end

  @impl true
  def handle_call({:rotate_now, room_id}, _from, state) do
    case Map.get(state.rooms, room_id) do
      nil ->
        {:reply, {:error, :not_tracked}, state}

      room_state ->
        {result, updated_room, global_delta} = perform_rotation(room_id, room_state)
        new_rooms = Map.put(state.rooms, room_id, updated_room)

        new_state = %{
          state
          | rooms: new_rooms,
            total_rotations: state.total_rotations + global_delta.rotations,
            total_errors: state.total_errors + global_delta.errors
        }

        {:reply, result, new_state}
    end
  end

  @impl true
  def handle_call(:metrics, _from, state) do
    metrics = %{
      rooms: state.rooms,
      total_rotations: state.total_rotations,
      total_errors: state.total_errors,
      enabled: state.enabled,
      rotation_interval_ms: state.rotation_interval_ms
    }

    {:reply, metrics, state}
  end

  @impl true
  def handle_call({:room_metrics, room_id}, _from, state) do
    case Map.get(state.rooms, room_id) do
      nil -> {:reply, {:error, :not_tracked}, state}
      room_state -> {:reply, {:ok, room_state}, state}
    end
  end

  @impl true
  def handle_cast({:track_room, room_id}, state) do
    if Map.has_key?(state.rooms, room_id) do
      {:noreply, state}
    else
      room_state = new_room_rotation_state(room_id)
      Logger.info("[KeyRotation] Tracking room: #{room_id}")
      {:noreply, %{state | rooms: Map.put(state.rooms, room_id, room_state)}}
    end
  end

  @impl true
  def handle_cast({:untrack_room, room_id}, state) do
    Logger.info("[KeyRotation] Untracking room: #{room_id}")
    {:noreply, %{state | rooms: Map.delete(state.rooms, room_id)}}
  end

  # ── PubSub event handlers ──

  # Room created: start tracking it for key rotation.
  @impl true
  def handle_info({:room_created, %{room_id: room_id}}, state) do
    if Map.has_key?(state.rooms, room_id) do
      {:noreply, state}
    else
      room_state = new_room_rotation_state(room_id)
      Logger.debug("[KeyRotation] Auto-tracking new room: #{room_id}")
      {:noreply, %{state | rooms: Map.put(state.rooms, room_id, room_state)}}
    end
  end

  # Room destroyed: stop tracking it immediately.
  @impl true
  def handle_info({:room_destroyed, %{room_id: room_id}}, state) do
    if Map.has_key?(state.rooms, room_id) do
      Logger.debug("[KeyRotation] Room destroyed, stopping rotation: #{room_id}")
      {:noreply, %{state | rooms: Map.delete(state.rooms, room_id)}}
    else
      {:noreply, state}
    end
  end

  # E2EE room initialised: start tracking for rotation.
  def handle_info({:e2ee_room_init, %{room_id: room_id}}, state) do
    if Map.has_key?(state.rooms, room_id) do
      {:noreply, state}
    else
      room_state = new_room_rotation_state(room_id)
      Logger.debug("[KeyRotation] E2EE room init, tracking: #{room_id}")
      {:noreply, %{state | rooms: Map.put(state.rooms, room_id, room_state)}}
    end
  end

  # E2EE room destroyed: stop tracking.
  def handle_info({:e2ee_room_destroy, %{room_id: room_id}}, state) do
    Logger.debug("[KeyRotation] E2EE room destroyed, untracking: #{room_id}")
    {:noreply, %{state | rooms: Map.delete(state.rooms, room_id)}}
  end

  # Periodic rotation tick: rotate keys for all active rooms.
  def handle_info(:rotate_tick, %{enabled: false} = state) do
    {:noreply, state}
  end

  def handle_info(:rotate_tick, state) do
    # Rotate keys for all active rooms.
    {updated_rooms, rotation_count, error_count} = rotate_all_rooms(state.rooms)

    # Schedule the next tick.
    timer_ref = schedule_rotation(state.rotation_interval_ms)

    if rotation_count > 0 do
      Logger.debug(
        "[KeyRotation] Rotation sweep complete: #{rotation_count} rotated, #{error_count} errors"
      )
    end

    new_state = %{
      state
      | rooms: updated_rooms,
        timer_ref: timer_ref,
        total_rotations: state.total_rotations + rotation_count,
        total_errors: state.total_errors + error_count
    }

    {:noreply, new_state}
  end

  # Catch-all for unexpected messages (prevents GenServer crash).
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Cancel the timer on shutdown.
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    Logger.info("[KeyRotation] Scheduler stopped")
    :ok
  end

  # ── Private: Rotation logic ──

  # Create a fresh room rotation tracking state.
  @spec new_room_rotation_state(String.t()) :: room_rotation_state()
  defp new_room_rotation_state(room_id) do
    %{
      room_id: room_id,
      rotation_count: 0,
      last_rotation_at: nil,
      last_rotation_latency_us: nil,
      active: true
    }
  end

  # Rotate keys for all tracked active rooms.
  # Returns {updated_rooms_map, total_rotations, total_errors}.
  @spec rotate_all_rooms(map()) :: {map(), non_neg_integer(), non_neg_integer()}
  defp rotate_all_rooms(rooms) do
    Enum.reduce(rooms, {%{}, 0, 0}, fn {room_id, room_state}, {acc_rooms, rotations, errors} ->
      if room_state.active do
        {_result, updated_room, delta} = perform_rotation(room_id, room_state)

        {
          Map.put(acc_rooms, room_id, updated_room),
          rotations + delta.rotations,
          errors + delta.errors
        }
      else
        {Map.put(acc_rooms, room_id, room_state), rotations, errors}
      end
    end)
  end

  # Perform a single key rotation for one room.
  #
  # Measures latency, calls E2EE.ratchet_key/1, and updates room metrics.
  # Returns {result, updated_room_state, %{rotations: n, errors: n}}.
  @spec perform_rotation(String.t(), room_rotation_state()) ::
          {{:ok, non_neg_integer()} | {:error, term()}, room_rotation_state(),
           %{rotations: non_neg_integer(), errors: non_neg_integer()}}
  defp perform_rotation(room_id, room_state) do
    start_time = System.monotonic_time(:microsecond)

    case Burble.Media.E2EE.ratchet_key(room_id) do
      {:ok, new_epoch} ->
        elapsed_us = System.monotonic_time(:microsecond) - start_time

        # Emit telemetry event for monitoring dashboards.
        :telemetry.execute(
          [:burble, :key_rotation, :complete],
          %{latency_us: elapsed_us, epoch: new_epoch},
          %{room_id: room_id}
        )

        updated = %{
          room_state
          | rotation_count: room_state.rotation_count + 1,
            last_rotation_at: DateTime.utc_now(),
            last_rotation_latency_us: elapsed_us
        }

        {{:ok, new_epoch}, updated, %{rotations: 1, errors: 0}}

      {:error, :no_room} ->
        # Room no longer exists in E2EE module — mark as inactive.
        Logger.warning("[KeyRotation] Room #{room_id} not found in E2EE, marking inactive")

        :telemetry.execute(
          [:burble, :key_rotation, :error],
          %{},
          %{room_id: room_id, reason: :no_room}
        )

        updated = %{room_state | active: false}
        {{:error, :no_room}, updated, %{rotations: 0, errors: 1}}

      {:error, reason} ->
        Logger.error("[KeyRotation] Rotation failed for #{room_id}: #{inspect(reason)}")

        :telemetry.execute(
          [:burble, :key_rotation, :error],
          %{},
          %{room_id: room_id, reason: reason}
        )

        {{:error, reason}, room_state, %{rotations: 0, errors: 1}}
    end
  end

  # Schedule the next rotation tick.
  @spec schedule_rotation(non_neg_integer()) :: reference()
  defp schedule_rotation(interval_ms) do
    Process.send_after(self(), :rotate_tick, interval_ms)
  end
end
