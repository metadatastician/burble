# SPDX-License-Identifier: MPL-2.0
#
# Burble.Chat.MessageStore — In-memory message store backed by ETS.
#
# Provides fast in-process storage for real-time text messages in a room.
# Messages are NOT persisted across restarts — this is by design (ephemeral
# chat alongside the voice session). For archival storage, messages are also
# forwarded through NNTPSBackend.
#
# Design notes:
#   - ETS table is owned by this GenServer so it dies with the process.
#   - Per-room message lists are stored as reversed insertion-order lists
#     (newest first) so get_messages/2 is O(limit) rather than O(n).
#   - A hard cap of @max_messages_per_room evicts the oldest messages when
#     exceeded. Eviction is done at write time (amortised O(1)).
#
# Usage:
#   Burble.Chat.MessageStore.store_message(room_id, msg)
#   Burble.Chat.MessageStore.get_messages(room_id, 50)
#   Burble.Chat.MessageStore.clear_room(room_id)

defmodule Burble.Chat.MessageStore do
  @moduledoc """
  ETS-backed in-memory store for room text messages.

  ## Message shape

  Messages are plain maps with the following keys:
  - `:id` — unique message ID (hex string)
  - `:from` — user_id of the sender
  - `:body` — message text (UTF-8 string)
  - `:timestamp` — `DateTime` (UTC) when the message was stored

  ## Capacity

  Each room is capped at 500 messages.
  When the cap is reached the oldest message is evicted.
  """

  use GenServer

  require Logger

  @table :burble_chat_messages
  @max_messages_per_room 500

  # ── Client API ──

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Store a message in the given room.

  `msg` must be a map with at least `:id`, `:from`, `:body`, and `:timestamp`.
  Returns `:ok`.
  """
  @spec store_message(String.t(), map()) :: :ok
  def store_message(room_id, msg) do
    GenServer.call(__MODULE__, {:store, room_id, msg})
  end

  @doc """
  Return the last `limit` messages from a room, newest first.

  Returns an empty list if the room has no messages or does not exist.
  """
  @spec get_messages(String.t(), pos_integer()) :: [map()]
  def get_messages(room_id, limit \\ 50) do
    case :ets.lookup(@table, room_id) do
      [{^room_id, messages}] -> Enum.take(messages, limit)
      [] -> []
    end
  end

  @doc """
  Delete all messages for a room (e.g. when the room is destroyed).
  """
  @spec clear_room(String.t()) :: :ok
  def clear_room(room_id) do
    GenServer.call(__MODULE__, {:clear, room_id})
  end

  # ── GenServer callbacks ──

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, read_concurrency: true])
    Logger.debug("[MessageStore] ETS table created: #{table}")
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:store, room_id, msg}, _from, state) do
    messages =
      case :ets.lookup(@table, room_id) do
        [{^room_id, existing}] -> existing
        [] -> []
      end

    # Prepend new message (newest-first order) and enforce cap.
    updated =
      [msg | messages]
      |> Enum.take(@max_messages_per_room)

    :ets.insert(@table, {room_id, updated})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:clear, room_id}, _from, state) do
    :ets.delete(@table, room_id)
    {:reply, :ok, state}
  end
end
