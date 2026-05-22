# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
#
# Burble.Media.LMDBPlayout — Memory-mapped ring buffer for audio frame playout.
#
# LMDB (Lightning Memory-Mapped Database) provides crash-safe, zero-copy
# reads with deterministic latency — ideal for real-time audio playout
# where jitter must be minimised. This module wraps LMDB as a fixed-size
# ring buffer: old frames are evicted when the buffer is full.
#
# Why LMDB over ETS:
#   - Memory-mapped: reads don't copy data, avoiding GC pressure
#   - Crash-safe: MVCC + copy-on-write means data survives process crashes
#   - Deterministic latency: no GC pauses, no lock contention (readers never block)
#   - Multi-process safe: LMDB's MVCC allows concurrent readers + single writer
#
# Ring buffer semantics:
#   - Fixed capacity (default: 50 frames = 1 second at 20ms Opus frames)
#   - Write advances a write cursor (sequence number mod capacity)
#   - Read advances a read cursor (oldest unread frame)
#   - Overflow: oldest frame is overwritten (producer never blocks)
#
# Fallback:
#   When the LMDB NIF is not available (e.g. during development or on
#   platforms without the C library), we fall back to an ETS-based
#   implementation with similar semantics but without crash safety.
#
# Frame format stored in the buffer:
#   Key: sequence_number (integer, monotonically increasing)
#   Value: {timestamp_us, opus_payload}
#
# Author: Jonathan D.A. Jewell

defmodule Burble.Media.LMDBPlayout do
  @moduledoc """
  Memory-mapped ring buffer for audio frame playout using LMDB.

  Provides fixed-latency frame storage and retrieval for the audio
  playout pipeline. Falls back to ETS when LMDB is not available.

  ## Usage

      # Start with default 50-frame capacity (1 second of Opus audio)
      {:ok, pid} = Burble.Media.LMDBPlayout.start_link(room_id: "room-123")

      # Write a frame
      :ok = Burble.Media.LMDBPlayout.write_frame(pid, 42, 1_000_000, <<opus_payload>>)

      # Read the next frame
      {:ok, {seq, timestamp, payload}} = Burble.Media.LMDBPlayout.read_next(pid)

  ## Configuration

      config :burble, Burble.Media.LMDBPlayout,
        capacity: 50,                  # frames (default: 50 = 1 second)
        data_dir: "priv/lmdb_playout", # LMDB data directory
        map_size: 10_485_760           # 10 MB LMDB map size
  """

  use GenServer

  require Logger

  # Module atoms for optional LMDB dependencies — referenced via apply/3
  # to avoid compile-time warnings when these NIFs are not installed.
  @exlmdb :"Elixir.Exlmdb"
  @lmdb :lmdb

  # ── Types ──

  @typedoc "Audio frame as stored in the ring buffer."
  @type frame :: {seq :: non_neg_integer(), timestamp_us :: non_neg_integer(), payload :: binary()}

  @typedoc "Backend implementation: :lmdb (preferred) or :ets (fallback)."
  @type backend :: :lmdb | :ets

  # Default ring buffer capacity: 50 frames = 1 second at 20ms per Opus frame.
  @default_capacity 50

  # Default LMDB map size: 10 MB (more than enough for audio frames).
  @default_map_size 10_485_760

  # Default data directory for LMDB files.
  @default_data_dir "priv/lmdb_playout"

  # ── Client API ──

  @doc """
  Start the playout buffer for a specific room.

  Options:
    - `:room_id` — room identifier (used for LMDB subdirectory and ETS table naming)
    - `:capacity` — ring buffer size in frames (default: 50)
    - `:data_dir` — LMDB data directory (default: "priv/lmdb_playout")
    - `:map_size` — LMDB map size in bytes (default: 10 MB)
    - `:backend` — force `:lmdb` or `:ets` (default: auto-detect)
    - `:name` — GenServer name (default: via Registry)
  """
  def start_link(opts) do
    room_id = Keyword.fetch!(opts, :room_id)
    name = Keyword.get(opts, :name, via_name(room_id))
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Write an audio frame into the ring buffer.

  Parameters:
    - `server` — PID or registered name of the playout buffer
    - `seq` — sequence number (monotonically increasing per stream)
    - `timestamp_us` — frame timestamp in microseconds (for synchronisation)
    - `payload` — raw Opus audio payload (binary)

  If the buffer is full, the oldest frame is overwritten (ring semantics).
  Returns `:ok`.
  """
  @spec write_frame(GenServer.server(), non_neg_integer(), non_neg_integer(), binary()) :: :ok
  def write_frame(server, seq, timestamp_us, payload) do
    GenServer.call(server, {:write_frame, seq, timestamp_us, payload})
  end

  @doc """
  Read the next frame from the buffer (ordered by sequence number).

  Returns `{:ok, {seq, timestamp_us, payload}}` or `{:empty, nil}` if
  the buffer has no unread frames.

  The read cursor advances past the returned frame so it won't be
  returned again.
  """
  @spec read_next(GenServer.server()) :: {:ok, frame()} | {:empty, nil}
  def read_next(server) do
    GenServer.call(server, :read_next)
  end

  @doc """
  Peek at the next frame without advancing the read cursor.

  Returns `{:ok, {seq, timestamp_us, payload}}` or `{:empty, nil}`.
  """
  @spec peek(GenServer.server()) :: {:ok, frame()} | {:empty, nil}
  def peek(server) do
    GenServer.call(server, :peek)
  end

  @doc """
  Get the current buffer status.

  Returns a map with:
    - `:backend` — :lmdb or :ets
    - `:capacity` — max frames
    - `:frame_count` — current frames in buffer
    - `:write_cursor` — next write position
    - `:read_cursor` — next read position
    - `:room_id` — the room this buffer belongs to
  """
  @spec status(GenServer.server()) :: map()
  def status(server) do
    GenServer.call(server, :status)
  end

  @doc """
  Flush all frames from the buffer.

  Resets both read and write cursors. Use when a participant leaves
  or the room audio state needs to be reset.
  """
  @spec flush(GenServer.server()) :: :ok
  def flush(server) do
    GenServer.call(server, :flush)
  end

  @doc """
  Read all currently buffered frames as an ordered list.

  Returns frames ordered by sequence number, from oldest to newest.
  Does NOT advance the read cursor (non-destructive read).
  """
  @spec drain(GenServer.server()) :: [frame()]
  def drain(server) do
    GenServer.call(server, :drain)
  end

  # ── Server Callbacks ──

  @impl true
  def init(opts) do
    room_id = Keyword.fetch!(opts, :room_id)
    app_config = Application.get_env(:burble, __MODULE__, [])

    capacity =
      Keyword.get(opts, :capacity, Keyword.get(app_config, :capacity, @default_capacity))

    data_dir =
      Keyword.get(opts, :data_dir, Keyword.get(app_config, :data_dir, @default_data_dir))

    map_size =
      Keyword.get(opts, :map_size, Keyword.get(app_config, :map_size, @default_map_size))

    forced_backend = Keyword.get(opts, :backend, nil)

    # Detect available backend.
    backend = detect_backend(forced_backend, data_dir, room_id, map_size)

    # Initialise the backend-specific state.
    backend_state = init_backend(backend, room_id, data_dir, map_size)

    state = %{
      room_id: room_id,
      capacity: capacity,
      backend: backend,
      backend_state: backend_state,
      # Write cursor: next sequence position to write (slot index = seq mod capacity).
      write_cursor: 0,
      # Read cursor: next sequence position to read.
      read_cursor: 0,
      # Total frames written (for statistics).
      frames_written: 0,
      # Total frames read.
      frames_read: 0,
      # Total frames overwritten (evicted by ring overflow).
      frames_evicted: 0
    }

    Logger.info(
      "[LMDBPlayout] Started for room #{room_id} (backend: #{backend}, capacity: #{capacity})"
    )

    {:ok, state}
  end

  @impl true
  def handle_call({:write_frame, seq, timestamp_us, payload}, _from, state) do
    # Calculate the ring buffer slot for this frame.
    slot = rem(seq, state.capacity)

    # Check if we're overwriting an existing frame (ring overflow).
    evicted =
      if state.frames_written >= state.capacity and
           slot_occupied?(state.backend, state.backend_state, slot) do
        1
      else
        0
      end

    # Write the frame to the backend.
    frame_data = {seq, timestamp_us, payload}
    :ok = backend_write(state.backend, state.backend_state, slot, frame_data)

    new_state = %{
      state
      | write_cursor: seq + 1,
        frames_written: state.frames_written + 1,
        frames_evicted: state.frames_evicted + evicted
    }

    # If the read cursor falls behind the write cursor by more than capacity,
    # advance it to prevent reading stale/overwritten data.
    new_state =
      if new_state.write_cursor - new_state.read_cursor > state.capacity do
        %{new_state | read_cursor: new_state.write_cursor - state.capacity}
      else
        new_state
      end

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:read_next, _from, state) do
    if state.read_cursor >= state.write_cursor do
      # No unread frames.
      {:reply, {:empty, nil}, state}
    else
      slot = rem(state.read_cursor, state.capacity)

      case backend_read(state.backend, state.backend_state, slot) do
        {:ok, {seq, timestamp_us, payload}} ->
          new_state = %{
            state
            | read_cursor: state.read_cursor + 1,
              frames_read: state.frames_read + 1
          }

          {:reply, {:ok, {seq, timestamp_us, payload}}, new_state}

        :not_found ->
          # Slot was evicted or not yet written — advance cursor and retry.
          {:reply, {:empty, nil}, %{state | read_cursor: state.read_cursor + 1}}
      end
    end
  end

  @impl true
  def handle_call(:peek, _from, state) do
    if state.read_cursor >= state.write_cursor do
      {:reply, {:empty, nil}, state}
    else
      slot = rem(state.read_cursor, state.capacity)

      case backend_read(state.backend, state.backend_state, slot) do
        {:ok, frame} -> {:reply, {:ok, frame}, state}
        :not_found -> {:reply, {:empty, nil}, state}
      end
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    frame_count = max(0, min(state.write_cursor - state.read_cursor, state.capacity))

    status = %{
      backend: state.backend,
      capacity: state.capacity,
      frame_count: frame_count,
      write_cursor: state.write_cursor,
      read_cursor: state.read_cursor,
      room_id: state.room_id,
      frames_written: state.frames_written,
      frames_read: state.frames_read,
      frames_evicted: state.frames_evicted
    }

    {:reply, status, state}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    backend_flush(state.backend, state.backend_state)

    new_state = %{
      state
      | write_cursor: 0,
        read_cursor: 0,
        frames_written: 0,
        frames_read: 0,
        frames_evicted: 0
    }

    Logger.debug("[LMDBPlayout] Flushed buffer for room #{state.room_id}")
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:drain, _from, state) do
    frames =
      state.read_cursor..(state.write_cursor - 1)//1
      |> Enum.reduce([], fn cursor, acc ->
        slot = rem(cursor, state.capacity)

        case backend_read(state.backend, state.backend_state, slot) do
          {:ok, frame} -> [frame | acc]
          :not_found -> acc
        end
      end)
      |> Enum.reverse()

    {:reply, frames, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Clean up backend resources.
    backend_close(state.backend, state.backend_state)
    Logger.info("[LMDBPlayout] Stopped for room #{state.room_id}")
    :ok
  end

  # ── Private: Backend detection ──

  # Detect whether the LMDB NIF is available, falling back to ETS.
  #
  # We check for the `Exlmdb` module (Elixir LMDB NIF binding).
  # If not loaded, we use ETS as a functional fallback.
  @spec detect_backend(atom() | nil, String.t(), String.t(), non_neg_integer()) :: backend()
  defp detect_backend(:ets, _data_dir, _room_id, _map_size), do: :ets
  defp detect_backend(:lmdb, _data_dir, _room_id, _map_size), do: :lmdb

  defp detect_backend(nil, data_dir, room_id, _map_size) do
    # Check if the LMDB NIF module is available.
    if Code.ensure_loaded?(@lmdb) or Code.ensure_loaded?(@exlmdb) do
      # Verify we can actually create the data directory.
      room_dir = Path.join(data_dir, room_id)

      case File.mkdir_p(room_dir) do
        :ok ->
          Logger.info("[LMDBPlayout] LMDB backend available for room #{room_id}")
          :lmdb

        {:error, reason} ->
          Logger.warning(
            "[LMDBPlayout] Cannot create LMDB dir #{room_dir}: #{inspect(reason)}, falling back to ETS"
          )

          :ets
      end
    else
      Logger.info("[LMDBPlayout] LMDB NIF not available, using ETS fallback")
      :ets
    end
  end

  # ── Private: Backend initialisation ──

  @spec init_backend(backend(), String.t(), String.t(), non_neg_integer()) :: term()
  defp init_backend(:lmdb, room_id, data_dir, map_size) do
    room_dir = Path.join(data_dir, room_id)
    File.mkdir_p!(room_dir)

    # Open the LMDB environment.
    # :lmdb is the Erlang NIF wrapper; Exlmdb is the Elixir wrapper.
    # We try both to support different packaging.
    env =
      cond do
        Code.ensure_loaded?(@exlmdb) ->
          {:ok, env} =
            apply(@exlmdb, :open, [String.to_charlist(room_dir),
              [mapsize: map_size,
              maxdbs: 1,
              flags: [:nosubdir]]
            ])

          env

        Code.ensure_loaded?(@lmdb) ->
          {:ok, env} =
            apply(@lmdb, :env_open, [String.to_charlist(room_dir), [
              {:mapsize, map_size},
              {:maxdbs, 1}
            ]])

          env

        true ->
          raise "LMDB NIF not available but :lmdb backend was selected"
      end

    %{env: env, room_dir: room_dir}
  end

  defp init_backend(:ets, _room_id, _data_dir, _map_size) do
    # Create an unnamed ETS table for the fallback backend.
    # Uses table reference (tid) instead of atom name to avoid unbounded
    # atom creation from room IDs. :set for O(1) slot-based access.
    table = create_ets_table()

    %{table: table}
  end

  # ── Private: Backend operations ──

  # Write a frame to the backend at the given slot.
  @spec backend_write(backend(), term(), non_neg_integer(), frame()) :: :ok
  defp backend_write(:lmdb, backend_state, slot, frame_data) do
    %{env: env} = backend_state
    key = :erlang.term_to_binary(slot)
    value = :erlang.term_to_binary(frame_data)

    # Use a read-write transaction for the write.
    cond do
      Code.ensure_loaded?(@exlmdb) ->
        {:ok, txn} = apply(@exlmdb, :txn_begin, [env])
        {:ok, dbi} = apply(@exlmdb, :dbi_open, [txn, nil])
        :ok = apply(@exlmdb, :put, [txn, dbi, key, value])
        :ok = apply(@exlmdb, :txn_commit, [txn])

      Code.ensure_loaded?(@lmdb) ->
        {:ok, txn} = apply(@lmdb, :txn_begin, [env])
        {:ok, dbi} = apply(@lmdb, :dbi_open, [txn, :undefined])
        :ok = apply(@lmdb, :put, [txn, dbi, key, value])
        :ok = apply(@lmdb, :txn_commit, [txn])
    end

    :ok
  end

  defp backend_write(:ets, backend_state, slot, frame_data) do
    :ets.insert(backend_state.table, {slot, frame_data})
    :ok
  end

  # Read a frame from the backend at the given slot.
  @spec backend_read(backend(), term(), non_neg_integer()) :: {:ok, frame()} | :not_found
  defp backend_read(:lmdb, backend_state, slot) do
    %{env: env} = backend_state
    key = :erlang.term_to_binary(slot)

    result =
      cond do
        Code.ensure_loaded?(@exlmdb) ->
          {:ok, txn} = apply(@exlmdb, :txn_begin, [env, [:rdonly]])
          {:ok, dbi} = apply(@exlmdb, :dbi_open, [txn, nil])
          res = apply(@exlmdb, :get, [txn, dbi, key])
          apply(@exlmdb, :txn_abort, [txn])
          res

        Code.ensure_loaded?(@lmdb) ->
          {:ok, txn} = apply(@lmdb, :txn_begin, [env, [:rdonly]])
          {:ok, dbi} = apply(@lmdb, :dbi_open, [txn, :undefined])
          res = apply(@lmdb, :get, [txn, dbi, key])
          apply(@lmdb, :txn_abort, [txn])
          res
      end

    case result do
      {:ok, value_bin} ->
        frame_data = :erlang.binary_to_term(value_bin)
        {:ok, frame_data}

      :not_found ->
        :not_found
    end
  end

  defp backend_read(:ets, backend_state, slot) do
    case :ets.lookup(backend_state.table, slot) do
      [{^slot, frame_data}] -> {:ok, frame_data}
      [] -> :not_found
    end
  end

  # Check if a slot is occupied in the backend.
  @spec slot_occupied?(backend(), term(), non_neg_integer()) :: boolean()
  defp slot_occupied?(:ets, backend_state, slot) do
    :ets.member(backend_state.table, slot)
  end

  defp slot_occupied?(:lmdb, backend_state, slot) do
    case backend_read(:lmdb, backend_state, slot) do
      {:ok, _} -> true
      :not_found -> false
    end
  end

  # Flush all data from the backend.
  @spec backend_flush(backend(), term()) :: :ok
  defp backend_flush(:lmdb, backend_state) do
    %{env: env} = backend_state

    cond do
      Code.ensure_loaded?(@exlmdb) ->
        {:ok, txn} = apply(@exlmdb, :txn_begin, [env])
        {:ok, dbi} = apply(@exlmdb, :dbi_open, [txn, nil])
        apply(@exlmdb, :drop, [txn, dbi])
        apply(@exlmdb, :txn_commit, [txn])

      Code.ensure_loaded?(@lmdb) ->
        {:ok, txn} = apply(@lmdb, :txn_begin, [env])
        {:ok, dbi} = apply(@lmdb, :dbi_open, [txn, :undefined])
        apply(@lmdb, :drop, [txn, dbi])
        apply(@lmdb, :txn_commit, [txn])
    end

    :ok
  end

  defp backend_flush(:ets, backend_state) do
    :ets.delete_all_objects(backend_state.table)
    :ok
  end

  # Close backend resources on shutdown.
  @spec backend_close(backend(), term()) :: :ok
  defp backend_close(:lmdb, backend_state) do
    %{env: env} = backend_state

    cond do
      Code.ensure_loaded?(@exlmdb) -> apply(@exlmdb, :close, [env])
      Code.ensure_loaded?(@lmdb) -> apply(@lmdb, :env_close, [env])
    end

    :ok
  rescue
    # Environment may already be closed if the NIF was unloaded.
    _ -> :ok
  end

  defp backend_close(:ets, backend_state) do
    try do
      :ets.delete(backend_state.table)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  # ── Private: Naming helpers ──

  # Generate a Registry-based via tuple for process naming.
  @spec via_name(String.t()) :: {:via, Registry, {atom(), String.t()}}
  defp via_name(room_id) do
    {:via, Registry, {Burble.RoomRegistry, {:lmdb_playout, room_id}}}
  end

  # Create an ETS table for a room's fallback buffer.
  # Returns the table reference (tid), avoiding atom creation entirely.
  # The table reference is stored in GenServer state, not looked up by name.
  @spec create_ets_table() :: :ets.tid()
  defp create_ets_table do
    :ets.new(:burble_playout, [:ordered_set, :public])
  end
end
