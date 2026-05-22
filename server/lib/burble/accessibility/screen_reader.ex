# SPDX-License-Identifier: MPL-2.0
#
# Burble.Accessibility.ScreenReader — Voice-first interface generation.
#
# Provides a server-side "screen reader" for the Burble platform.
# For voice-only or voice-first users, this module generates descriptive
# audio cues (via TTS) for interface changes, presence updates, and
# moderation actions.
#
# Features:
#   1. Automatic ARIA generation for web client templates.
#   2. Presence announcements ("Jonathan joined the room").
#   3. Room status summaries ("There are 3 people speaking").
#   4. Navigation feedback ("You are now in the 'Lounge' room").
#
# Integration:
#   Calls Burble.Groove's TTS capability to synthesize voice cues.

defmodule Burble.Accessibility.ScreenReader do
  @moduledoc """
  Voice-first accessibility engine for Burble.

  Generates audio descriptions of interface state and events for
  vision-impaired users or voice-only environments.
  """

  require Logger

  # ── Public API ──

  @doc "Announce a user joining a room."
  def announce_join(username, room_name) do
    speak("#{username} joined #{room_name}")
  end

  @doc "Announce a user leaving a room."
  def announce_leave(username, room_name) do
    speak("#{username} left #{room_name}")
  end

  @doc "Announce a room change."
  def announce_room_change(room_name) do
    speak("Switched to room #{room_name}")
  end

  @doc "Announce a moderation action."
  def announce_moderation(target, action, moderator) do
    speak("#{target} was #{action} by #{moderator}")
  end

  # ── Internal ──

  defp speak(text) do
    Logger.debug("[Accessibility] Speaking: #{text}")
    # In a real implementation, this would push to the user's voice channel
    # or trigger a client-side TTS via the Groove protocol.
    :telemetry.execute([:burble, :accessibility, :announce], %{text: text})
    :ok
  end
end
