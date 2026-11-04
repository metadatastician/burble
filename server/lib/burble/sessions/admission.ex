# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
defmodule Burble.Sessions.Admission do
  @moduledoc """
  Single-node, ephemeral session admission authority.

  The trusted host provisions opaque participant, audience and role identifiers.
  A socket must independently authenticate the participant, then consume that
  participant's session/epoch/role ticket. Rejoin needs a separate, rotating
  credential and fences the previous connection before admitting its replacement.

  All lease checks and their effects run in this authority's mailbox. A stale
  connection cannot pass a check, lose its seat, and then publish. Session state
  and sequence high-water marks survive a channel reconnect, not an authority
  restart. A restarted authority knows no sessions: hosts must provision a new
  random epoch. This module issues no durable, delivered or applied receipts.

  `create/4`, `rotate/1` and `close/1` are trusted, in-VM provisioning operations;
  they are deliberately not exposed as unauthenticated socket/HTTP commands.
  """
  use GenServer

  @protocol "admission-v1"
  @max_sessions 256
  @max_seats 16
  @max_lifetime 3_600
  @max_seq 9_007_199_254_740_991

  def protocol, do: @protocol

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Provision a finite-lived session. Returned bearer credentials are secrets."
  def create(session_id, audience, seats, opts \\ []) do
    call({:create, session_id, audience, seats, Keyword.get(opts, :ttl_seconds, 1_800)})
  end

  @doc "Revoke all old tickets/connections and provision a new random epoch."
  def rotate(session_id), do: call({:rotate, session_id})

  def close(session_id), do: call({:close, session_id})

  @doc "Atomically claim a ticket or replace the current lease with a rejoin token."
  def claim(identity, session_id, audience, role, epoch, credential) do
    call({:claim, identity, session_id, audience, role, epoch, credential})
  end

  @doc "Run a bounded effect only while the calling channel owns this lease."
  def with_current(lease, effect) when is_function(effect, 0),
    do: call({:effect, lease, :unsequenced, effect})

  @doc "Run a relay effect once for a strictly increasing, per-seat sequence."
  def relay(lease, seq, effect) when is_function(effect, 0),
    do: call({:effect, lease, seq, effect})

  def leave(lease), do: call({:leave, lease})

  # An unavailable authority cannot degrade to the unauthenticated relay.
  defp call(request) do
    GenServer.call(__MODULE__, request)
  catch
    :exit, _ -> {:error, :authority_unavailable}
  end

  @impl true
  def init(_opts) do
    Process.send_after(self(), :expire, 60_000)
    {:ok, %{sessions: %{}, monitors: %{}}}
  end

  @impl true
  def handle_call({:create, id, audience, roster, ttl}, _from, state) do
    state = expire(state)

    cond do
      not valid_id?(id) or not valid_id?(audience) or not valid_roster?(roster) or
        not is_integer(ttl) or ttl not in 1..@max_lifetime ->
        {:reply, {:error, :invalid_session}, state}

      Map.has_key?(state.sessions, id) ->
        {:reply, {:error, :session_exists}, state}

      map_size(state.sessions) >= @max_sessions ->
        {:reply, {:error, :session_capacity}, state}

      true ->
        {session, provision} = provision(id, audience, roster, ttl, 1)
        {:reply, {:ok, provision}, put_in(state.sessions[id], session)}
    end
  end

  def handle_call({:rotate, id}, _from, state) do
    state = expire(state)

    case Map.fetch(state.sessions, id) do
      {:ok, old} ->
        roster = Map.new(old.seats, fn {role, seat} -> {role, seat.subject} end)
        state = revoke(state, id)
        {session, provision} = provision(id, old.audience, roster, old.ttl, old.revision + 1)
        {:reply, {:ok, provision}, put_in(state.sessions[id], session)}

      :error ->
        {:reply, {:error, :unknown_session}, state}
    end
  end

  def handle_call({:close, id}, _from, state), do: {:reply, :ok, revoke(state, id)}

  def handle_call({:claim, identity, id, audience, role, epoch, credential}, {pid, _}, state) do
    state = expire(state)

    with {:ok, subject, expires_at} <- identity(identity),
         {:ok, session} <- fetch_session(state, id, epoch),
         true <- session.audience == audience,
         {:ok, seat} <- Map.fetch(session.seats, role),
         true <- seat.subject == subject,
         :ok <- credential(seat, credential) do
      state = disconnect(state, id, role, true)
      rejoin = secret()
      lease_id = secret()
      monitor = Process.monitor(pid)

      seat = %{
        seat
        | used: true,
          pid: pid,
          monitor: monitor,
          lease_id: lease_id,
          expires_at: expires_at,
          rejoin_digest: digest(rejoin)
      }

      lease = %{session_id: id, epoch: epoch, role: role, subject: subject, id: lease_id}

      reply = %{
        protocol: @protocol,
        session_id: id,
        epoch: epoch,
        roster_revision: session.revision,
        role: role,
        participant_id: subject,
        rejoin_token: rejoin,
        evidence: "accepted",
        issuer: "burble-admission"
      }

      state =
        state
        |> put_in([:sessions, id, :seats, role], seat)
        |> put_in([:monitors, monitor], {id, role, lease_id})

      {:reply, {:ok, lease, reply}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      _ -> {:reply, {:error, :scope_mismatch}, state}
    end
  end

  def handle_call({:effect, lease, seq, effect}, {pid, _}, state) do
    state = expire(state)

    with {:ok, seat} <- current(state, lease, pid),
         :ok <- sequence(seq, seat.last_seq) do
      # Only trusted, bounded adapters supply effects. Never execute an effect
      # outside the authority after a check, or swallow a failed effect as ACK.
      case effect.() do
        :ok ->
          state =
            if is_integer(seq),
              do: put_in(state.sessions[lease.session_id].seats[lease.role].last_seq, seq),
              else: state

          {:reply, :ok, state}

        {:error, _} = error ->
          {:reply, error, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:leave, lease}, {pid, _}, state) do
    case current(state, lease, pid) do
      {:ok, _seat} ->
        {:reply, :ok, disconnect(state, lease.session_id, lease.role, false)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.fetch(state.monitors, ref) do
      {:ok, {id, role, lease_id}} ->
        case get_in(state.sessions, [id, :seats, role]) do
          %{lease_id: ^lease_id} -> {:noreply, disconnect(state, id, role, false)}
          _ -> {:noreply, %{state | monitors: Map.delete(state.monitors, ref)}}
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(:expire, state) do
    Process.send_after(self(), :expire, 60_000)
    {:noreply, expire(state)}
  end

  # Crash diagnostics must not serialize tickets, rejoin digests or lease IDs.
  @impl true
  def format_status(status) do
    status
    |> Map.put(:state, %{session_count: map_size(status.state.sessions)})
    |> Map.put(:message, :redacted)
    |> Map.put(:log, [])
  end

  defp valid_id?(id),
    do:
      is_binary(id) and byte_size(id) in 1..128 and String.valid?(id) and
        Regex.match?(~r/\A[A-Za-z0-9_.-]+\z/, id)

  defp valid_roster?(roster) when is_map(roster) and map_size(roster) in 1..@max_seats do
    Enum.all?(roster, fn {role, subject} -> valid_id?(role) and valid_id?(subject) end) and
      map_size(roster) == MapSet.size(MapSet.new(Map.values(roster)))
  end

  defp valid_roster?(_), do: false

  defp identity(%{subject: subject, expires_at: expires_at}) do
    if valid_id?(subject) and is_integer(expires_at) and expires_at > now(),
      do: {:ok, subject, expires_at},
      else: {:error, :unauthenticated}
  end

  defp identity(_), do: {:error, :unauthenticated}

  defp provision(id, audience, roster, ttl, revision) do
    epoch = secret()

    {seats, grants} =
      Enum.reduce(roster, {%{}, %{}}, fn {role, subject}, {seats, grants} ->
        ticket = secret()

        seat = %{
          subject: subject,
          ticket_digest: digest(ticket),
          used: false,
          pid: nil,
          monitor: nil,
          lease_id: nil,
          rejoin_digest: nil,
          expires_at: nil,
          last_seq: nil
        }

        grant = %{participant_id: subject, ticket: ticket}
        {Map.put(seats, role, seat), Map.put(grants, role, grant)}
      end)

    session = %{
      audience: audience,
      epoch: epoch,
      revision: revision,
      expires_at: now() + ttl,
      deadline: System.monotonic_time(:second) + ttl,
      ttl: ttl,
      seats: seats
    }

    provision = %{
      protocol: @protocol,
      session_id: id,
      audience: audience,
      epoch: epoch,
      roster_revision: revision,
      expires_at: session.expires_at,
      grants: grants
    }

    {session, provision}
  end

  defp credential(%{used: false, ticket_digest: expected}, {:ticket, token}) do
    if matches?(token, expected), do: :ok, else: {:error, :invalid_ticket}
  end

  defp credential(%{used: true}, {:ticket, _}), do: {:error, :ticket_consumed}

  defp credential(%{used: true, rejoin_digest: expected}, {:rejoin, token}) do
    if matches?(token, expected), do: :ok, else: {:error, :invalid_rejoin}
  end

  defp credential(_, _), do: {:error, :invalid_ticket}

  defp matches?(token, expected)
       when is_binary(token) and byte_size(token) == 43 and is_binary(expected),
       do: Plug.Crypto.secure_compare(digest(token), expected)

  defp matches?(_, _), do: false

  defp fetch_session(state, id, epoch) do
    case Map.fetch(state.sessions, id) do
      {:ok, %{epoch: ^epoch} = session} -> {:ok, session}
      {:ok, _} -> {:error, :stale_epoch}
      :error -> {:error, :unknown_session}
    end
  end

  defp current(
         state,
         %{session_id: id, epoch: epoch, role: role, subject: subject, id: lease_id},
         pid
       ) do
    with {:ok, session} <- fetch_session(state, id, epoch),
         %{pid: ^pid, subject: ^subject, lease_id: ^lease_id, expires_at: expiry} = seat <-
           Map.get(session.seats, role),
         true <- is_integer(expiry) and expiry > now() do
      {:ok, seat}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :stale_lease}
    end
  end

  defp current(_, _, _), do: {:error, :stale_lease}

  defp sequence(:unsequenced, _), do: :ok

  defp sequence(seq, last) when is_integer(seq) and seq in 0..@max_seq do
    if is_integer(last) and seq <= last, do: {:error, :stale_or_duplicate}, else: :ok
  end

  defp sequence(_, _), do: {:error, :invalid_sequence}

  defp disconnect(state, id, role, fence?) do
    seat = state.sessions[id].seats[role]

    if seat.monitor, do: Process.demonitor(seat.monitor, [:flush])
    if fence? and seat.pid, do: send(seat.pid, :session_fenced)

    disconnected = %{seat | pid: nil, monitor: nil, lease_id: nil, expires_at: nil}

    state
    |> put_in([:sessions, id, :seats, role], disconnected)
    |> Map.update!(:monitors, &Map.delete(&1, seat.monitor))
  end

  defp revoke(state, id) do
    case Map.get(state.sessions, id) do
      nil ->
        state

      session ->
        state = Enum.reduce(Map.keys(session.seats), state, &disconnect(&2, id, &1, true))
        %{state | sessions: Map.delete(state.sessions, id)}
    end
  end

  defp expire(state) do
    now = System.monotonic_time(:second)

    Enum.reduce(state.sessions, state, fn {id, session}, acc ->
      if session.deadline <= now, do: revoke(acc, id), else: acc
    end)
  end

  defp now, do: System.system_time(:second)
  defp secret, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  defp digest(secret), do: :crypto.hash(:sha256, secret)
end
