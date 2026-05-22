# SPDX-License-Identifier: MPL-2.0
#
# Burble Chaos Test — AWOL Layline Resilience.

defmodule Burble.Network.ChaosTest do
  use ExUnit.Case, async: true
  alias Burble.Network.AWOL

  require Logger

  # --- Mock Transport ---
  defmodule MockTransport do
    def send(_class, _target, _payload), do: :ok
  end

  setup do
    # Configure AWOL to use mock transport for this test
    Application.put_env(:burble, :awol_transport, MockTransport)
    
    start_supervised!(AWOL)
    session_id = "chaos_session_#{:rand.uniform(1000)}"
    
    # Setup two paths: 'primary' (WiFi) and 'secondary' (LTE)
    AWOL.add_interface(session_id, "wifi", {192, 168, 1, 50}, {1, 1, 1, 1})
    AWOL.add_interface(session_id, "lte", {10, 0, 0, 5}, {1, 1, 1, 1})
    
    {:ok, session_id: session_id}
  end

  test "Layline algorithm predictively switches paths during WiFi degradation", %{session_id: session_id} do
    # 1. Start with WiFi as healthy (RTT 20ms)
    simulate_network_conditions(session_id, "wifi", 20, 0.0, 10)
    simulate_network_conditions(session_id, "lte", 60, 0.0, 10)
    
    {:ok, best} = AWOL.predict_best_path(session_id)
    assert best == "wifi"

    # 2. Inject degradation velocity
    Logger.info("[Chaos] Injecting WiFi degradation (RTT climb)...")
    
    # RTT jump from 20 to 100 in two steps (High velocity)
    simulate_network_conditions(session_id, "wifi", 60, 0.0, 1)
    simulate_network_conditions(session_id, "wifi", 100, 0.0, 1)
    
    # Layline should see the trend and switch to LTE (which is still 60ms)
    {:ok, predicted_best} = AWOL.predict_best_path(session_id)
    assert predicted_best == "lte"
  end

  test "Layline ignores transient jitter but reacts to sustained RTT velocity", %{session_id: session_id} do
    # 1. Stable baseline
    simulate_network_conditions(session_id, "wifi", 30, 0.0, 5)
    
    # 2. Inject transient jitter (spike)
    Logger.info("[Chaos] Injecting transient jitter (spike)...")
    update_path_metrics(session_id, "wifi", 150, 0.0) # Single spike
    send(AWOL, :analyze_trends)
    
    # Revert WiFi back to baseline so subsequent ticks don't record 150
    update_path_metrics(session_id, "wifi", 30, 0.0)
    
    # Should still prefer WiFi (assuming LTE is much worse or not better enough)
    simulate_network_conditions(session_id, "lte", 100, 0.0, 5)
    {:ok, best} = AWOL.predict_best_path(session_id)
    assert best == "wifi"

    # 3. Sustained degradation (climb)
    Logger.info("[Chaos] Injecting sustained RTT climb...")
    simulate_network_conditions(session_id, "wifi", 60, 0.0, 1)
    simulate_network_conditions(session_id, "wifi", 90, 0.0, 1)
    simulate_network_conditions(session_id, "wifi", 120, 0.0, 1)
    
    # Now it should switch to LTE (100ms)
    {:ok, predicted_best} = AWOL.predict_best_path(session_id)
    assert predicted_best == "lte"
  end

  test "Layline switches to secondary path when primary loss exceeds 20%", %{session_id: session_id} do
    # 1. WiFi is healthy but has slightly higher RTT than LTE
    simulate_network_conditions(session_id, "wifi", 50, 0.0, 10)
    simulate_network_conditions(session_id, "lte", 40, 0.0, 10)
    
    # Initially LTE is better
    {:ok, best} = AWOL.predict_best_path(session_id)
    assert best == "lte"

    # 2. LTE starts losing packets (25% loss)
    Logger.info("[Chaos] Injecting 25% packet loss on LTE...")
    simulate_network_conditions(session_id, "lte", 40, 0.25, 5)
    
    # Even though RTT is 40ms (better than WiFi's 50ms), the loss should trigger switch
    {:ok, predicted_best} = AWOL.predict_best_path(session_id)
    assert predicted_best == "wifi"
  end

  test "AWOL maintains signaling redundancy during total primary failure", %{session_id: session_id} do
    simulate_network_conditions(session_id, "wifi", 1000, 1.0, 5) # Dead path
    assert :ok == AWOL.send(session_id, :signaling, "CRITICAL_UPDATE")
  end

  # --- Helpers ---

  defp simulate_network_conditions(session_id, path_id, rtt, loss, count) do
    Enum.each(1..count, fn _ ->
      update_path_metrics(session_id, path_id, rtt, loss)
      send(AWOL, :analyze_trends)
    end)
  end

  defp update_path_metrics(session_id, path_id, rtt, loss) do
    state = :sys.get_state(AWOL)
    session = state.sessions[session_id]
    path = session.paths[path_id]
    
    new_path = %{path | rtt_us: rtt, loss_rate: loss}
    new_session = %{session | paths: Map.put(session.paths, path_id, new_path)}
    new_state = %{state | sessions: Map.put(state.sessions, session_id, new_session)}
    
    :sys.replace_state(AWOL, fn _ -> new_state end)
  end
end
