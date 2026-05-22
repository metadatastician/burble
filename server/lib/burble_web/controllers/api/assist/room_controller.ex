# SPDX-License-Identifier: MPL-2.0
#
# BurbleWeb.API.Assist.RoomController — room health diagnostics for the LLM.
#
# GET /api/v1/assist/rooms              — list active rooms
# GET /api/v1/assist/rooms/:id/health   — RoomHealth object
# GET /api/v1/assist/rooms/:id/sync     — sync state

defmodule BurbleWeb.API.Assist.RoomController do
  use Phoenix.Controller, formats: [:json]

  alias Burble.Rooms.{RoomManager, Room}
  alias Burble.Media.Engine

  def index(conn, _params) do
    rooms = RoomManager.list_active_rooms()

    summaries =
      Enum.map(rooms, fn room_id ->
        count =
          case Room.participant_count(room_id) do
            {:ok, n} -> n
            _ -> 0
          end

        %{room_id: room_id, participants: count}
      end)

    json(conn, %{rooms: summaries, total: length(summaries)})
  end

  def health(conn, %{"id" => room_id}) do
    with {:ok, room_state} <- Room.get_state(room_id),
         media_health <- Engine.get_room_health(room_id) do
      participants = map_size(Map.get(room_state, :participants, %{}))
      topology = Application.get_env(:burble, Burble.Topology, []) |> Keyword.get(:mode, :monarchic)

      {direct, relay} = count_paths(media_health)
      {status, mitigations} = assess_health(media_health)

      json(conn, %{
        room_id: room_id,
        status: status,
        participants: participants,
        topology: topology,
        direct_paths: direct,
        relay_paths: relay,
        mean_rtt_ms: get_in(media_health, [:mean_rtt_ms]) || 0,
        mean_jitter_ms: get_in(media_health, [:mean_jitter_ms]) || 0,
        packet_loss_pct: get_in(media_health, [:packet_loss_pct]) || 0.0,
        sync_confidence: get_in(media_health, [:sync_confidence]) || 1.0,
        cpu_pressure: get_in(media_health, [:cpu_pressure]) || "unknown",
        active_mitigations: mitigations,
        recommended_actions: recommend_actions(media_health),
        measured_at: DateTime.to_iso8601(DateTime.utc_now())
      })
    else
      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "room_not_found", room_id: room_id})

      _ ->
        conn |> put_status(503) |> json(%{error: "room_unavailable", room_id: room_id})
    end
  end

  def sync(conn, %{"id" => room_id}) do
    case Room.get_state(room_id) do
      {:ok, _room_state} ->
        correlator = Burble.Timing.ClockCorrelator

        drift_ppm =
          case Burble.Timing.ClockCorrelator.drift_ppm(correlator) do
            {:ok, ppm} -> ppm
            _ -> nil
          end

        json(conn, %{
          room_id: room_id,
          sync_mode: "normal",
          sync_confidence: if(drift_ppm && abs(drift_ppm) < 100, do: 0.95, else: 0.7),
          max_peer_drift_ms: if(drift_ppm, do: abs(drift_ppm) / 1000, else: nil),
          correction_active: false,
          load_shedding_state: "off",
          measured_at: DateTime.to_iso8601(DateTime.utc_now())
        })

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "room_not_found"})
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp count_paths(nil), do: {0, 0}
  defp count_paths(health) do
    direct = Map.get(health, :direct_paths, 0)
    relay = Map.get(health, :relay_paths, 0)
    {direct, relay}
  end

  defp assess_health(nil), do: {"unknown", []}
  defp assess_health(health) do
    loss = Map.get(health, :packet_loss_pct, 0.0)
    jitter = Map.get(health, :mean_jitter_ms, 0)

    cond do
      loss > 10 or jitter > 100 ->
        {"degraded", ["high_packet_loss"]}

      loss > 3 or jitter > 40 ->
        {"degraded", ["elevated_jitter"]}

      true ->
        {"healthy", []}
    end
  end

  defp recommend_actions(nil), do: []
  defp recommend_actions(health) do
    relay = Map.get(health, :relay_paths, 0)
    loss = Map.get(health, :packet_loss_pct, 0.0)

    []
    |> then(fn acc -> if relay > 0 and loss > 5, do: ["switch_to_relay" | acc], else: acc end)
    |> then(fn acc -> if loss > 10, do: ["enable_low_load_mode" | acc], else: acc end)
  end
end
