# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)

defmodule Burble.Store.BackupScheduler do
  @moduledoc """
  Periodic VeriSimDB backup scheduler.

  Runs `Burble.Store.Backup.run/1` on a fixed interval, then prunes the
  backup directory down to the configured retention count. Failures are
  logged but never crash the scheduler — the next tick is always scheduled.

  ## Configuration

      config :burble, Burble.Store.BackupScheduler,
        enabled: true,
        interval_ms: :timer.hours(24),
        dir: "/var/backups/burble",
        retention_count: 14,
        run_on_startup: false,
        startup_delay_ms: 30_000

  When `enabled: false` the GenServer still starts (so `status/0` works) but
  no backups are scheduled. This is the default in `:test`.
  """

  use GenServer
  require Logger

  alias Burble.Store.Backup

  @default_interval_ms :timer.hours(24)
  @default_retention 14
  @default_startup_delay_ms 30_000

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Trigger an immediate backup. Returns the result synchronously."
  @spec run_now() :: {:ok, Backup.result()} | {:error, term()}
  def run_now do
    GenServer.call(__MODULE__, :run_now, 120_000)
  end

  @doc "Return the scheduler's current status snapshot."
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    cfg = load_config()

    if cfg.enabled do
      delay = if cfg.run_on_startup, do: cfg.startup_delay_ms, else: cfg.interval_ms
      Process.send_after(self(), :backup, delay)

      Logger.info(
        "[BackupScheduler] enabled — first run in #{delay}ms, " <>
          "interval #{cfg.interval_ms}ms, dir #{cfg.dir}, retention #{cfg.retention_count}"
      )
    else
      Logger.info("[BackupScheduler] disabled (set :enabled true to schedule backups)")
    end

    {:ok,
     %{
       config: cfg,
       last_run_at: nil,
       last_status: :never_run,
       last_path: nil,
       last_error: nil,
       last_octad_count: nil,
       last_byte_size: nil,
       last_duration_ms: nil,
       run_count: 0
     }}
  end

  @impl true
  def handle_call(:status, _from, state) do
    snapshot = %{
      enabled: state.config.enabled,
      interval_ms: state.config.interval_ms,
      dir: state.config.dir,
      retention_count: state.config.retention_count,
      last_run_at: state.last_run_at,
      last_status: state.last_status,
      last_path: state.last_path,
      last_error: maybe_inspect(state.last_error),
      last_octad_count: state.last_octad_count,
      last_byte_size: state.last_byte_size,
      last_duration_ms: state.last_duration_ms,
      run_count: state.run_count,
      backup_count: length(Backup.list(state.config.dir))
    }

    {:reply, snapshot, state}
  end

  @impl true
  def handle_call(:run_now, _from, state) do
    {result, new_state} = do_backup(state)
    {:reply, result, new_state}
  end

  @impl true
  def handle_info(:backup, state) do
    {_result, new_state} = do_backup(state)

    if new_state.config.enabled do
      Process.send_after(self(), :backup, new_state.config.interval_ms)
    end

    {:noreply, new_state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp do_backup(state) do
    cfg = state.config
    now = DateTime.utc_now()

    case safe_run(cfg) do
      {:ok, result} ->
        Backup.prune(cfg.dir, cfg.retention_count)

        new_state = %{
          state
          | last_run_at: now,
            last_status: :ok,
            last_path: result.path,
            last_error: nil,
            last_octad_count: result.octad_count,
            last_byte_size: result.byte_size,
            last_duration_ms: result.duration_ms,
            run_count: state.run_count + 1
        }

        {{:ok, result}, new_state}

      {:error, reason} = err ->
        new_state = %{
          state
          | last_run_at: now,
            last_status: :error,
            last_error: reason,
            run_count: state.run_count + 1
        }

        {err, new_state}
    end
  end

  defp safe_run(cfg) do
    Backup.run(dir: cfg.dir, store: cfg.store, per_prefix_limit: cfg.per_prefix_limit)
  rescue
    e ->
      Logger.error("[BackupScheduler] crashed: #{Exception.message(e)}")
      {:error, {:exception, Exception.message(e)}}
  catch
    kind, value ->
      Logger.error("[BackupScheduler] caught #{kind}: #{inspect(value)}")
      {:error, {kind, value}}
  end

  defp load_config do
    raw = Application.get_env(:burble, __MODULE__, [])

    %{
      enabled: Keyword.get(raw, :enabled, true),
      interval_ms: Keyword.get(raw, :interval_ms, @default_interval_ms),
      dir: Keyword.get(raw, :dir, Backup.default_dir()),
      retention_count: Keyword.get(raw, :retention_count, @default_retention),
      run_on_startup: Keyword.get(raw, :run_on_startup, false),
      startup_delay_ms: Keyword.get(raw, :startup_delay_ms, @default_startup_delay_ms),
      store: Keyword.get(raw, :store, Burble.Store),
      per_prefix_limit: Keyword.get(raw, :per_prefix_limit, 10_000)
    }
  end

  defp maybe_inspect(nil), do: nil
  defp maybe_inspect(other), do: inspect(other)
end
