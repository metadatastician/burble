# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Burble.Presence.KaomojiStatus — Animated kaomoji status indicators.
#
# Lightweight non-verbal expression system. Users set a kaomoji status
# that animates next to their name in the participant list. No typing
# needed — pick from a palette or use a keyboard shortcut.
#
# Categories:
#   Availability  — busy, available, away, do not disturb
#   Reaction      — laughing, confused, agreeing, disagreeing
#   Technical     — can't hear, mic issues, lag, audio test
#   Gaming        — dying, winning, AFK, concentrating
#   Custom        — any kaomoji string (auto-expires)
#
# Animation: kaomoji cycle through 2-4 frames at 500ms intervals.
# Broadcast via Phoenix Presence so all participants see updates instantly.

defmodule Burble.Presence.KaomojiStatus do
  @moduledoc """
  Animated kaomoji status indicators for voice participants.

  Set a status that appears next to your name — no interruption to voice,
  no text message needed, just a quick visual expression.

  ## Usage

      KaomojiStatus.set(room_id, user_id, :cant_hear)
      KaomojiStatus.set(room_id, user_id, {:custom, "(╯°□°)╯︵ ┻━┻"})
      KaomojiStatus.clear(room_id, user_id)
  """

  # ---------------------------------------------------------------------------
  # Built-in status kaomoji (with animation frames)
  # ---------------------------------------------------------------------------

  @statuses %{
    # --- Availability ---
    available:    %{category: :availability, label: "Available",
                    frames: ["(•‿•)", "(•‿•)b"],
                    shortcut: "F5"},
    busy:         %{category: :availability, label: "Busy",
                    frames: ["(•̀ᴗ•́)و", "(•̀ᴗ•́)و✎", "(•̀ᴗ•́)و✎•••"],
                    shortcut: "F6"},
    away:         %{category: :availability, label: "Away",
                    frames: ["(－ω－) zzZ", "(－ω－) zzZZ", "(－ω－) zzZZZ"],
                    shortcut: "F7"},
    dnd:          %{category: :availability, label: "Do Not Disturb",
                    frames: ["(ー_ー)!!", "(ー_ー)!!"],
                    shortcut: "F8"},

    # --- Reactions ---
    laughing:     %{category: :reaction, label: "Laughing",
                    frames: ["( ´∀`)", "(ノ´∀`)ノ", "ヽ(´∀`)ノ", "(ノ´∀`)ノ"],
                    shortcut: nil},
    confused:     %{category: :reaction, label: "Confused",
                    frames: ["(・・?)", "(・・ )?", "(・・ )??"],
                    shortcut: nil},
    agreeing:     %{category: :reaction, label: "Agreeing",
                    frames: ["(•̀ᴗ•́)و✧", "(•̀ᴗ•́)و ✧"],
                    shortcut: nil},
    disagreeing:  %{category: :reaction, label: "Disagreeing",
                    frames: ["(；￣Д￣)", "(；￣Д￣)ﾉ"],
                    shortcut: nil},
    love:         %{category: :reaction, label: "Love it",
                    frames: ["(♡‿♡)", "(♡ᴗ♡)", "(♡‿♡)"],
                    shortcut: nil},
    thinking:     %{category: :reaction, label: "Thinking",
                    frames: ["(　-_-)  ✎", "(　-_-)  ✎•", "(　-_-)  ✎••", "(　-_-)  ✎•••"],
                    shortcut: nil},
    clapping:     %{category: :reaction, label: "Clapping",
                    frames: ["(•‿•)👏", "(•‿•) 👏", "(•‿•)  👏"],
                    shortcut: nil},

    # --- Technical (these are the critical ones for voice) ---
    cant_hear:    %{category: :technical, label: "Can't hear you",
                    frames: ["(◉_◉)??", "(◉_◉) ??", "(◉_◉)  ¿¿"],
                    shortcut: "F9"},
    mic_issues:   %{category: :technical, label: "Mic problems",
                    frames: ["(>_<) 🎤✗", "(>_<)  🎤✗"],
                    shortcut: "F10"},
    lag:          %{category: :technical, label: "Lagging",
                    frames: ["(⊙_⊙)⏳", "(⊙_⊙) ⏳", "(⊙_⊙)  ⏳"],
                    shortcut: nil},
    audio_test:   %{category: :technical, label: "Testing audio",
                    frames: ["(•‿•)♪", "(•‿•)♫", "(•‿•)♪♫"],
                    shortcut: nil},
    brb:          %{category: :technical, label: "Be right back",
                    frames: ["(•_•)⌐■-■", "(⌐■_■)"],
                    shortcut: nil},
    reconnecting: %{category: :technical, label: "Reconnecting",
                    frames: ["(◞‸◟)↻", "(◞‸◟) ↻", "(◞‸◟)  ↻"],
                    shortcut: nil},

    # --- Gaming ---
    dying:        %{category: :gaming, label: "Dying / help",
                    frames: ["(×_×;)", "(×_×;)⌇", "_(×_×;)⌇_"],
                    shortcut: nil},
    winning:      %{category: :gaming, label: "Winning!",
                    frames: ["╰(*°▽°*)╯", "ヽ(>∀<☆)ノ", "╰(*°▽°*)╯"],
                    shortcut: nil},
    afk:          %{category: :gaming, label: "AFK",
                    frames: ["(∪｡∪)｡｡｡zzZ", "(∪｡∪)｡｡｡zzZZ"],
                    shortcut: nil},
    concentrating: %{category: :gaming, label: "Concentrating",
                    frames: ["(ง •̀_•́)ง", "(ง •̀_•́)ง !!"],
                    shortcut: nil},
    gg:           %{category: :gaming, label: "GG",
                    frames: ["(•‿•)gg", "(•‿•) GG"],
                    shortcut: nil},
    rage:         %{category: :gaming, label: "Rage",
                    frames: ["(╯°□°)╯", "(╯°□°)╯︵", "(╯°□°)╯︵ ┻━┻"],
                    shortcut: nil},
  }

  @animation_interval_ms 500
  @auto_expire_seconds 300  # Custom statuses expire after 5 minutes.

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Set a kaomoji status for a user in a room."
  def set(room_id, user_id, status_key) when is_atom(status_key) do
    case Map.get(@statuses, status_key) do
      nil -> {:error, :unknown_status}
      status ->
        broadcast_status(room_id, user_id, %{
          key: status_key,
          label: status.label,
          frames: status.frames,
          interval_ms: @animation_interval_ms,
          expires_at: nil
        })
    end
  end

  def set(room_id, user_id, {:custom, kaomoji}) when is_binary(kaomoji) do
    # Custom kaomoji — single frame, auto-expires.
    broadcast_status(room_id, user_id, %{
      key: :custom,
      label: "Custom",
      frames: [kaomoji],
      interval_ms: @animation_interval_ms,
      expires_at: DateTime.add(DateTime.utc_now(), @auto_expire_seconds) |> DateTime.to_iso8601()
    })
  end

  @doc "Clear the kaomoji status for a user."
  def clear(room_id, user_id) do
    broadcast_status(room_id, user_id, nil)
  end

  @doc "Get all available status kaomoji grouped by category."
  def palette do
    @statuses
    |> Enum.group_by(fn {_key, status} -> status.category end)
    |> Enum.map(fn {category, entries} ->
      %{
        category: category,
        statuses: Enum.map(entries, fn {key, status} ->
          %{
            key: key,
            label: status.label,
            preview: List.first(status.frames),
            shortcut: status.shortcut
          }
        end)
      }
    end)
  end

  @doc "Get the animation frames for a status key."
  def get_frames(status_key) do
    case Map.get(@statuses, status_key) do
      nil -> []
      status -> status.frames
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp broadcast_status(room_id, user_id, status) do
    Phoenix.PubSub.broadcast(
      Burble.PubSub,
      "room:#{room_id}",
      {:kaomoji_status, user_id, status}
    )
    :ok
  end
end
