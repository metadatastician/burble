# SPDX-License-Identifier: MPL-2.0
#
# Burble.Permissions — Role-based permission system.
#
# Designed to be powerful but understandable:
#   - Role templates for common setups (Admin, Moderator, Member, Guest)
#   - Clear inheritance model (role -> channel overrides)
#   - Readable effective-permissions evaluation
#   - No ACL terror — if a permission question can't be answered
#     by reading the role + channel override, the system is wrong.

defmodule Burble.Permissions do
  @moduledoc """
  Permission evaluation for Burble servers.

  ## Permission model

  Permissions are bit flags on roles. A user's effective permissions
  in a channel are: `(role_permissions | channel_allow) & ~channel_deny`

  ## Built-in permissions

  Voice:
  - `:join_room` — enter a voice room
  - `:speak` — unmute and transmit audio
  - `:priority_speaker` — speak over others (attenuation)
  - `:whisper` — direct audio to specific users
  - `:mute_others` — server-mute other users
  - `:deafen_others` — server-deafen other users
  - `:move_others` — move users between rooms

  Text:
  - `:text` — send text messages
  - `:chat_send` — send chat messages (LLM-specific)
  - `:pin_messages` — pin messages in channels
  - `:manage_messages` — delete others' messages

  Admin:
  - `:manage_rooms` — create/edit/delete rooms
  - `:manage_roles` — create/edit roles (up to own level)
  - `:manage_server` — server-wide settings
  - `:manage_invites` — create/revoke invite links
  - `:kick` — kick users from server
  - `:ban` — ban users from server
  - `:view_audit_log` — access audit log

  ## Built-in roles

  - `:admin` — full access to all permissions
  - `:moderator` — moderation capabilities without server management
  - `:member` — regular user with speak and chat capabilities
  - `:guest` — limited access, speak only
  - `:llm` — LLM participant with selective capabilities (join, speak, chat_send)
  """

  @all_permissions [
    :join_room,
    :speak,
    :priority_speaker,
    :whisper,
    :mute_others,
    :deafen_others,
    :move_others,
    :text,
    :chat_send,
    :pin_messages,
    :manage_messages,
    :manage_rooms,
    :manage_roles,
    :manage_server,
    :manage_invites,
    :kick,
    :ban,
    :view_audit_log
  ]

  @doc "All defined permissions."
  def all_permissions, do: @all_permissions

  @doc "Default role templates."
  def role_template(:admin) do
    MapSet.new(@all_permissions)
  end

  def role_template(:moderator) do
    MapSet.new([
      :join_room,
      :speak,
      :priority_speaker,
      :whisper,
      :mute_others,
      :deafen_others,
      :move_others,
      :text,
      :pin_messages,
      :manage_messages,
      :kick,
      :view_audit_log
    ])
  end

  def role_template(:member) do
    MapSet.new([:join_room, :speak, :whisper, :text])
  end

  def role_template(:guest) do
    MapSet.new([:join_room, :speak, :text])
  end

  def role_template(:llm) do
    MapSet.new([:join_room, :speak, :chat_send])
  end

  @doc """
  Evaluate effective permissions for a user in a channel.

  Takes the user's role permissions and applies channel-specific
  allow/deny overrides.
  """
  def effective_permissions(role_perms, channel_allow \\ MapSet.new(), channel_deny \\ MapSet.new()) do
    role_perms
    |> MapSet.union(channel_allow)
    |> MapSet.difference(channel_deny)
  end

  @doc "Check if a permission set includes a specific permission."
  def has_permission?(perms, permission) do
    MapSet.member?(perms, permission)
  end

  @doc "Check if a user can perform an action in a channel."
  def can?(role_perms, permission, channel_allow \\ MapSet.new(), channel_deny \\ MapSet.new()) do
    effective_permissions(role_perms, channel_allow, channel_deny)
    |> has_permission?(permission)
  end

  @doc """
  Validate that a participant with the LLM role has only the required permissions.
  
  LLM participants should only have :join_room, :speak, and :chat_send capabilities.
  This prevents LLM participants from having human-facing controls like :hand_raise or :mute_self.
  """
  def validate_llm_permissions(perms) do
    required = MapSet.new([:join_room, :speak, :chat_send])
    forbidden = MapSet.new([:hand_raise, :mute_self, :mute_others, :kick, :ban, :manage_rooms, :manage_roles, :manage_server])
    
    # LLM must have exactly the required permissions
    perms == required && MapSet.disjoint?(perms, forbidden)
  end

  @doc """
  Check if a participant is an LLM based on their permissions.
  
  Returns true if the participant has the exact LLM permission set.
  """
  def is_llm?(perms) do
    validate_llm_permissions(perms)
  end
end
