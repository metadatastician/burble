# SPDX-License-Identifier: MPL-2.0
#
# Burble.Rooms.Participant — Voice room participant state.
#
# Tracks a single user's presence and voice state within a room.
# Immutable struct — updates return new structs.

defmodule Burble.Rooms.Participant do
  @moduledoc """
  Represents a user's state within a voice room.

  Voice states:
  - `:connected` — active, mic on
  - `:muted` — self-muted (can still hear)
  - `:deafened` — can't hear or speak
  - `:priority` — priority speaker (others attenuated)
  """

  @type voice_state :: :connected | :muted | :deafened | :priority

  @type t :: %__MODULE__{
          user_id: String.t(),
          display_name: String.t(),
          voice_state: voice_state(),
          joined_at: DateTime.t(),
          is_speaking: boolean(),
          volume: float()
        }

  @enforce_keys [:user_id, :display_name]
  defstruct [
    :user_id,
    :display_name,
    voice_state: :connected,
    joined_at: nil,
    is_speaking: false,
    volume: 1.0
  ]

  @doc "Create a new participant from user info."
  def new(user_id, user_info) do
    %__MODULE__{
      user_id: user_id,
      display_name: Map.get(user_info, :display_name, "Guest"),
      voice_state: :connected,
      joined_at: DateTime.utc_now(),
      is_speaking: false,
      volume: 1.0
    }
  end

  @doc "Update voice state."
  def set_voice_state(%__MODULE__{} = p, state)
      when state in [:connected, :muted, :deafened, :priority] do
    %{p | voice_state: state, is_speaking: state == :connected or state == :priority}
  end

  @doc "Mark as speaking or not."
  def set_speaking(%__MODULE__{} = p, speaking?) do
    %{p | is_speaking: speaking?}
  end

  @doc "Set per-user volume (0.0 to 2.0)."
  def set_volume(%__MODULE__{} = p, vol) when vol >= 0.0 and vol <= 2.0 do
    %{p | volume: vol}
  end

  @doc "Summary map for client consumption."
  def summarise(%__MODULE__{} = p) do
    %{
      user_id: p.user_id,
      display_name: p.display_name,
      voice_state: p.voice_state,
      is_speaking: p.is_speaking,
      volume: p.volume
    }
  end
end
