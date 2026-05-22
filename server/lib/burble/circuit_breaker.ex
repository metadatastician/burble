# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)

defmodule Burble.CircuitBreaker do
  @moduledoc """
  Generic ETS-backed circuit breaker. No GenServer, no dependencies.

  Each breaker is identified by an atom name. The breaker tracks consecutive
  failures; once `failure_threshold` is reached the circuit opens and
  `with_breaker/2` short-circuits to `{:error, :circuit_open}` for
  `open_duration_ms`. After that window a single probe is permitted
  (half-open); success closes the circuit, failure re-opens it.

  Telemetry events emitted (measurements may include `failures`, `consecutive`):
    * `[:burble, :circuit_breaker, :open]`         — `%{name: atom}`
    * `[:burble, :circuit_breaker, :close]`        — `%{name: atom}`
    * `[:burble, :circuit_breaker, :half_open]`    — `%{name: atom}`
    * `[:burble, :circuit_breaker, :reject]`       — `%{name: atom}`

  ## Example

      Burble.CircuitBreaker.register(:my_api, failure_threshold: 5, open_duration_ms: 30_000)

      Burble.CircuitBreaker.with_breaker(:my_api, fn ->
        SomeApi.call()
      end)

      # => {:ok, result} | {:error, reason} | {:error, :circuit_open}
  """

  require Logger

  @table :burble_circuit_breakers

  @default_failure_threshold 5
  @default_open_duration_ms 30_000

  @type name :: atom()
  @type state :: :closed | :half_open | :open
  @type opts :: [failure_threshold: pos_integer(), open_duration_ms: pos_integer()]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Register a breaker. Idempotent; calling twice with different opts updates
  the configuration but preserves any in-flight failure count.
  """
  @spec register(name(), opts()) :: :ok
  def register(name, opts \\ []) when is_atom(name) do
    ensure_table()

    config = %{
      failure_threshold: Keyword.get(opts, :failure_threshold, @default_failure_threshold),
      open_duration_ms: Keyword.get(opts, :open_duration_ms, @default_open_duration_ms)
    }

    :ets.insert(@table, {{name, :config}, config})
    :ok
  end

  @doc """
  Run `fun` under the breaker named `name`.

  Returns the function's return value untouched on success, or
  `{:error, :circuit_open}` if the breaker is open.

  Treats `{:error, _}` and exceptions as failures; everything else as success.
  Auto-registers the breaker with defaults if it has not been registered.
  """
  @spec with_breaker(name(), (-> term())) :: term() | {:error, :circuit_open}
  def with_breaker(name, fun) when is_atom(name) and is_function(fun, 0) do
    ensure_table()
    ensure_registered(name)

    case state(name) do
      :open ->
        :telemetry.execute([:burble, :circuit_breaker, :reject], %{count: 1}, %{name: name})
        {:error, :circuit_open}

      st when st in [:closed, :half_open] ->
        if st == :half_open do
          :telemetry.execute([:burble, :circuit_breaker, :half_open], %{count: 1}, %{name: name})
        end

        try do
          result = fun.()
          classify_and_record(name, result)
          result
        rescue
          e ->
            record_failure(name)
            reraise e, __STACKTRACE__
        catch
          kind, value ->
            record_failure(name)
            :erlang.raise(kind, value, __STACKTRACE__)
        end
    end
  end

  @doc "Current state of the breaker: `:closed`, `:half_open`, or `:open`."
  @spec state(name()) :: state()
  def state(name) when is_atom(name) do
    ensure_table()
    {failures, opened_at} = read_counters(name)
    threshold = config(name).failure_threshold
    open_ms = config(name).open_duration_ms

    cond do
      is_integer(opened_at) ->
        elapsed = System.monotonic_time(:millisecond) - opened_at
        if elapsed >= open_ms, do: :half_open, else: :open

      failures >= threshold ->
        :open

      true ->
        :closed
    end
  end

  @doc "Manually reset the breaker to `:closed` (e.g. after fixing an outage)."
  @spec reset(name()) :: :ok
  def reset(name) when is_atom(name) do
    ensure_table()
    :ets.insert(@table, {{name, :failures}, 0})
    :ets.delete(@table, {name, :opened_at})
    :telemetry.execute([:burble, :circuit_breaker, :close], %{count: 1}, %{name: name})
    :ok
  end

  @doc "Record a successful call (closes the circuit if half-open)."
  @spec record_success(name()) :: :ok
  def record_success(name) when is_atom(name) do
    ensure_table()
    {_failures, opened_at} = read_counters(name)
    :ets.insert(@table, {{name, :failures}, 0})
    :ets.delete(@table, {name, :opened_at})

    if is_integer(opened_at) do
      :telemetry.execute([:burble, :circuit_breaker, :close], %{count: 1}, %{name: name})
    end

    :ok
  end

  @doc "Record a failed call. Opens the circuit if the threshold is reached."
  @spec record_failure(name()) :: :ok
  def record_failure(name) when is_atom(name) do
    ensure_table()
    threshold = config(name).failure_threshold

    new_count =
      :ets.update_counter(@table, {name, :failures}, {2, 1}, {{name, :failures}, 0})

    if new_count >= threshold do
      now = System.monotonic_time(:millisecond)
      # Only emit :open the first time we cross the threshold.
      case :ets.lookup(@table, {name, :opened_at}) do
        [] ->
          :ets.insert(@table, {{name, :opened_at}, now})
          Logger.error("[CB:#{name}] Circuit OPEN after #{new_count} consecutive failures")

          :telemetry.execute([:burble, :circuit_breaker, :open], %{consecutive: new_count}, %{
            name: name
          })

        [{_, _existing}] ->
          # Half-open probe failed; bump the open timer.
          :ets.insert(@table, {{name, :opened_at}, now})
      end
    end

    :ok
  end

  @doc """
  Return a snapshot of every registered breaker as `%{name => %{state, failures, ...}}`.

  Useful for `/health` endpoints and operational dashboards.
  """
  @spec snapshot() :: %{name() => %{state: state(), failures: non_neg_integer()}}
  def snapshot do
    ensure_table()

    @table
    |> :ets.tab2list()
    |> Enum.flat_map(fn
      {{name, :config}, _cfg} -> [name]
      _ -> []
    end)
    |> Enum.uniq()
    |> Map.new(fn name ->
      {failures, opened_at} = read_counters(name)
      {name, %{state: state(name), failures: failures, opened_at: opened_at}}
    end)
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [
            :set,
            :public,
            :named_table,
            read_concurrency: true,
            write_concurrency: true
          ])
        rescue
          # raced with another process; table already exists
          ArgumentError -> :ok
        end

        :ok

      _ ->
        :ok
    end
  end

  defp ensure_registered(name) do
    case :ets.lookup(@table, {name, :config}) do
      [] -> register(name, [])
      _ -> :ok
    end
  end

  defp config(name) do
    case :ets.lookup(@table, {name, :config}) do
      [{_, cfg}] ->
        cfg

      [] ->
        %{
          failure_threshold: @default_failure_threshold,
          open_duration_ms: @default_open_duration_ms
        }
    end
  end

  defp read_counters(name) do
    failures =
      case :ets.lookup(@table, {name, :failures}) do
        [{_, n}] -> n
        [] -> 0
      end

    opened_at =
      case :ets.lookup(@table, {name, :opened_at}) do
        [{_, t}] -> t
        [] -> nil
      end

    {failures, opened_at}
  end

  defp classify_and_record(name, {:error, _}), do: record_failure(name)
  defp classify_and_record(name, :error), do: record_failure(name)
  defp classify_and_record(name, _other), do: record_success(name)
end
