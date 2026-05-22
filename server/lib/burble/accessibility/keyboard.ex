# SPDX-License-Identifier: MPL-2.0
#
# Burble.Accessibility.Keyboard — Server-side keyboard binding management.
#
# Manages user-defined keybindings for room-level actions (PTT, mute,
# room switch, volume control). Keybindings are persisted in VeriSimDB
# and synchronized across client sessions via Phoenix Channels.
#
# This allows users to maintain consistent keyboard accessibility across
# web and desktop clients.

defmodule Burble.Accessibility.Keyboard do
  @moduledoc """
  Manages accessibility-focused keyboard bindings for Burble.

  Synchronizes keybindings across client sessions and provides
  defaults for PTT (Push-To-Talk) and room navigation.
  """

  # ── Types ──

  @type action :: :ptt | :mute | :deafen | :volume_up | :volume_down | :next_room | :prev_room

  @default_bindings %{
    "Space" => :ptt,
    "m" => :mute,
    "d" => :deafen,
    "ArrowUp" => :volume_up,
    "ArrowDown" => :volume_down,
    "Tab" => :next_room,
    "Shift+Tab" => :prev_room
  }

  # ── Public API ──

  @doc "Get default keybindings."
  def default_bindings, do: @default_bindings

  @doc "Get bindings for a specific user from VeriSimDB."
  def get_user_bindings(user_id) do
    case Burble.Store.get_user(user_id) do
      {:ok, user} -> 
        # Preferences are stored in the user document
        Map.get(user, :keybindings) || @default_bindings
      _ -> 
        @default_bindings
    end
  end

  @doc "Save user-defined keybindings."
  def set_user_bindings(user_id, bindings) do
    Burble.Store.update_user(user_id, %{keybindings: bindings})
  end
end
