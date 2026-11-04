# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
# Private stdin/file fixture for the Rust WebSocket conformance executable.
# It exposes no management route and always binds the real listener to loopback.
if Mix.env() != :test, do: raise("admission fixture requires MIX_ENV=test")

alias Burble.Auth.Guardian
alias Burble.Sessions.Admission

path = System.fetch_env!("BURBLE_ADMISSION_FIXTURE")
Application.put_env(:burble, :game_session_mode, :scoped)
{:ok, listener} = Bandit.start_link(plug: BurbleWeb.Endpoint, ip: {127, 0, 0, 1}, port: 0)
{:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
session_id = "wire-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

{:ok, provision} =
  Admission.create(session_id, "idaptik", %{"infiltrator" => "alice", "hacker" => "bob"})

tokens =
  Map.new(["alice", "bob", "mallory"], fn subject ->
    {:ok, token, _} =
      Guardian.encode_and_sign(%{id: subject}, %{"gst" => true, "dn" => subject},
        token_type: "guest"
      )

    {subject, token}
  end)

fixture = %{
  generation: 0,
  endpoint: "ws://127.0.0.1:#{port}/voice/websocket",
  provision: provision,
  tokens: tokens
}

publish = fn data ->
  # The parent creates a private directory. No tickets are written to logs.
  pending = path <> ".pending"
  File.write!(pending, Jason.encode!(data))
  File.chmod!(pending, 0o600)
  File.rename!(pending, path)
end

publish.(fixture)

IO.stream(:stdio, :line)
|> Enum.reduce(fixture, fn command, state ->
  next =
    case String.trim(command) do
      "rotate" ->
        {:ok, rotated} = Admission.rotate(session_id)
        %{state | provision: rotated, generation: state.generation + 1}

      "restart" ->
        :ok = Supervisor.terminate_child(Burble.Supervisor, Admission)
        {:ok, _} = Supervisor.restart_child(Burble.Supervisor, Admission)
        %{state | generation: state.generation + 1}

      "stop" ->
        System.halt(0)

      _ ->
        raise "unknown fixture control command"
    end

  publish.(next)
  next
end)
