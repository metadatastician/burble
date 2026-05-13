# SPDX-License-Identifier: PMPL-1.0-or-later
#
# BurbleWeb.BoltChannel — Phoenix channel for incoming Bolt notifications.
#
# Topic: "bolt:notifications"
#
# Clients join this channel after page load to receive incoming Bolt events.
# When a Bolt arrives at the UDP listener, Notify.incoming/2 broadcasts on
# Phoenix.PubSub, which this channel receives and forwards to the browser.
#
# The browser then:
#   1. Calls Notification.requestPermission() and fires a desktop notification.
#   2. Shows the "Incoming Bolt" call overlay UI.
#   3. Sends "bolt:accept" or "bolt:dismiss" back when the user responds.
#
# No authentication is required to receive bolt notifications — any connected
# browser can subscribe. Sending a bolt back (bolt:accept triggering a return
# bolt) uses the sender's server URL from the packet payload.

defmodule BurbleWeb.BoltChannel do
  # Match the existing convention in this codebase — other channels
  # (assist_channel, room_channel, signaling_channel) all use `Phoenix.Channel`
  # directly. There is no `BurbleWeb` aggregator module in this project.
  use Phoenix.Channel
  require Logger

  alias Burble.Bolt.{Notify, Sender}

  # ---------------------------------------------------------------------------
  # Join
  # ---------------------------------------------------------------------------

  @impl true
  def join("bolt:notifications", _params, socket) do
    # Subscribe this channel process to PubSub bolt events
    Notify.subscribe()
    {:ok, socket}
  end

  def join("bolt:" <> _, _params, _socket), do: {:error, %{reason: "invalid_topic"}}

  # ---------------------------------------------------------------------------
  # Incoming from browser
  # ---------------------------------------------------------------------------

  @impl true
  def handle_in("bolt:accept", %{"sender" => sender}, socket) do
    # User accepted the bolt — send an acknowledgement bolt back to the sender
    case sender["ip"] do
      nil ->
        {:reply, {:error, %{reason: "no_sender_ip"}}, socket}

      ip_str ->
        result = fire_ack(ip_str, sender)
        {:reply, format_reply(result), socket}
    end
  end

  def handle_in("bolt:dismiss", _params, socket) do
    {:reply, :ok, socket}
  end

  def handle_in("bolt:test", _params, socket) do
    # Let the browser test the notification path without sending a real bolt
    push(socket, "bolt:incoming", %{
      type:    "incoming_bolt",
      sender:  %{display: "Test Bolt", ip: "127.0.0.1"},
      ts:      System.os_time(:millisecond),
      payload: %{"test" => true}
    })
    {:reply, :ok, socket}
  end

  # ---------------------------------------------------------------------------
  # PubSub relay — Bolt arrived at listener, push to browser
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:bolt_incoming, notification}, socket) do
    push(socket, "bolt:incoming", notification)
    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp fire_ack(ip_str, sender) do
    case :inet.parse_address(String.to_charlist(ip_str)) do
      {:ok, ip} ->
        Sender.send({ip, nil}, [
          request_ack: false,
          payload: %{
            "type"    => "bolt_ack",
            "display_name" => sender["display"] || "Burble user"
          }
        ])

      _ ->
        {:error, :bad_ip}
    end
  end

  defp format_reply(:ok), do: :ok
  defp format_reply({:error, reason}), do: {:error, %{reason: inspect(reason)}}
end
