# SPDX-License-Identifier: MPL-2.0
#
# Burble.Telemetry — Observability as a product feature.
#
# "Observability is a product feature, not an afterthought."
#
# Metrics exposed:
#   - Active rooms count
#   - Total connected users
#   - Voice state distribution (speaking/muted/deafened)
#   - WebRTC signaling latency
#   - Room join/leave rates
#   - Text message rates
#   - Auth success/failure rates
#   - Media plane health (when integrated)
#
# Designed to feed into Prometheus/Grafana or any OpenTelemetry collector.
# Also powers the Phoenix LiveDashboard for quick operator checks.

defmodule Burble.Telemetry do
  @moduledoc """
  Telemetry supervisor for Burble metrics.

  Exposes key voice platform metrics for operational monitoring.
  """

  use Supervisor

  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      {:telemetry_poller,
       measurements: periodic_measurements(),
       period: :timer.seconds(10),
       name: :burble_poller}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "Metrics definitions for LiveDashboard and exporters."
  def metrics do
    [
      # Phoenix
      summary("phoenix.endpoint.start.system_time", unit: {:native, :millisecond}),
      summary("phoenix.endpoint.stop.duration", unit: {:native, :millisecond}),
      summary("phoenix.router_dispatch.stop.duration", unit: {:native, :millisecond}),

      # Channel (voice room signaling)
      counter("phoenix.channel_joined.duration"),
      counter("phoenix.channel_handled_in.duration"),

      # Burble-specific
      last_value("burble.rooms.active.count"),
      last_value("burble.users.connected.count"),
      counter("burble.rooms.joined.total"),
      counter("burble.rooms.left.total"),
      counter("burble.auth.login.success.total"),
      counter("burble.auth.login.failure.total"),
      counter("burble.messages.text.total"),
      counter("burble.signaling.offer.total"),
      counter("burble.signaling.answer.total"),
      counter("burble.signaling.ice_candidate.total"),

      # VM (BEAM health)
      summary("vm.memory.total", unit: :byte),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  defp periodic_measurements do
    [
      {__MODULE__, :measure_active_rooms, []},
      {__MODULE__, :measure_connected_users, []}
    ]
  end

  @doc false
  def measure_active_rooms do
    count = Burble.Rooms.RoomManager.active_room_count()
    :telemetry.execute([:burble, :rooms, :active], %{count: count}, %{})
  end

  @doc false
  def measure_connected_users do
    # Sum participants across all active rooms
    rooms = Burble.Rooms.RoomManager.list_active_rooms()

    count =
      Enum.reduce(rooms, 0, fn room_id, acc ->
        case Burble.Rooms.Room.participant_count(room_id) do
          n when is_integer(n) -> acc + n
          _ -> acc
        end
      end)

    :telemetry.execute([:burble, :users, :connected], %{count: count}, %{})
  end
end
