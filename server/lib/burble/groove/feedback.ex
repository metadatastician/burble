# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Burble.Groove.Feedback — Groove-routed feedback receiver.
#
# Accepts feedback events routed through the Groove mesh and stores them
# locally. Any groove-connected service can POST feedback targeted at
# Burble via POST /.well-known/groove/feedback.
#
# Feedback Schema:
#   {
#     "type": "feedback",
#     "target_service": "burble",
#     "category": "bug" | "feature" | "ux" | "performance" | "other",
#     "message": "Description of the feedback",
#     "metadata": { ... }
#   }
#
# Storage: ETS table (:groove_feedback) with timestamp-based keys.
# Retrieval: Burble.Groove.Feedback.list/0 returns all stored feedback.

defmodule Burble.Groove.Feedback do
  @moduledoc """
  Receives and stores feedback routed through the Groove mesh.

  Feedback events arrive via POST /.well-known/groove/feedback and are
  stored in an ETS table for retrieval by operators or downstream
  analytics.
  """

  use GenServer

  require Logger

  @table :groove_feedback

  # Maximum stored feedback entries (oldest evicted first).
  @max_entries 10_000

  # Valid feedback categories.
  @valid_categories ~w(bug feature ux performance other)

  # --- Client API ---

  @doc "Start the feedback store."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Accept a feedback event from the Groove mesh.

  Validates the event structure and stores it. Returns `{:ok, id}` on
  success or `{:error, reason}` on validation failure.
  """
  @spec accept(map()) :: {:ok, String.t()} | {:error, String.t()}
  def accept(event) when is_map(event) do
    GenServer.call(__MODULE__, {:accept, event})
  end

  @doc "List all stored feedback entries (most recent first)."
  @spec list() :: list(map())
  def list do
    GenServer.call(__MODULE__, :list)
  end

  @doc "Return the count of stored feedback entries."
  @spec count() :: non_neg_integer()
  def count do
    GenServer.call(__MODULE__, :count)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    :ets.new(@table, [:ordered_set, :named_table, :public, read_concurrency: true])
    {:ok, %{count: 0}}
  end

  @impl true
  def handle_call({:accept, event}, _from, state) do
    category = Map.get(event, "category", "other")

    unless category in @valid_categories do
      {:reply, {:error, "invalid category: #{category}"}, state}
    else
      now_ms = System.system_time(:millisecond)

      id = "groove-feedback-#{now_ms}-#{:rand.uniform(999_999)}"

      entry = %{
        id: id,
        timestamp_ms: now_ms,
        source_service: Map.get(event, "source_service", "unknown"),
        target_service: Map.get(event, "target_service", "burble"),
        category: category,
        message: Map.get(event, "message", ""),
        metadata: Map.get(event, "metadata", %{})
      }

      :ets.insert(@table, {now_ms, entry})

      # Evict oldest if we exceed the limit.
      new_count = state.count + 1

      if new_count > @max_entries do
        case :ets.first(@table) do
          :"$end_of_table" -> :ok
          key -> :ets.delete(@table, key)
        end
      end

      Logger.info("[Groove.Feedback] Accepted feedback #{id} (category=#{category})")

      {:reply, {:ok, id}, %{state | count: min(new_count, @max_entries)}}
    end
  end

  @impl true
  def handle_call(:list, _from, state) do
    entries =
      :ets.tab2list(@table)
      |> Enum.map(fn {_key, entry} -> entry end)
      |> Enum.reverse()

    {:reply, entries, state}
  end

  @impl true
  def handle_call(:count, _from, state) do
    {:reply, state.count, state}
  end
end
