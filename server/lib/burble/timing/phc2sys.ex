# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
#
# Burble.Timing.Phc2sys — optional phc2sys supervisor.
#
# Launches phc2sys when /dev/ptp0 is present and phc2sys is not already
# running. Keeps the OS clock tightly aligned with the PTP hardware clock so
# that Burble.Timing.PTP sees a :phc2sys clock source rather than falling back
# to NTP or the bare system clock.
#
# Design decisions:
#
#   • auto_start defaults to false — safe for containers and CI runners that
#     have no PTP hardware and no desire to have us fork processes.
#   • In Mix :test env the option is forced to false regardless of config, so
#     the test suite never spawns a real phc2sys binary.
#   • All phc2sys arguments are hardcoded; no user input reaches Port.open.
#   • If the phc2sys binary is absent from PATH we return
#     {:error, :phc2sys_not_installed} from start_link rather than crashing.
#
# Author: Jonathan D.A. Jewell

defmodule Burble.Timing.Phc2sys do
  @moduledoc """
  Optional supervisor that launches `phc2sys` when PTP hardware is available.

  `phc2sys` continuously disciplines the Linux system clock from the PTP
  hardware clock (`/dev/ptp0`), typically achieving ~1 µs accuracy. This
  module manages its lifecycle so the rest of Burble can rely on an accurate
  system clock without manual administration.

  ## States

    - `:idle` — not running (auto_start false, /dev/ptp0 absent, or phc2sys
      already running externally)
    - `:ptp_absent` — `/dev/ptp0` does not exist on this host
    - `:already_running` — a phc2sys process is already running (we stay out
      of the way)
    - `{:running, port}` — we own a phc2sys port process

  ## Configuration

  In `config/config.exs` (or env-specific files):

      config :burble, Burble.Timing.Phc2sys,
        auto_start: true   # default: false

  The `auto_start` option can also be passed as a keyword argument to
  `start_link/1`, which takes precedence over application config.

  ## Safety

  - `auto_start` is **forced to false** in `Mix.env() == :test`.
  - phc2sys arguments are hardcoded; no user input reaches `Port.open`.
  - If `phc2sys` is not found in PATH, `start_link/1` returns
    `{:error, :phc2sys_not_installed}`.
  """

  use GenServer

  require Logger

  # Path to the PTP hardware clock device.
  @ptp_device_path "/dev/ptp0"

  # Hardcoded phc2sys arguments (SECURITY: never interpolate user input here).
  #   -s /dev/ptp0   — synchronise from the PTP hardware clock
  #   -O 0           — UTC offset 0 (no TAI→UTC correction; we want raw offset)
  #   -m             — log to stdout (captured by Port)
  @phc2sys_args ["-s", @ptp_device_path, "-O", "0", "-m"]

  # ── Types ──────────────────────────────────────────────────────────────────

  @typedoc "Supervisor state."
  @type phc2sys_state ::
          {:running, port()}
          | :idle
          | :ptp_absent
          | :already_running

  # ── Client API ─────────────────────────────────────────────────────────────

  @doc """
  Start the phc2sys supervisor GenServer.

  Options:
    - `:auto_start` — launch phc2sys if conditions are met (default: false)

  Returns `{:error, :phc2sys_not_installed}` if the binary is absent from PATH
  and `auto_start: true` was requested (we can detect absence early before
  forking).
  """
  @spec start_link(keyword()) :: GenServer.on_start() | {:error, :phc2sys_not_installed}
  def start_link(opts \\ []) do
    # Resolve effective auto_start before the GenServer starts so we can do
    # the phc2sys binary check synchronously and return a clean error.
    effective_auto_start = resolve_auto_start(opts)

    if effective_auto_start and not phc2sys_in_path?() do
      {:error, :phc2sys_not_installed}
    else
      {name, init_opts} = Keyword.pop(opts, :name, __MODULE__)
      GenServer.start_link(__MODULE__, init_opts, name: name)
    end
  end

  @doc """
  Return the current supervision state.

  Possible return values:

    - `{:running, port}` — phc2sys is running under our port
    - `:idle` — not started (auto_start false or conditions not met)
    - `:ptp_absent` — `/dev/ptp0` does not exist
    - `:already_running` — phc2sys was already running when we started

  """
  @spec status() :: phc2sys_state()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Stop the GenServer (and any owned phc2sys port).
  """
  @spec stop() :: :ok
  def stop do
    GenServer.stop(__MODULE__)
  end

  # ── Server Callbacks ───────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    # Trap exits so that {:EXIT, port, reason} messages are delivered to
    # handle_info/2 when the phc2sys port dies unexpectedly.
    Process.flag(:trap_exit, true)

    effective_auto_start = resolve_auto_start(opts)

    state = maybe_launch(effective_auto_start)

    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state, state}
  end

  # phc2sys port closed / exited.
  @impl true
  def handle_info({port, {:exit_status, code}}, {:running, port}) do
    Logger.warning("[Phc2sys] phc2sys exited with status #{code}; transitioning to :idle")
    {:noreply, :idle}
  end

  # Port sent a data message (stdout from phc2sys). Log at debug and ignore.
  @impl true
  def handle_info({port, {:data, data}}, {:running, port} = state) do
    Logger.debug("[Phc2sys] #{String.trim(data)}")
    {:noreply, state}
  end

  # Port closed without an exit_status (e.g. OS killed it).
  @impl true
  def handle_info({:EXIT, port, reason}, {:running, port}) do
    Logger.warning("[Phc2sys] phc2sys port exited: #{inspect(reason)}; transitioning to :idle")
    {:noreply, :idle}
  end

  # Ignore stray EXIT signals (e.g. from the port when we are already :idle).
  @impl true
  def handle_info({:EXIT, _port, _reason}, state) do
    {:noreply, state}
  end

  # Ignore any other messages.
  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, {:running, port}) do
    # Close the port so phc2sys receives SIGTERM/SIGHUP and dies with us.
    Port.close(port)
    :ok
  end

  @impl true
  def terminate(_reason, _state), do: :ok

  # ── Private helpers ────────────────────────────────────────────────────────

  # Determine the effective auto_start value, merging opts > app config >
  # default (false). In the :test Mix env we always force false.
  @spec resolve_auto_start(keyword()) :: boolean()
  defp resolve_auto_start(opts) do
    if Mix.env() == :test do
      false
    else
      app_config = Application.get_env(:burble, __MODULE__, [])

      Keyword.get(
        opts,
        :auto_start,
        Keyword.get(app_config, :auto_start, false)
      )
    end
  end

  # Main launch logic: check conditions and either open a port or stay idle.
  @spec maybe_launch(boolean()) :: phc2sys_state()
  defp maybe_launch(false) do
    Logger.info("[Phc2sys] auto_start is false; staying in :idle state")
    :idle
  end

  defp maybe_launch(true) do
    cond do
      not ptp_device_present?() ->
        Logger.warning(
          "[Phc2sys] auto_start requested but #{@ptp_device_path} does not exist on this host; " <>
            "skipping phc2sys launch. Attach PTP hardware or disable auto_start."
        )

        :ptp_absent

      phc2sys_running?() ->
        Logger.info("[Phc2sys] phc2sys already running; staying in :idle state (:already_running)")
        :already_running

      true ->
        launch_phc2sys()
    end
  end

  # Open a Port running phc2sys.  Assumes binary is in PATH (checked in
  # start_link/1 before we get here when auto_start is true).
  @spec launch_phc2sys() :: phc2sys_state()
  defp launch_phc2sys do
    # SECURITY: @phc2sys_args is a module-level constant — no user input.
    port =
      Port.open(
        {:spawn_executable, System.find_executable("phc2sys")},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:args, @phc2sys_args}
        ]
      )

    Logger.info("[Phc2sys] Launched phc2sys (port #{inspect(port)})")
    {:running, port}
  rescue
    e ->
      Logger.warning("[Phc2sys] Failed to launch phc2sys: #{inspect(e)}; staying in :idle state")
      :idle
  end

  # Return true when /dev/ptp0 (or the configured path) exists.
  @spec ptp_device_present?() :: boolean()
  defp ptp_device_present? do
    File.exists?(@ptp_device_path)
  end

  # Return true when a phc2sys process is already running.
  # SECURITY: hardcoded binary + hardcoded arguments; no user input.
  @spec phc2sys_running?() :: boolean()
  defp phc2sys_running? do
    case System.cmd("pgrep", ["-x", "phc2sys"], stderr_to_stdout: true) do
      {_output, 0} -> true
      _ -> false
    end
  rescue
    # pgrep not available on this system.
    _ -> false
  end

  # Return true when phc2sys binary exists somewhere in PATH.
  @spec phc2sys_in_path?() :: boolean()
  defp phc2sys_in_path? do
    System.find_executable("phc2sys") != nil
  end
end
