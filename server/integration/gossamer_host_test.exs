# SPDX-License-Identifier: MPL-2.0
# Deliberate fault injector, NOT Burble endpoint or media acceptance.
defmodule Burble.GossamerHostFaultPlug do
  import Plug.Conn
  def init(opts), do: opts

  def call(conn, opts) do
    send(opts[:observer], {:fault_request, conn.method, conn.request_path})

    case {opts[:fault], conn.request_path} do
      {:stall, "/.well-known/groove/voice/connect"} ->
        Process.sleep(5_000)
        send_resp(conn, 503, "deliberately stalled provider")

      {:rupture, "/.well-known/groove/voice/connect"} ->
        body = Jason.encode!(%{handle: "fault-fixture", lease: %{mode: "soft", ttl_ms: 4_000}})
        conn |> put_resp_content_type("application/json") |> send_resp(200, body)

      {:rupture, "/.well-known/groove/voice/disconnect"} ->
        send_resp(conn, 204, "")

      _ ->
        send_resp(conn, 503, "deliberate transport/provider failure")
    end
  end
end

defmodule Burble.GossamerHostTest do
  use ExUnit.Case, async: false

  for fault <- [:stall, :rupture] do
    @tag timeout: 20_000
    test "actual GTK owned worker handles #{fault} without leaking", _ do
      fault = unquote(fault)
      driver = System.fetch_env!("GOSSAMER_HOST_DRIVER")
      assert File.regular?(driver)
      assert Burble.Groove.connection_status() == %{}

      start_supervised!(
        {Bandit,
         plug: {Burble.GossamerHostFaultPlug, [observer: self(), fault: fault]},
         ip: {127, 0, 0, 1},
         port: 6473}
      )

      {output, code} =
        System.cmd(driver, [Atom.to_string(fault)],
          env: [{"VOICE_ROOM", "fault-room"}, {"VOICE_ALICE_TOKEN", "fixture-not-a-credential"}],
          stderr_to_stdout: true
        )

      assert code == 0, output
      IO.puts(output)
      # Positive control: the native socket reached the intentionally broken
      # boundary. A test that never connected cannot count as cancellation.
      assert_received {:fault_request, "POST", "/.well-known/groove/voice/connect"}

      if fault == :rupture do
        assert_received {:fault_request, "GET", "/.well-known/groove/voice/recv"}
        assert_received {:fault_request, "POST", "/.well-known/groove/voice/disconnect"}
      end

      assert String.contains?(output, "owned worker joined")
      assert Burble.Groove.connection_status() == %{}
    end
  end
end
