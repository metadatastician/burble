# SPDX-License-Identifier: MPL-2.0
#
# BurbleWeb.API.Assist.ActionsController — capability-gated action registry.
#
# POST /api/v1/assist/actions/:action
#
# All actions support:
#   dry_run     — boolean, validate but do not execute
#   reason      — string, why this action is being requested (logged)
#   requested_by — string, identity of requesting LLM/operator
#
# Every action is logged to the audit trail regardless of dry_run.

defmodule BurbleWeb.API.Assist.ActionsController do
  use Phoenix.Controller, formats: [:json]

  alias Burble.Audit

  # Safe actions — no confirmation required.
  @safe_actions ~w(
    run_connectivity_probe
    request_mic_check
    request_echo_test
    open_support_overlay
    enable_low_load_mode
    disable_optional_processing
    send_bolt
    request_sync_repair
  )

  # Disruptive actions — require explicit confirmation or elevated capability.
  @disruptive_actions ~w(
    switch_to_relay
    retry_direct_path
    restart_room_worker
  )

  @all_actions @safe_actions ++ @disruptive_actions

  def execute(conn, %{"action" => action} = params) when action in @all_actions do
    dry_run = Map.get(params, "dry_run", false)
    reason = Map.get(params, "reason", "no reason given")
    requested_by = Map.get(params, "requested_by", "unknown")

    action_id = generate_action_id()

    Audit.log(:assist_action, requested_by, %{
      action: action,
      params: Map.drop(params, ["action"]),
      dry_run: dry_run,
      reason: reason,
      action_id: action_id
    })

    if action in @disruptive_actions and not Map.get(params, "confirmed", false) and not dry_run do
      conn
      |> put_status(422)
      |> json(%{
        action_id: action_id,
        status: "requires_confirmation",
        action: action,
        message: "This action is disruptive. Retry with confirmed: true to proceed.",
        dry_run: false
      })
    else
      result = if dry_run, do: {:ok, :dry_run}, else: dispatch(action, params)
      format_result(conn, action_id, action, dry_run, result, params)
    end
  end

  def execute(conn, %{"action" => unknown_action}) do
    conn
    |> put_status(404)
    |> json(%{
      error: "unknown_action",
      action: unknown_action,
      available_actions: @all_actions
    })
  end

  def execute(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{error: "action_required", message: "POST body must include an action field"})
  end

  # ---------------------------------------------------------------------------
  # Action dispatch
  # ---------------------------------------------------------------------------

  defp dispatch("run_connectivity_probe", params) do
    peer_id = Map.get(params, "peer_id")
    Burble.Groove.HealthMesh.probe_now()
    {:ok, %{probed: peer_id || "all_peers"}}
  end

  defp dispatch("send_bolt", %{"target" => target} = params) do
    payload = Map.get(params, "payload", %{"type" => "call_request"})
    Burble.Bolt.send(target, payload)
  end

  defp dispatch("send_bolt", _) do
    {:error, "target is required for send_bolt"}
  end

  defp dispatch("request_mic_check", params) do
    peer_id = Map.get(params, "peer_id")
    if peer_id do
      Phoenix.PubSub.broadcast(Burble.PubSub, "peer:#{peer_id}", {:assist_request, :mic_check})
      {:ok, %{requested: "mic_check", peer_id: peer_id}}
    else
      {:error, "peer_id is required for request_mic_check"}
    end
  end

  defp dispatch("enable_low_load_mode", params) do
    room_id = Map.get(params, "room_id")
    Phoenix.PubSub.broadcast(Burble.PubSub, "room:#{room_id}", {:assist_request, :low_load_mode})
    {:ok, %{enabled: "low_load_mode", room_id: room_id}}
  end

  defp dispatch("request_sync_repair", params) do
    room_id = Map.get(params, "room_id")
    Phoenix.PubSub.broadcast(Burble.PubSub, "room:#{room_id}", {:assist_request, :sync_repair})
    {:ok, %{requested: "sync_repair", room_id: room_id}}
  end

  defp dispatch("switch_to_relay", params) do
    peer_id = Map.get(params, "peer_id")
    Phoenix.PubSub.broadcast(Burble.PubSub, "peer:#{peer_id}", {:assist_request, :force_relay})
    {:ok, %{switched: "relay", peer_id: peer_id}}
  end

  defp dispatch("retry_direct_path", params) do
    peer_id = Map.get(params, "peer_id")
    Phoenix.PubSub.broadcast(Burble.PubSub, "peer:#{peer_id}", {:assist_request, :retry_direct})
    {:ok, %{retrying: "direct_path", peer_id: peer_id}}
  end

  defp dispatch("restart_room_worker", params) do
    room_id = Map.get(params, "room_id")
    case Burble.Rooms.RoomManager.ensure_room(room_id) do
      {:ok, _pid} -> {:ok, %{restarted: "room_worker", room_id: room_id}}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp dispatch(action, _params) do
    {:ok, %{action: action, note: "acknowledged"}}
  end

  # ---------------------------------------------------------------------------
  # Response formatting
  # ---------------------------------------------------------------------------

  defp format_result(conn, action_id, action, dry_run, {:ok, detail}, _params) do
    BurbleWeb.AssistChannel.broadcast_event("assist.action.completed", %{
      action_id: action_id,
      action: action,
      dry_run: dry_run,
      detail: detail
    })

    json(conn, %{
      action_id: action_id,
      status: if(dry_run, do: "dry_run", else: "completed"),
      action: action,
      dry_run: dry_run,
      detail: detail,
      completed_at: DateTime.to_iso8601(DateTime.utc_now())
    })
  end

  defp format_result(conn, action_id, action, dry_run, {:error, reason}, _params) do
    BurbleWeb.AssistChannel.broadcast_event("assist.action.denied", %{
      action_id: action_id,
      action: action,
      reason: reason
    })

    conn
    |> put_status(422)
    |> json(%{
      action_id: action_id,
      status: "failed",
      action: action,
      dry_run: dry_run,
      reason: reason
    })
  end

  defp generate_action_id do
    "act_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
  end
end
