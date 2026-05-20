# SPDX-License-Identifier: PMPL-1.0-or-later
ExUnit.start()

{:ok, _apps} = Application.ensure_all_started(:burble)

# Singletons whose mid-run liveness this helper watches. Order is irrelevant.
required = [
  Burble.PubSub,
  Burble.Presence,
  Burble.RoomRegistry,
  Burble.RoomSupervisor,
  Burble.PeerRegistry,
  Burble.PeerSupervisor,
  Burble.CoprocessorRegistry,
  Burble.CoprocessorSupervisor,
  Burble.Chat.MessageStore,
  Burble.Text.NNTPSBackend,
  Burble.Media.Engine,
  Burble.Timing.PTP,
  Burble.Timing.ClockCorrelator,
  Burble.Timing.Alignment,
  Burble.Groove,
  Burble.Groove.HealthMesh,
  Burble.Groove.Feedback,
  Burble.Transport.RTSP,
  Burble.Bolt.Listener,
  BurbleWeb.Endpoint
]

# Boot-readiness probe: wait for each child to register its name and respond
# to `:sys.get_state` so `init/1` is complete and the callback mailbox is
# drained before any test runs. Deterministic precondition for the mid-run
# watcher below.
deadline = System.monotonic_time(:millisecond) + 5_000

await_registered = fn name ->
  Stream.repeatedly(fn ->
    case Process.whereis(name) do
      nil ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(5)
          :retry
        else
          :timeout
        end

      pid when is_pid(pid) ->
        {:ok, pid}
    end
  end)
  |> Enum.find(fn
    :retry -> false
    _ -> true
  end)
end

Enum.each(required, fn name ->
  case await_registered.(name) do
    {:ok, pid} ->
      try do
        :sys.get_state(pid, 1_000)
      catch
        :exit, reason ->
          raise "Burble test boot: #{inspect(name)} init not stable: #{inspect(reason)}"
      end

    :timeout ->
      raise "Burble test boot: #{inspect(name)} did not register within 5s"
  end
end)

# Mid-run singleton-death watcher (#62 bucket B instrumentation).
#
# The earlier diagnosis in #62 was that app-owned singletons are
# intermittently dead mid-run, causing the "(EXIT) no process" cascade
# despite the application booting cleanly. A static boot probe cannot
# detect that — it only verifies the start instant. This watcher monitors
# every singleton above and records each death + reason + timestamp. The
# watcher re-monitors after each death (the application supervisor
# normally restarts these as :one_for_one children), so a flapping
# singleton produces one death record per flap.
#
# At suite end we emit a stderr block listing all deaths. The block is
# advisory (does not fail the run) so it can be deployed without
# changing CI exit semantics until the owner is ready to enforce.
defmodule Burble.TestSupport.SingletonWatcher do
  use GenServer

  def start_link(names), do: GenServer.start_link(__MODULE__, names, name: __MODULE__)

  def freeze, do: GenServer.call(__MODULE__, :freeze, 5_000)

  @impl true
  def init(names) do
    start_ms = System.monotonic_time(:millisecond)

    refs =
      Enum.reduce(names, %{}, fn name, acc ->
        case Process.whereis(name) do
          pid when is_pid(pid) -> Map.put(acc, Process.monitor(pid), name)
          nil -> raise "SingletonWatcher: #{inspect(name)} not running at watch start"
        end
      end)

    {:ok, %{refs: refs, deaths: [], start_ms: start_ms, frozen?: false}}
  end

  # Snapshot the death list and stop accepting new deaths. Called from
  # ExUnit.after_suite so that the subsequent application-shutdown :DOWN
  # cascade is not recorded as mid-run instability.
  @impl true
  def handle_call(:freeze, _from, state) do
    {:reply, Enum.reverse(state.deaths), %{state | frozen?: true}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, %{frozen?: true} = state) do
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case Map.fetch(state.refs, ref) do
      {:ok, name} ->
        death = %{
          name: name,
          pid: pid,
          reason: reason,
          at_ms: System.monotonic_time(:millisecond) - state.start_ms
        }

        new_refs =
          case Process.whereis(name) do
            new_pid when is_pid(new_pid) and new_pid != pid ->
              state.refs
              |> Map.delete(ref)
              |> Map.put(Process.monitor(new_pid), name)

            _ ->
              Process.send_after(self(), {:rewatch, name}, 50)
              Map.delete(state.refs, ref)
          end

        {:noreply, %{state | refs: new_refs, deaths: [death | state.deaths]}}

      :error ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:rewatch, name}, %{frozen?: true} = state), do: {:noreply, state}

  def handle_info({:rewatch, name}, state) do
    new_refs =
      case Process.whereis(name) do
        pid when is_pid(pid) -> Map.put(state.refs, Process.monitor(pid), name)
        nil -> state.refs
      end

    {:noreply, %{state | refs: new_refs}}
  end
end

{:ok, _watcher} = Burble.TestSupport.SingletonWatcher.start_link(required)

ExUnit.after_suite(fn _result ->
  # Freeze the watcher before the BEAM begins application shutdown so the
  # subsequent normal-shutdown :DOWN cascade is not mistaken for instability.
  deaths =
    Burble.TestSupport.SingletonWatcher.freeze()
    # Belt-and-braces: filter clean shutdowns even if any slipped in.
    |> Enum.reject(fn d -> d.reason in [:shutdown, :normal, {:shutdown, :normal}] end)

  unless deaths == [] do
    IO.puts(
      :stderr,
      "\n" <>
        "===========================================================================\n" <>
        "  burble#62 — App-owned singleton deaths recorded during test run\n" <>
        "===========================================================================\n"
    )

    Enum.with_index(deaths, 1)
    |> Enum.each(fn {d, i} ->
      IO.puts(
        :stderr,
        "  #{i}. #{inspect(d.name)} died at +#{d.at_ms}ms " <>
          "pid=#{inspect(d.pid)} reason=#{inspect(d.reason)}"
      )
    end)

    IO.puts(
      :stderr,
      "\n  #{length(deaths)} mid-run singleton death(s) observed. This is\n" <>
        "  bucket B from #62. Correlate with --seed-fixed test order to\n" <>
        "  identify the offending test interactions.\n" <>
        "==========================================================================="
    )
  end

  :ok
end)
