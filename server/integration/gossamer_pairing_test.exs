# SPDX-License-Identifier: MPL-2.0
# Explicit opt-in suite: mix test integration/gossamer_pairing_test.exs
# It must fail (not skip) if the actual consumer library/checkout is missing.
defmodule Burble.GossamerPairingTest do
  use ExUnit.Case, async: false

  @tag timeout: 40_000
  test "native Gossamer session API pairs with the actual HTTP endpoint" do
    driver = System.fetch_env!("GOSSAMER_PAIRING_DRIVER")
    assert File.regular?(driver)
    assert Burble.Groove.connection_status() == %{}
    # Bind the registry port exclusively. Never attach to or stop an existing
    # service on this port. This is the production Endpoint, not a fake Plug.
    start_supervised!({Bandit, plug: BurbleWeb.Endpoint, ip: {127, 0, 0, 1}, port: 6473})
    observer = self()
    events = for event <- [:connect, :disconnect, :lease_expired], do: [:burble, :groove, event]
    handler = "native-gossamer-pairing"

    :ok =
      :telemetry.attach_many(
        handler,
        events,
        fn event, measurements, metadata, pid ->
          send(pid, {:groove_event, event, measurements, metadata})
        end,
        observer
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    task = Task.async(fn -> System.cmd(driver, [], stderr_to_stdout: true) end)

    case Task.yield(task, 30_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        IO.puts(output)
        assert String.contains?(output, "PASS native lifecycle pairing")
        assert Burble.Groove.connection_status() == %{}
        observed = drain_events([])

        assert Enum.frequencies_by(observed, fn {event, _} -> List.last(event) end) ==
                 %{connect: 5, disconnect: 3, lease_expired: 2}

        for {_event, metadata} <- observed do
          refute Map.has_key?(metadata, :session_id)
          assert metadata.connection_id =~ ~r/^sha256:[0-9a-f]{64}$/
        end

      {:ok, {output, code}} ->
        flunk("Native pairing failed (#{code}):\n#{output}")

      nil ->
        flunk("Native pairing exceeded 30 seconds")
    end
  end

  defp drain_events(events) do
    receive do
      {:groove_event, event, _measurements, metadata} ->
        drain_events([{event, metadata} | events])
    after
      0 -> Enum.reverse(events)
    end
  end
end
