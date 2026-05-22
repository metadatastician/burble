# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# BurbleWeb.API.HealthController — HTTP health endpoint.
#
# Returns server health status for load balancers, container orchestrators,
# and the Gossamer admin panel. Checks OTP supervision tree and VeriSimDB
# connectivity.

defmodule BurbleWeb.API.HealthController do
  @moduledoc """
  Health check endpoint.

  `GET /api/v1/health` returns:
  - `200 OK` with `{"status": "healthy", ...}` when all systems are operational.
  - `503 Service Unavailable` with `{"status": "degraded", ...}` when a
    subsystem is down but the server can still accept requests.
  """

  use Phoenix.Controller, formats: [:json]

  @doc """
  Return the current health status.

  Checks:
  - OTP supervision tree is alive
  - VeriSimDB store is reachable
  - PubSub is functional
  """
  def check(conn, _params) do
    supervisor_ok = Process.whereis(Burble.Supervisor) != nil
    pubsub_ok = Process.whereis(Burble.PubSub) != nil

    verisimdb_status =
      case Burble.Store.health() do
        {:ok, true} -> :healthy
        {:ok, false} -> :degraded
        {:error, _} -> :unreachable
      end

    # Get WebRTC peer status from health mesh
    webrtc_status =
      case Burble.Groove.HealthMesh.mesh_status() do
        %{peers: peers} ->
          webrtc_peers = Enum.filter(peers, fn peer -> :webrtc in peer.capabilities end)

          if Enum.all?(webrtc_peers, &(&1.status == :up)) do
            :healthy
          else
            :degraded
          end

        _ ->
          :unknown
      end

    breakers = Burble.CircuitBreaker.snapshot()
    breakers_healthy = Enum.all?(breakers, fn {_name, %{state: s}} -> s != :open end)

    backup_status = backup_status()

    overall =
      cond do
        not supervisor_ok -> :degraded
        not pubsub_ok -> :degraded
        verisimdb_status != :healthy -> :degraded
        webrtc_status != :healthy -> :degraded
        not breakers_healthy -> :degraded
        true -> :healthy
      end

    status_code = if overall == :healthy, do: 200, else: 503

    conn
    |> put_status(status_code)
    |> json(%{
      status: overall,
      version: Application.spec(:burble, :vsn) |> to_string(),
      checks: %{
        supervisor: if(supervisor_ok, do: "ok", else: "down"),
        pubsub: if(pubsub_ok, do: "ok", else: "down"),
        verisimdb: verisimdb_status,
        webrtc: webrtc_status,
        circuit_breakers: Map.new(breakers, fn {name, info} -> {name, info.state} end),
        backup: backup_status
      },
      timestamp: DateTime.to_iso8601(DateTime.utc_now())
    })
  end

  defp backup_status do
    case Process.whereis(Burble.Store.BackupScheduler) do
      nil ->
        %{scheduler: "down"}

      _pid ->
        case Burble.Store.BackupScheduler.status() do
          %{} = s -> Map.put(s, :scheduler, "ok")
          _ -> %{scheduler: "ok"}
        end
    end
  end
end
