# SPDX-License-Identifier: MPL-2.0
#
# BurbleWeb.API.Assist.SupportController — composite endpoints for the LLM.
#
# These endpoints save round trips by returning pre-composed summaries
# rather than forcing the LLM to stitch together multiple reads.
#
# GET /api/v1/assist/support/summary?peer_id=...  — support-focused diagnosis
# GET /api/v1/assist/discovery/resolve?target=... — DNS/NAPTR resolution chain

defmodule BurbleWeb.API.Assist.SupportController do
  use Phoenix.Controller, formats: [:json]

  alias Burble.Groove.HealthMesh

  def summary(conn, %{"peer_id" => peer_id}) do
    mesh = HealthMesh.mesh_status()
    peer = find_peer(mesh, peer_id)

    if peer do
      loss = Map.get(peer, :packet_loss_pct, 0.0)
      jitter = Map.get(peer, :jitter_ms, 0)
      turn = Map.get(peer, :turn_in_use, false)
      reachable = peer.status == :up

      {status, headline, primary, secondary} = diagnose(peer, loss, jitter, turn, reachable)

      json(conn, %{
        status: status,
        headline: headline,
        primary_issue: primary,
        secondary_issues: secondary,
        recommended_actions: recommend(loss, jitter, turn),
        measured_at: DateTime.to_iso8601(DateTime.utc_now())
      })
    else
      conn |> put_status(404) |> json(%{error: "peer_not_found", peer_id: peer_id})
    end
  end

  def summary(conn, _params) do
    conn |> put_status(400) |> json(%{error: "peer_id query parameter required"})
  end

  def resolve(conn, %{"target" => target}) do
    case Burble.Bolt.NAPTR.resolve(target) do
      {:ok, result} ->
        json(conn, %{
          target: target,
          resolved: true,
          result: result,
          measured_at: DateTime.to_iso8601(DateTime.utc_now())
        })

      {:error, reason} ->
        json(conn, %{
          target: target,
          resolved: false,
          reason: inspect(reason),
          measured_at: DateTime.to_iso8601(DateTime.utc_now())
        })
    end
  end

  def resolve(conn, _params) do
    conn |> put_status(400) |> json(%{error: "target query parameter required"})
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp find_peer(%{peers: peers}, peer_id) do
    Enum.find(peers, &(to_string(&1.id) == peer_id))
  end
  defp find_peer(_, _), do: nil

  defp diagnose(_peer, loss, jitter, turn, true) when loss > 10 do
    secondary = (if turn, do: ["using TURN relay"], else: []) ++
                (if jitter > 40, do: ["elevated jitter (#{jitter} ms)"], else: [])
    {"degraded",
     "Voice is connected but packet loss is high (#{loss}%).",
     "High packet loss may cause audio gaps",
     secondary}
  end

  defp diagnose(_peer, _loss, jitter, turn, true) when jitter > 50 do
    secondary = if turn, do: ["using TURN relay"], else: []
    {"degraded",
     "Voice is connected, but network conditions are unstable.",
     "High jitter on #{if turn, do: "relay", else: "direct"} path (#{jitter} ms)",
     secondary}
  end

  defp diagnose(_peer, _loss, _jitter, true, true) do
    {"connected",
     "Voice is stable via relay — direct connection was unavailable.",
     "Using TURN relay due to NAT or firewall constraints",
     []}
  end

  defp diagnose(_peer, _loss, _jitter, _turn, true) do
    {"healthy", "Voice is connected and stable.", nil, []}
  end

  defp diagnose(_peer, _loss, _jitter, _turn, false) do
    {"disconnected", "Peer is not reachable.", "Connection failed or peer has left", []}
  end

  defp recommend(loss, jitter, turn) do
    []
    |> then(fn a -> if loss > 10, do: ["enable_low_load_mode" | a], else: a end)
    |> then(fn a -> if not turn and loss > 5, do: ["switch_to_relay" | a], else: a end)
    |> then(fn a -> if turn, do: ["stay_on_turn" | a], else: a end)
    |> then(fn a -> if jitter > 50, do: ["request_mic_check" | a], else: a end)
  end
end
