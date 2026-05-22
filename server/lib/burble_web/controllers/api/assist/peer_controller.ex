# SPDX-License-Identifier: MPL-2.0
#
# BurbleWeb.API.Assist.PeerController — per-peer connectivity diagnostics.
#
# GET /api/v1/assist/peers/:id/connectivity — PeerConnectivity object
# GET /api/v1/assist/peers/:id/media        — media quality summary
# GET /api/v1/assist/peers/:id/operator_view — composite single-call summary

defmodule BurbleWeb.API.Assist.PeerController do
  use Phoenix.Controller, formats: [:json]

  alias Burble.Groove.HealthMesh

  def connectivity(conn, %{"id" => peer_id}) do
    mesh = HealthMesh.mesh_status()
    peer_status = find_peer(mesh, peer_id)

    if peer_status do
      turn_in_use = Map.get(peer_status, :turn_in_use, false)
      path_mode = if turn_in_use, do: "relay", else: "direct"

      json(conn, %{
        peer_id: peer_id,
        reachable: peer_status.status == :up,
        path_mode: path_mode,
        turn_in_use: turn_in_use,
        nat_assessment: nat_assessment(peer_status),
        rtt_ms: Map.get(peer_status, :rtt_ms),
        jitter_ms: Map.get(peer_status, :jitter_ms),
        packet_loss_pct: Map.get(peer_status, :packet_loss_pct),
        last_path_change_reason: Map.get(peer_status, :last_path_change_reason),
        clock_quality: clock_quality(peer_status),
        confidence: 0.85,
        source: "health_mesh",
        measured_at: DateTime.to_iso8601(DateTime.utc_now()),
        inferred: false,
        recommended_actions: peer_recommended_actions(peer_status),
        user_visible_summary: peer_summary(peer_status, path_mode)
      })
    else
      conn |> put_status(404) |> json(%{error: "peer_not_found", peer_id: peer_id})
    end
  end

  def media(conn, %{"id" => peer_id}) do
    mesh = HealthMesh.mesh_status()
    peer_status = find_peer(mesh, peer_id)

    if peer_status do
      json(conn, %{
        peer_id: peer_id,
        codec: "opus",
        bitrate_kbps: Map.get(peer_status, :bitrate_kbps, 32),
        concealment_rate_pct: Map.get(peer_status, :concealment_rate_pct, 0.0),
        fec_active: Map.get(peer_status, :fec_active, false),
        echo_cancel_state: "normal",
        denoise_state: "normal",
        measured_at: DateTime.to_iso8601(DateTime.utc_now())
      })
    else
      conn |> put_status(404) |> json(%{error: "peer_not_found", peer_id: peer_id})
    end
  end

  def operator_view(conn, %{"id" => peer_id}) do
    mesh = HealthMesh.mesh_status()
    peer_status = find_peer(mesh, peer_id)

    if peer_status do
      turn_in_use = Map.get(peer_status, :turn_in_use, false)
      path_mode = if turn_in_use, do: "relay", else: "direct"
      loss = Map.get(peer_status, :packet_loss_pct, 0.0)
      jitter = Map.get(peer_status, :jitter_ms, 0)

      primary_issue =
        cond do
          loss > 10 -> "High packet loss (#{loss}%)"
          jitter > 50 -> "High jitter (#{jitter} ms)"
          turn_in_use -> "Using TURN relay — direct connection unavailable"
          true -> nil
        end

      json(conn, %{
        peer_id: peer_id,
        status: if(peer_status.status == :up, do: "connected", else: "disconnected"),
        path_mode: path_mode,
        headline: peer_summary(peer_status, path_mode),
        primary_issue: primary_issue,
        recommended_actions: peer_recommended_actions(peer_status),
        measured_at: DateTime.to_iso8601(DateTime.utc_now())
      })
    else
      conn |> put_status(404) |> json(%{error: "peer_not_found", peer_id: peer_id})
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp find_peer(%{peers: peers}, peer_id) do
    Enum.find(peers, &(to_string(&1.id) == peer_id))
  end
  defp find_peer(_, _), do: nil

  defp nat_assessment(peer_status) do
    %{
      type: Map.get(peer_status, :nat_type, "unknown"),
      confidence: 0.85,
      source: "stun_probe",
      measured_at: DateTime.to_iso8601(DateTime.utc_now())
    }
  end

  defp clock_quality(peer_status) do
    %{
      source: Map.get(peer_status, :clock_source, "ntp"),
      estimated_drift_ms: Map.get(peer_status, :clock_drift_ms),
      confidence: Map.get(peer_status, :clock_confidence, 0.7)
    }
  end

  defp peer_recommended_actions(peer_status) do
    loss = Map.get(peer_status, :packet_loss_pct, 0.0)
    turn = Map.get(peer_status, :turn_in_use, false)

    []
    |> then(fn acc -> if loss > 5, do: ["enable_low_load_mode" | acc], else: acc end)
    |> then(fn acc -> if not turn and loss > 8, do: ["switch_to_relay" | acc], else: acc end)
    |> then(fn acc -> if turn, do: ["stay_on_turn" | acc], else: acc end)
  end

  defp peer_summary(peer_status, "relay") do
    reason = Map.get(peer_status, :last_path_change_reason, "network conditions")
    "Direct connection is unavailable (#{reason}), so Burble is using a relay to keep voice stable."
  end
  defp peer_summary(%{status: :up}, "direct") do
    "Connected directly — voice is flowing peer-to-peer with no relay."
  end
  defp peer_summary(_, _) do
    "Peer connection status is uncertain."
  end
end
