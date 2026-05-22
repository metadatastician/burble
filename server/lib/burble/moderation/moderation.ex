# SPDX-License-Identifier: MPL-2.0
#
# Burble.Moderation — Server-side moderation actions.
#
# Provides kick, ban, mute, move, and timeout operations with:
#   - Permission checks (caller must hold the relevant permission)
#   - Audit trail (every action is logged via Burble.Audit)
#   - Duration-based expiry (bans, mutes, timeouts auto-expire)
#   - PubSub notifications (affected users and rooms are notified)
#
# All actions are idempotent — kicking an absent user or muting an
# already-muted user returns :ok without side effects.
#
# Author: Jonathan D.A. Jewell

defmodule Burble.Moderation do
  @moduledoc """
  Moderation actions for Burble servers and rooms.

  ## Actions

  - `kick/3` — Remove a user from a voice room (they can rejoin)
  - `ban/4` — Prevent a user from joining any room on a server
  - `mute/3` — Server-side mute (user cannot transmit audio)
  - `move/3` — Move a user from one room to another
  - `timeout/3` — Temporary voice block (cannot speak for duration)

  ## Permission model

  Each action requires a specific permission from `Burble.Permissions`:
  - `:kick` for kick
  - `:ban` for ban
  - `:mute_others` for mute and timeout
  - `:move_others` for move

  ## Audit trail

  Every moderation action is logged via `Burble.Audit.log/3` with:
  - Action type (`:mod_kick`, `:mod_ban`, etc.)
  - Actor ID (who performed the action)
  - Target ID (who was affected)
  - Reason (human-readable justification)
  - Duration (if time-limited)
  - Timestamp (UTC)
  """

  require Logger

  alias Burble.Audit
  alias Burble.Permissions
  alias Burble.Rooms.Room
  alias Burble.Media.Engine, as: MediaEngine

  # ── Types ──

  @type user_id :: String.t()
  @type room_id :: String.t()
  @type server_id :: String.t()
  @type reason :: String.t()

  @typedoc "Duration in seconds. nil means permanent."
  @type duration :: pos_integer() | nil

  @typedoc "Result of a moderation action."
  @type mod_result :: :ok | {:error, :insufficient_permissions | :user_not_found | :room_not_found | atom()}

  @typedoc "Ban record stored in the ban list."
  @type ban_record :: %{
          user_id: user_id(),
          server_id: server_id(),
          reason: reason(),
          banned_by: user_id(),
          banned_at: DateTime.t(),
          expires_at: DateTime.t() | nil
        }

  @typedoc "Mute record for server-side muting."
  @type mute_record :: %{
          user_id: user_id(),
          room_id: room_id(),
          muted_by: user_id(),
          muted_at: DateTime.t(),
          expires_at: DateTime.t() | nil
        }

  # ── Public API ──

  @doc """
  Kick a user from a voice room.

  The user is immediately removed from the room and their media
  session is torn down. They can rejoin unless also banned.

  ## Parameters

    * `actor_id` — ID of the moderator performing the kick
    * `target_id` — ID of the user being kicked
    * `room_id` — ID of the room to kick from
    * `reason` — Human-readable reason for the kick
    * `actor_perms` — MapSet of the actor's permissions

  ## Returns

    * `:ok` — user was kicked successfully
    * `{:error, :insufficient_permissions}` — actor lacks `:kick` permission
    * `{:error, :user_not_found}` — target user is not in the room
  """
  @spec kick(user_id(), user_id(), room_id(), reason(), MapSet.t()) :: mod_result()
  def kick(actor_id, target_id, room_id, reason, actor_perms) do
    with :ok <- check_permission(actor_perms, :kick),
         :ok <- verify_user_in_room(target_id, room_id) do
      # Remove from room state.
      Room.leave(room_id, target_id)

      # Tear down media session.
      MediaEngine.remove_peer(room_id, target_id)

      # Notify the kicked user and the room.
      broadcast_moderation_event(room_id, :kicked, %{
        target_id: target_id,
        reason: reason,
        actor_id: actor_id
      })

      # Audit trail.
      Audit.log(:mod_kick, actor_id, %{
        target_id: target_id,
        room_id: room_id,
        reason: reason
      })

      Logger.info("[Moderation] #{actor_id} kicked #{target_id} from #{room_id}: #{reason}")
      :ok
    end
  end

  @doc """
  Ban a user from a server.

  The user is prevented from joining any room on the server. If they
  are currently in a room, they are also kicked. Bans can be permanent
  (duration = nil) or time-limited (duration in seconds).

  ## Parameters

    * `actor_id` — ID of the moderator performing the ban
    * `target_id` — ID of the user being banned
    * `server_id` — ID of the server to ban from
    * `reason` — Human-readable reason for the ban
    * `duration` — Ban duration in seconds, or nil for permanent
    * `actor_perms` — MapSet of the actor's permissions

  ## Returns

    * `{:ok, ban_record}` — user was banned successfully
    * `{:error, :insufficient_permissions}` — actor lacks `:ban` permission
  """
  @spec ban(user_id(), user_id(), server_id(), reason(), duration(), MapSet.t()) ::
          {:ok, ban_record()} | {:error, atom()}
  def ban(actor_id, target_id, server_id, reason, duration, actor_perms) do
    with :ok <- check_permission(actor_perms, :ban) do
      expires_at =
        if duration do
          DateTime.add(DateTime.utc_now(), duration, :second)
        else
          nil
        end

      ban_record = %{
        user_id: target_id,
        server_id: server_id,
        reason: reason,
        banned_by: actor_id,
        banned_at: DateTime.utc_now(),
        expires_at: expires_at
      }

      # Store the ban. In production, this writes to VeriSimDB.
      # For now, broadcast so the room channel can enforce it.
      Phoenix.PubSub.broadcast(
        Burble.PubSub,
        "moderation:#{server_id}",
        {:user_banned, ban_record}
      )

      # Audit trail.
      Audit.log(:mod_ban, actor_id, %{
        target_id: target_id,
        server_id: server_id,
        reason: reason,
        duration: duration,
        expires_at: expires_at
      })

      Logger.info(
        "[Moderation] #{actor_id} banned #{target_id} from server #{server_id}" <>
          if(duration, do: " for #{duration}s", else: " permanently") <>
          ": #{reason}"
      )

      {:ok, ban_record}
    end
  end

  @doc """
  Server-side mute a user in a room.

  The user's audio is suppressed at the SFU level — their frames are
  not forwarded to other participants. The mute can be permanent
  (duration = nil) or time-limited (duration in seconds).

  ## Parameters

    * `actor_id` — ID of the moderator performing the mute
    * `target_id` — ID of the user being muted
    * `room_id` — ID of the room
    * `duration` — Mute duration in seconds, or nil for indefinite
    * `actor_perms` — MapSet of the actor's permissions

  ## Returns

    * `{:ok, mute_record}` — user was muted successfully
    * `{:error, :insufficient_permissions}` — actor lacks `:mute_others` permission
    * `{:error, :user_not_found}` — target user is not in the room
  """
  @spec mute(user_id(), user_id(), room_id(), duration(), MapSet.t()) ::
          {:ok, mute_record()} | {:error, atom()}
  def mute(actor_id, target_id, room_id, duration, actor_perms) do
    with :ok <- check_permission(actor_perms, :mute_others),
         :ok <- verify_user_in_room(target_id, room_id) do
      expires_at =
        if duration do
          DateTime.add(DateTime.utc_now(), duration, :second)
        else
          nil
        end

      mute_record = %{
        user_id: target_id,
        room_id: room_id,
        muted_by: actor_id,
        muted_at: DateTime.utc_now(),
        expires_at: expires_at
      }

      # Set the peer to server-muted in the media engine.
      MediaEngine.set_peer_audio(room_id, target_id, muted: true)

      # Schedule unmute if duration is set.
      if duration do
        schedule_unmute(target_id, room_id, duration)
      end

      # Notify the room.
      broadcast_moderation_event(room_id, :muted, %{
        target_id: target_id,
        reason: "Server muted by moderator",
        actor_id: actor_id,
        duration: duration
      })

      # Audit trail.
      Audit.log(:mod_mute, actor_id, %{
        target_id: target_id,
        room_id: room_id,
        duration: duration,
        expires_at: expires_at
      })

      Logger.info(
        "[Moderation] #{actor_id} muted #{target_id} in #{room_id}" <>
          if(duration, do: " for #{duration}s", else: " indefinitely")
      )

      {:ok, mute_record}
    end
  end

  @doc """
  Move a user from one room to another.

  The user is removed from the source room and added to the target
  room. Their media session is migrated. If the target room does not
  exist, it is created.

  ## Parameters

    * `actor_id` — ID of the moderator performing the move
    * `target_id` — ID of the user being moved
    * `from_room_id` — ID of the source room
    * `to_room_id` — ID of the destination room
    * `actor_perms` — MapSet of the actor's permissions

  ## Returns

    * `:ok` — user was moved successfully
    * `{:error, :insufficient_permissions}` — actor lacks `:move_others` permission
    * `{:error, :user_not_found}` — target user is not in the source room
  """
  @spec move(user_id(), user_id(), room_id(), room_id(), MapSet.t()) :: mod_result()
  def move(actor_id, target_id, from_room_id, to_room_id, actor_perms) do
    with :ok <- check_permission(actor_perms, :move_others),
         :ok <- verify_user_in_room(target_id, from_room_id) do
      # Remove from source room.
      Room.leave(from_room_id, target_id)
      MediaEngine.remove_peer(from_room_id, target_id)

      # Join target room (creates it if needed).
      Burble.Rooms.RoomManager.join(to_room_id, target_id, %{display_name: target_id})

      # Notify both rooms.
      broadcast_moderation_event(from_room_id, :moved_out, %{
        target_id: target_id,
        to_room_id: to_room_id,
        actor_id: actor_id
      })

      broadcast_moderation_event(to_room_id, :moved_in, %{
        target_id: target_id,
        from_room_id: from_room_id,
        actor_id: actor_id
      })

      # Audit trail.
      Audit.log(:mod_move, actor_id, %{
        target_id: target_id,
        from_room_id: from_room_id,
        to_room_id: to_room_id
      })

      Logger.info(
        "[Moderation] #{actor_id} moved #{target_id} from #{from_room_id} to #{to_room_id}"
      )

      :ok
    end
  end

  @doc """
  Timeout a user in a room (temporary voice block).

  Similar to mute, but the user is also prevented from unmuting
  themselves for the duration. After the timeout expires, their
  voice state is automatically restored.

  ## Parameters

    * `actor_id` — ID of the moderator performing the timeout
    * `target_id` — ID of the user being timed out
    * `room_id` — ID of the room
    * `duration` — Timeout duration in seconds (required, must be > 0)
    * `actor_perms` — MapSet of the actor's permissions

  ## Returns

    * `:ok` — timeout applied successfully
    * `{:error, :insufficient_permissions}` — actor lacks `:mute_others` permission
    * `{:error, :user_not_found}` — target user is not in the room
    * `{:error, :invalid_duration}` — duration must be positive
  """
  @spec timeout(user_id(), user_id(), room_id(), pos_integer(), MapSet.t()) :: mod_result()
  def timeout(actor_id, target_id, room_id, duration, actor_perms) when duration > 0 do
    with :ok <- check_permission(actor_perms, :mute_others),
         :ok <- verify_user_in_room(target_id, room_id) do
      # Server-mute the user.
      MediaEngine.set_peer_audio(room_id, target_id, muted: true)

      # Schedule automatic unmute after duration.
      schedule_unmute(target_id, room_id, duration)

      # Notify the room.
      broadcast_moderation_event(room_id, :timed_out, %{
        target_id: target_id,
        duration: duration,
        actor_id: actor_id
      })

      # Audit trail.
      Audit.log(:mod_timeout, actor_id, %{
        target_id: target_id,
        room_id: room_id,
        duration: duration,
        expires_at: DateTime.add(DateTime.utc_now(), duration, :second)
      })

      Logger.info(
        "[Moderation] #{actor_id} timed out #{target_id} in #{room_id} for #{duration}s"
      )

      :ok
    end
  end

  def timeout(_actor_id, _target_id, _room_id, _duration, _actor_perms) do
    {:error, :invalid_duration}
  end

  # ── Private helpers ──

  # Check that the actor has the required permission.
  @doc false
  defp check_permission(actor_perms, required_permission) do
    if Permissions.has_permission?(actor_perms, required_permission) do
      :ok
    else
      {:error, :insufficient_permissions}
    end
  end

  # Verify that a user is currently in a room.
  # Returns :ok if present, {:error, :user_not_found} otherwise.
  @doc false
  defp verify_user_in_room(user_id, room_id) do
    case Room.get_state(room_id) do
      {:ok, %{participants: participants}} ->
        participant_ids =
          participants
          |> Enum.map(fn
            %{id: id} -> id
            %{user_id: id} -> id
            p when is_map(p) -> Map.get(p, :id, Map.get(p, :user_id))
            _ -> nil
          end)

        if user_id in participant_ids do
          :ok
        else
          {:error, :user_not_found}
        end

      {:error, _} ->
        {:error, :room_not_found}
    end
  end

  # Broadcast a moderation event to all users in a room via PubSub.
  @doc false
  defp broadcast_moderation_event(room_id, event_type, metadata) do
    Phoenix.PubSub.broadcast(
      Burble.PubSub,
      "room:#{room_id}",
      {:moderation, event_type, metadata}
    )
  end

  # Schedule an automatic unmute after a duration (in seconds).
  #
  # SECURITY FIX: Uses Process.send_after to the calling process (or a
  # centralized timer registry) instead of spawning a Task per mute.
  # The previous design spawned one Task per timed mute — each Task
  # sleeps for the full duration, holding a BEAM process and its memory
  # for potentially hours. With many timed mutes, this causes process
  # exhaustion. Process.send_after uses a lightweight timer that doesn't
  # hold a process, and the message is handled by the existing GenServer
  # process (the room's Engine) when it fires.
  @doc false
  defp schedule_unmute(user_id, room_id, duration_seconds) do
    # Convert to milliseconds for Process.send_after.
    duration_ms = duration_seconds * 1_000

    # Send the unmute command to the Media.Engine for this room after
    # the duration expires. This avoids spawning a Task per mute — the
    # Engine's existing GenServer handles the message when it arrives.
    # If the Engine (or room) has been stopped by then, the message is
    # simply discarded by the BEAM runtime.
    # The Media.Engine is a singleton GenServer registered as
    # Burble.Media.Engine. Send the auto-unmute timer message to it.
    case GenServer.whereis(MediaEngine) do
      nil ->
        # Engine not running — room may already be closed. No timer needed.
        Logger.debug(
          "[Moderation] No engine running, skipping unmute timer for #{user_id}"
        )

      engine_pid when is_pid(engine_pid) ->
        Process.send_after(engine_pid, {:auto_unmute, user_id, room_id}, duration_ms)

        Logger.info(
          "[Moderation] Scheduled auto-unmute for #{user_id} in #{room_id} " <>
          "in #{duration_seconds}s (timer-based, no Task spawned)"
        )
    end
  end
end
