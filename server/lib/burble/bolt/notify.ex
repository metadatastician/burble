# SPDX-License-Identifier: MPL-2.0
#
# Burble.Bolt.Notify — dispatch an incoming Bolt to browser + desktop.
#
# When the Listener receives a valid Bolt packet, it calls Notify.incoming/2.
# Notify broadcasts over Phoenix.PubSub on the topic "bolt:notifications",
# which BurbleWeb.BoltChannel forwards to every connected browser tab.
#
# The browser then:
#   1. Fires the Web Notifications API for a desktop pop-up.
#   2. Renders an "Incoming Bolt" call overlay with Accept / Dismiss buttons.
#   3. If accepted, auto-navigates to a new voice room (or opens one).
#
# Future: OS-level desktop notification via Ephapax IPC when the desktop
# client is running.

defmodule Burble.Bolt.Notify do
  require Logger

  alias Burble.Bolt.Packet

  @pubsub Burble.PubSub
  @topic  "bolt:notifications"

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Dispatch a received bolt packet as an incoming-call notification.

  Broadcasts on PubSub so BoltChannel can forward to connected browsers.
  """
  @spec incoming(Packet.t(), String.t()) :: :ok
  def incoming(%Packet{} = packet, src_ip) do
    sender = extract_sender(packet, src_ip)

    notification = %{
      type:        "incoming_bolt",
      sender:      sender,
      ts:          System.os_time(:millisecond),
      request_ack: packet.request_ack,
      payload:     packet.payload
    }

    Logger.info("[Bolt] Incoming bolt from #{sender.display} (#{src_ip})")

    Phoenix.PubSub.broadcast(@pubsub, @topic, {:bolt_incoming, notification})

    if packet.request_ack do
      acknowledge(src_ip, packet)
    end

    :ok
  end

  @doc """
  Subscribe to incoming bolt notifications.

  Messages delivered as `{:bolt_incoming, notification_map}`.
  """
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp extract_sender(packet, src_ip) do
    payload = packet.payload || %{}

    mac_str =
      case packet.sender_mac do
        nil -> nil
        mac -> Packet.format_mac(mac)
      end

    %{
      ip:      src_ip,
      mac:     mac_str,
      node:    payload["from"],
      server:  payload["server"],
      display: display_name(payload, src_ip)
    }
  end

  defp display_name(payload, src_ip) do
    cond do
      name = payload["display_name"] -> name
      node = payload["from"]         -> node
      true                           -> src_ip
    end
  end

  defp acknowledge(src_ip, original_packet) do
    # Send a return bolt to the sender (best-effort, no recursive ack)
    alias Burble.Bolt.{Sender, Packet}

    case :inet.parse_address(String.to_charlist(src_ip)) do
      {:ok, ip} ->
        Sender.send({ip, original_packet.target_mac}, [
          request_ack: false,
          payload: %{"type" => "bolt_ack", "in_reply_to" => original_packet.payload["ts"]}
        ])

      _ ->
        :ok
    end
  end
end
