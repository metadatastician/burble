# SPDX-License-Identifier: MPL-2.0
#
# BurbleWeb.AssistChannel — live event stream for the Burble Assist API.
#
# LLM assistants and operators join "assist:events" to receive real-time
# state changes without polling REST endpoints. Events mirror changes in
# room health, peer connectivity, timing quality, bridge status, and Bolt.
#
# Capability required: any assist capability (checked on join).

defmodule BurbleWeb.AssistChannel do
  use Phoenix.Channel

  require Logger

  @topics [
    "room.health.changed",
    "room.sync.changed",
    "peer.connectivity.changed",
    "peer.path.changed",
    "peer.device.changed",
    "timing.quality.changed",
    "network.turn.changed",
    "bridge.status.changed",
    "bolt.received",
    "bolt.acked",
    "assist.action.completed",
    "assist.action.denied"
  ]

  @impl true
  def join("assist:events", _params, socket) do
    # Subscribe to all assist PubSub topics.
    for topic <- @topics do
      Burble.PubSub |> Phoenix.PubSub.subscribe("assist:#{topic}")
    end

    # Also subscribe to bolt notifications.
    Burble.Bolt.Notify.subscribe()

    Logger.info("[AssistChannel] client connected: #{inspect(socket.assigns[:user_id])}")
    {:ok, %{topics: @topics}, socket}
  end

  # Forward any PubSub message to the client as an assist event.
  @impl true
  def handle_info({:assist_event, topic, payload}, socket) do
    push(socket, "event", %{
      topic: topic,
      timestamp: DateTime.to_iso8601(DateTime.utc_now()),
      payload: payload
    })
    {:noreply, socket}
  end

  @impl true
  def handle_info({:bolt_incoming, notification}, socket) do
    push(socket, "event", %{
      topic: "bolt.received",
      timestamp: DateTime.to_iso8601(DateTime.utc_now()),
      payload: notification
    })
    {:noreply, socket}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @doc "Broadcast an assist event to all connected assist clients."
  def broadcast_event(topic, payload) when topic in @topics do
    Phoenix.PubSub.broadcast(Burble.PubSub, "assist:#{topic}", {:assist_event, topic, payload})
  end

  def topics, do: @topics
end
