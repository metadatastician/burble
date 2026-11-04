# SPDX-License-Identifier: MPL-2.0
#
# BurbleWeb.GameChannel — one game session's typed relay lane.
#
# The two seats of `game:<session_id>` exchange their game's typed wire
# enums verbatim: a `"command"` or `"event"` message's payload IS the
# game's JSON, byte-preserving — burble reads only the routing tag and
# never interprets the body. Which seat may send which command tag comes
# from the session's registered game profile (Burble.Games), so this
# module contains no game-specific code at all.
#
# Ported from IDApTIK's session_channel.ex (the parity source; see
# docs/superpowers/specs/2026-08-04-game-session-fabric-design.md).
# The legacy JSON lane is an explicit loopback-only development protocol.
# Scoped sessions cross-check the game and role against the host-provisioned
# admission authority. This is not the 0.8 binary/durable session protocol.
defmodule BurbleWeb.GameChannel do
  use Phoenix.Channel

  alias Burble.Games
  alias Burble.Sessions.Admission

  intercept(["command", "event", "peer_joined", "peer_left"])

  @max_payload_bytes 8_192

  @impl true
  def join("game:" <> session_id, %{"role" => role, "game" => game_id} = params, socket)
      when is_binary(role) and is_binary(game_id) do
    case Games.fetch(game_id) do
      {:ok, profile} ->
        if role in profile.roles() do
          with {:ok, lease, receipt, mode} <- admit(socket, session_id, game_id, role, params) do
            socket =
              socket
              |> assign(:role, role)
              |> assign(:game, game_id)
              |> assign(:profile, profile)
              |> assign(:last_seq, nil)
              |> assign(:session_mode, mode)
              |> assign(:session_lease, lease)

            send(self(), :after_join)
            {:ok, Map.merge(%{role: role, game: game_id}, receipt), socket}
          else
            {:error, reason} -> {:error, %{reason: to_string(reason)}}
          end
        else
          {:error,
           %{
             reason:
               "unknown role #{inspect(role)} — #{game_id} seats: " <>
                 Enum.join(profile.roles(), ", ")
           }}
        end

      :error ->
        {:error, %{reason: "unknown game: #{inspect(game_id)}"}}
    end
  end

  def join("game:" <> _session_id, params, _socket) do
    reason =
      ["role", "game"]
      |> Enum.map(&field_problem(params, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" and ")

    {:error, %{reason: "join requires #{reason}"}}
  end

  @impl true
  def handle_info(:after_join, socket) do
    case guarded(socket, fn ->
           relay_broadcast(socket, "peer_joined", %{"role" => socket.assigns.role})
         end) do
      :ok -> {:noreply, socket}
      {:error, _} -> {:stop, {:shutdown, :session_fenced}, socket}
    end
  end

  def handle_info(:session_fenced, socket), do: {:stop, {:shutdown, :session_fenced}, socket}

  # Interception prevents an old, still-subscribed channel from reading new
  # session traffic between a rejoin/epoch change and processing its stop signal.
  @impl true
  def handle_out(
        event,
        %{admission_epoch: epoch, payload: payload},
        %{assigns: %{session_mode: :scoped, session_lease: %{epoch: epoch}}} = socket
      ) do
    forward_current(event, payload, socket)
  end

  # PubSub may be distributed or retain a queued broadcast through rotation.
  # A valid local lease never authorizes an unscoped or different-epoch message.
  def handle_out(_event, _payload, %{assigns: %{session_mode: :scoped}} = socket),
    do: {:noreply, socket}

  def handle_out(_event, %{admission_epoch: _, payload: _}, socket), do: {:noreply, socket}

  def handle_out(event, payload, socket), do: forward_current(event, payload, socket)

  defp forward_current(event, payload, socket) do
    case guarded(socket, fn -> push(socket, event, payload) end) do
      :ok -> {:noreply, socket}
      {:error, _} -> {:stop, {:shutdown, :session_fenced}, socket}
    end
  end

  # Lightweight liveness check.
  @impl true
  def handle_in("ping", _payload, socket) do
    case guarded(socket, fn -> :ok end) do
      :ok -> {:reply, {:ok, %{"pong" => true}}, socket}
      {:error, reason} -> {:reply, {:error, %{"reason" => to_string(reason)}}, socket}
    end
  end

  # A typed game command (tagged "cmd") -> the other seat, verbatim except
  # for the optional "seq" relay-envelope key.
  def handle_in("command", payload, socket) when is_map(payload) do
    with {:ok, tag} <- command_tag(payload, socket.assigns.profile),
         :ok <- authorize(tag, socket),
         :ok <- bounded(payload, socket) do
      relay_command(payload, socket)
    else
      {:error, reason} -> {:reply, {:error, %{"reason" => to_string(reason)}}, socket}
    end
  end

  def handle_in("command", _payload, socket) do
    {:reply, {:error, %{"reason" => "command payload must be a JSON object"}}, socket}
  end

  # A typed game Event (tagged "event") -> the other seat, verbatim.
  # Events are produced by the peers' deterministic engines, not authored
  # by a seat, so both roles may publish them (lockstep cross-feed).
  def handle_in("event", %{"event" => tag} = payload, socket) when is_binary(tag) do
    with :ok <- bounded(payload, socket),
         :ok <- guarded(socket, fn -> relay_broadcast(socket, "event", payload) end) do
      {:reply, {:ok, acceptance(socket)}, socket}
    else
      {:error, reason} -> {:reply, {:error, %{"reason" => to_string(reason)}}, socket}
    end
  end

  def handle_in("event", _payload, socket) do
    {:reply, {:error, %{"reason" => "event payload must carry the \"event\" tag"}}, socket}
  end

  # Anything else — refuse politely instead of crashing the channel (a stale
  # or foreign client must not read as a peer loss to the other seat).
  def handle_in(event, _payload, socket) do
    {:reply, {:error, %{"reason" => "unknown message: #{inspect(event)}"}}, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    if socket.joined do
      guarded(socket, fn ->
        relay_broadcast(socket, "peer_left", %{"role" => socket.assigns.role})
      end)

      if socket.assigns.session_lease, do: Admission.leave(socket.assigns.session_lease)
    end

    :ok
  end

  # -- helpers ---------------------------------------------------------------

  defp admit(socket, session_id, game_id, role, params) do
    case Application.get_env(:burble, :game_session_mode, :scoped) do
      :local_legacy ->
        cond do
          Map.get(socket.assigns, :legacy_game_local) != true ->
            {:error, :legacy_requires_loopback}

          Map.get(params, "protocol", "legacy-json-v1") != "legacy-json-v1" or
            not json_only?(params) or
            Map.has_key?(params, "ticket") or Map.has_key?(params, "rejoin_token") ->
            {:error, :unsupported_protocol}

          true ->
            {:ok, nil, %{protocol: "legacy-json-v1"}, :local_legacy}
        end

      :scoped ->
        with true <- params["protocol"] == Admission.protocol() and json_only?(params),
             {:ok, credential} <- join_credential(params),
             {:ok, lease, receipt} <-
               Admission.claim(
                 Map.get(socket.assigns, :session_identity),
                 session_id,
                 game_id,
                 role,
                 params["epoch"],
                 credential
               ) do
          {:ok, lease, receipt, :scoped}
        else
          false -> {:error, :unsupported_protocol}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :session_mode_unavailable}
    end
  end

  defp join_credential(%{"ticket" => _, "rejoin_token" => _}), do: {:error, :ambiguous_credential}
  defp join_credential(%{"ticket" => ticket}), do: {:ok, {:ticket, ticket}}
  defp join_credential(%{"rejoin_token" => token}), do: {:ok, {:rejoin, token}}
  defp join_credential(_), do: {:error, :ticket_required}

  defp json_only?(params),
    do:
      Map.get(params, "encoding", "json") == "json" and
        Map.get(params, "binary_format", "none") == "none"

  defp guarded(socket, effect, seq \\ :unsequenced) do
    current_mode = Application.get_env(:burble, :game_session_mode, :scoped)

    case {current_mode, socket.assigns.session_mode} do
      {:local_legacy, :local_legacy} -> effect.()
      {:scoped, :scoped} -> Admission.relay(socket.assigns.session_lease, seq, effect)
      _ -> {:error, :session_mode_changed}
    end
  end

  defp relay_command(payload, %{assigns: %{session_mode: :scoped}} = socket) do
    result =
      guarded(
        socket,
        fn -> relay_broadcast(socket, "command", Map.delete(payload, "seq")) end,
        Map.get(payload, "seq")
      )

    relay_reply(result, socket)
  end

  defp relay_command(payload, socket) do
    case note_seq(payload, socket) do
      {:fresh, updated} ->
        result =
          guarded(updated, fn ->
            relay_broadcast(updated, "command", Map.delete(payload, "seq"))
          end)

        relay_reply(result, updated)

      {:stale, updated} ->
        relay_reply({:error, :stale_or_duplicate}, updated)
    end
  end

  defp relay_reply(:ok, socket), do: {:reply, {:ok, acceptance(socket)}, socket}

  defp relay_reply({:error, :stale_or_duplicate}, socket),
    do: {:reply, {:ok, %{"relayed" => false, "reason" => "stale_or_duplicate"}}, socket}

  defp relay_reply({:error, reason}, socket),
    do: {:reply, {:error, %{"reason" => to_string(reason)}}, socket}

  defp acceptance(%{assigns: %{session_mode: :scoped, session_lease: lease}}) do
    %{
      "relayed" => true,
      "evidence" => "accepted",
      "issuer" => "burble-admission",
      "protocol" => Admission.protocol(),
      "session_id" => lease.session_id,
      "epoch" => lease.epoch
    }
  end

  defp acceptance(_socket), do: %{"relayed" => true}

  defp relay_broadcast(
         %{assigns: %{session_mode: :scoped, session_lease: lease}} = socket,
         event,
         payload
       ),
       do: broadcast_from(socket, event, %{admission_epoch: lease.epoch, payload: payload})

  defp relay_broadcast(socket, event, payload), do: broadcast_from(socket, event, payload)

  defp bounded(payload, socket) do
    limit = if socket.assigns.session_mode == :scoped, do: @max_payload_bytes, else: 16_384

    case Jason.encode(payload) do
      {:ok, bytes} when byte_size(bytes) <= limit -> :ok
      {:ok, _} -> {:error, :payload_too_large}
      {:error, _} -> {:error, :invalid_payload}
    end
  end

  defp command_tag(%{"cmd" => tag}, profile) when is_binary(tag) do
    if Map.has_key?(profile.command_roles(), tag) do
      {:ok, tag}
    else
      {:error, "unknown command: #{inspect(tag)}"}
    end
  end

  defp command_tag(_payload, _profile),
    do: {:error, "command payload must carry the \"cmd\" tag"}

  # Names what's wrong with a join param: absent, or present but not the
  # required string type. Returns nil when the field is fine, so the caller
  # can build a reason listing only the actual offenders.
  defp field_problem(params, key) when is_map(params) do
    case Map.fetch(params, key) do
      :error -> key
      {:ok, value} when is_binary(value) -> nil
      {:ok, _value} -> "#{key} (must be a string)"
    end
  end

  defp field_problem(_params, key), do: key

  defp authorize(tag, socket) do
    role = socket.assigns.role

    case Burble.Games.sender_for(socket.assigns.profile, tag) do
      :either -> :ok
      ^role -> :ok
      owner -> {:error, "#{tag} is a #{owner} command (you joined as #{role})"}
    end
  end

  # Track the optional "seq" envelope: a fresh (strictly increasing) integer
  # relays; a duplicate or out-of-order one drops gracefully. Commands
  # without "seq" are always fresh — ordering is then the transport's.
  defp note_seq(%{"seq" => seq}, socket) when is_integer(seq) do
    case socket.assigns.last_seq do
      last when is_integer(last) and seq <= last -> {:stale, socket}
      _ -> {:fresh, assign(socket, :last_seq, seq)}
    end
  end

  defp note_seq(_payload, socket), do: {:fresh, socket}
end
