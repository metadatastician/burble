# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Burble.Bridges.Matrix — Bidirectional bridge to Matrix/Element rooms.
#
# Connects to a Matrix homeserver and relays text messages and voice
# audio between Burble rooms and Matrix rooms.
#
# This is an INTEROP bridge, not a migration tool:
#   - Matrix users stay in Matrix/Element, Burble users stay in Burble
#   - They communicate through the bridge
#   - No Matrix features are replicated (reactions, threads, E2EE Megolm)
#   - Bridge must be explicitly enabled by server admin
#
# Protocol: Matrix uses a REST API (Client-Server API) over HTTPS:
#   - Events are the core primitive: room events, state events, presence
#   - Long-polling /sync endpoint for real-time updates
#   - Access token authentication (Bearer token)
#   - Voice via m.call.invite / m.call.answer events (WebRTC-based)
#   - Application Service mode for high-volume bridging
#
# Architecture:
#   Burble Room ↔ MatrixBridge GenServer ↔ Matrix Room
#                        │
#               Text: PubSub ↔ Matrix m.room.message events
#               Voice: WebRTC ↔ m.call.invite/answer events
#               Presence: member sync bidirectionally
#
# Matrix spec reference: https://spec.matrix.org/v1.10/client-server-api/

defmodule Burble.Bridges.Matrix do
  @moduledoc """
  Bidirectional text and voice bridge between Burble and Matrix/Element.

  Connects to a Matrix homeserver via the Client-Server API and relays
  messages and presence between a Burble room and a Matrix room.

  ## Starting a bridge

      {:ok, pid} = Matrix.start_link(
        room_id: "my_room",
        homeserver: "https://matrix.example.com",
        access_token: System.fetch_env!("MATRIX_ACCESS_TOKEN"),
        matrix_room_id: "!abc123:example.com"
      )

  ## How it works

  1. Bridge authenticates with the homeserver using an access token
  2. Joins the specified Matrix room
  3. Starts a /sync loop to receive real-time events
  4. Text: Burble messages → m.room.message events and vice versa
  5. Presence: Matrix members appear as phantom participants in Burble
  6. Voice: m.call.invite/answer events (WebRTC signalling)

  ## Modes

  ### Regular client mode (default)
  Bridge acts as a regular Matrix user. Simple setup, works with any
  homeserver. Limited to one bridge per bot account.

  ### Application Service mode
  For high-volume bridging. Requires registration with the homeserver
  admin. Can impersonate users (ghost users in Matrix for each Burble peer).

  ## Matrix protocol overview

  - REST API: /_matrix/client/v3/*
  - Events: m.room.message, m.room.member, m.presence, m.call.*
  - Sync: long-polling GET /_matrix/client/v3/sync?timeout=30000
  - Auth: ?access_token=TOKEN or Authorization: Bearer TOKEN
  - Room IDs: !opaque_id:homeserver.tld
  - Event IDs: $opaque_id

  ## Limitations

  - Matrix E2EE (Megolm) is not supported — rooms must be unencrypted
  - Matrix reactions, threads, and edits are not bridged
  - Voice bridging requires WebRTC support (experimental)
  - Application Service mode requires homeserver admin cooperation
  - Rate limits apply per Matrix homeserver configuration
  """

  use GenServer
  require Logger

  # Matrix Client-Server API version prefix.
  @api_prefix "/_matrix/client/v3"

  # Sync long-poll timeout in milliseconds.
  @sync_timeout_ms 30_000

  # Default sync filter: only text messages and membership events.
  @sync_filter %{
    "room" => %{
      "timeline" => %{
        "types" => [
          "m.room.message",
          "m.room.member",
          "m.call.invite",
          "m.call.answer",
          "m.call.candidates",
          "m.call.hangup"
        ],
        "limit" => 50
      },
      "state" => %{
        "types" => ["m.room.member"],
        "lazy_load_members" => true
      }
    },
    "presence" => %{
      "types" => ["m.presence"]
    }
  }

  # SECURITY FIX: Exponential backoff for sync retries instead of fixed delay.
  # Without backoff, a failing Matrix homeserver causes a tight retry loop that
  # wastes CPU, generates excessive log noise, and may trigger rate limiting
  # on the homeserver side — making recovery harder.
  @sync_min_backoff_ms 1_000
  @sync_max_backoff_ms 30_000

  # Legacy constant retained for initialization retry (non-sync).
  @sync_retry_ms 5_000

  # Maximum message body length to relay (prevent abuse).
  @max_message_length 4096

  @type bridge_config :: %{
          room_id: String.t(),
          homeserver: String.t(),
          access_token: String.t(),
          matrix_room_id: String.t(),
          as_token: String.t() | nil,
          display_name: String.t()
        }

  @type bridge_state :: %{
          config: bridge_config(),
          user_id: String.t() | nil,
          since_token: String.t() | nil,
          sync_ref: reference() | nil,
          matrix_members: map(),
          joined: boolean(),
          syncing: boolean()
        }

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc """
  Start a Matrix bridge for a Burble room.

  ## Required options

    * `:room_id` — The Burble room ID to bridge
    * `:homeserver` — Matrix homeserver URL (e.g. "https://matrix.org")
    * `:access_token` — Matrix access token for authentication
    * `:matrix_room_id` — Matrix room ID to join (e.g. "!abc:matrix.org")

  ## Optional

    * `:as_token` — Application Service token (for AS mode)
    * `:display_name` — Bot display name in Matrix (default "Burble Bridge")
  """
  def start_link(opts) do
    room_id = Keyword.fetch!(opts, :room_id)
    GenServer.start_link(__MODULE__, opts, name: via(room_id))
  end

  @doc "Get the list of Matrix members in the bridged room."
  @spec matrix_members(GenServer.name()) :: {:ok, [map()]}
  def matrix_members(bridge) do
    GenServer.call(bridge, :matrix_members)
  end

  @doc "Send a text message from Burble to the Matrix room."
  @spec send_text(GenServer.name(), String.t(), String.t()) :: :ok
  def send_text(bridge, sender_name, message) do
    GenServer.cast(bridge, {:send_text, sender_name, message})
  end

  @doc "Stop the bridge and leave the Matrix room."
  def stop(bridge) do
    GenServer.stop(bridge, :normal)
  end

  @doc "Get bridge status."
  @spec status(GenServer.name()) :: {:ok, map()}
  def status(bridge) do
    GenServer.call(bridge, :status)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    config = %{
      room_id: Keyword.fetch!(opts, :room_id),
      homeserver: Keyword.fetch!(opts, :homeserver) |> String.trim_trailing("/"),
      access_token: Keyword.fetch!(opts, :access_token),
      matrix_room_id: Keyword.fetch!(opts, :matrix_room_id),
      as_token: Keyword.get(opts, :as_token),
      display_name: Keyword.get(opts, :display_name, "Burble Bridge")
    }

    state = %{
      config: config,
      user_id: nil,
      since_token: nil,
      sync_ref: nil,
      matrix_members: %{},
      joined: false,
      syncing: false,
      # SECURITY FIX: Track current backoff delay for exponential backoff
      # on sync failures. Starts at @sync_min_backoff_ms, doubles on each
      # consecutive failure, capped at @sync_max_backoff_ms. Resets to
      # min on successful sync.
      sync_backoff_ms: @sync_min_backoff_ms
    }

    # Start async initialisation: whoami → set display name → join room → sync.
    send(self(), :initialize)

    Logger.info(
      "[MatrixBridge] Starting bridge: #{config.room_id} ↔ " <>
        "Matrix #{config.matrix_room_id} via #{config.homeserver}"
    )

    {:ok, state}
  end

  # -- Initialization --------------------------------------------------------

  @impl true
  def handle_info(:initialize, state) do
    with {:ok, user_id} <- whoami(state.config),
         :ok <- set_display_name(user_id, state.config.display_name, state.config),
         :ok <- join_room(state.config.matrix_room_id, state.config) do
      Logger.info("[MatrixBridge] Initialized as #{user_id}, joined #{state.config.matrix_room_id}")

      # Start the sync loop.
      send(self(), :sync)

      {:noreply, %{state | user_id: user_id, joined: true}}
    else
      {:error, reason} ->
        Logger.error("[MatrixBridge] Initialization failed: #{inspect(reason)}")
        Process.send_after(self(), :initialize, @sync_retry_ms)
        {:noreply, state}
    end
  end

  # -- Sync loop -------------------------------------------------------------

  @impl true
  def handle_info(:sync, %{syncing: false} = state) do
    # Spawn an async task for the long-poll /sync request.
    bridge_pid = self()
    config = state.config
    since = state.since_token

    Task.start(fn ->
      result = do_sync(config, since)
      send(bridge_pid, {:sync_result, result})
    end)

    {:noreply, %{state | syncing: true}}
  end

  @impl true
  def handle_info(:sync, state), do: {:noreply, state}

  @impl true
  def handle_info({:sync_result, {:ok, sync_data}}, state) do
    # Process sync response events.
    state = process_sync_response(sync_data, state)

    # Extract next_batch token for incremental sync.
    since_token = sync_data["next_batch"]

    # Schedule next sync immediately (long-poll provides the delay).
    # SECURITY FIX: Reset backoff to minimum on success — the homeserver
    # is responding normally, so no need for delay.
    send(self(), :sync)

    {:noreply, %{state | since_token: since_token, syncing: false, sync_backoff_ms: @sync_min_backoff_ms}}
  end

  @impl true
  def handle_info({:sync_result, {:error, reason}}, state) do
    # SECURITY FIX: Exponential backoff instead of fixed retry delay.
    # Without backoff, a failing homeserver causes a tight retry loop that
    # wastes CPU and may worsen the problem (e.g., by triggering rate limits).
    # Backoff doubles on each failure: 1s → 2s → 4s → 8s → 16s → 30s (cap).
    current_backoff = state.sync_backoff_ms
    next_backoff = min(current_backoff * 2, @sync_max_backoff_ms)

    Logger.warning(
      "[MatrixBridge] Sync failed: #{inspect(reason)}, retrying in #{current_backoff}ms"
    )
    Process.send_after(self(), :sync, current_backoff)
    {:noreply, %{state | syncing: false, sync_backoff_ms: next_backoff}}
  end

  # -- GenServer call handlers -----------------------------------------------

  @impl true
  def handle_call(:matrix_members, _from, state) do
    members = Map.values(state.matrix_members)
    {:reply, {:ok, members}, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      room_id: state.config.room_id,
      homeserver: state.config.homeserver,
      matrix_room_id: state.config.matrix_room_id,
      user_id: state.user_id,
      joined: state.joined,
      syncing: state.syncing,
      matrix_member_count: map_size(state.matrix_members),
      since_token: state.since_token
    }

    {:reply, {:ok, status}, state}
  end

  # -- GenServer cast handlers -----------------------------------------------

  @impl true
  def handle_cast({:send_text, sender_name, message}, %{joined: true} = state) do
    body = "[#{sender_name}] #{message}"
    truncated = String.slice(body, 0, @max_message_length)

    event_content = %{
      "msgtype" => "m.text",
      "body" => truncated
    }

    case send_room_event(state.config.matrix_room_id, "m.room.message", event_content, state.config) do
      {:ok, _event_id} ->
        :ok

      {:error, reason} ->
        Logger.warning("[MatrixBridge] Failed to send text: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:send_text, _, _}, state), do: {:noreply, state}

  # -- Terminate -------------------------------------------------------------

  @impl true
  def terminate(_reason, state) do
    # Leave the Matrix room gracefully.
    if state.joined do
      leave_room(state.config.matrix_room_id, state.config)
    end

    Logger.info("[MatrixBridge] Bridge stopped for room #{state.config.room_id}")
    :ok
  end

  # ---------------------------------------------------------------------------
  # Private: Sync processing
  # ---------------------------------------------------------------------------

  # Process the response from a /sync request.
  defp process_sync_response(sync_data, state) do
    rooms = get_in(sync_data, ["rooms", "join"]) || %{}

    # Process events for the room we're bridging.
    case Map.get(rooms, state.config.matrix_room_id) do
      nil ->
        state

      room_data ->
        state = process_timeline_events(room_data, state)
        state = process_state_events(room_data, state)
        state
    end
  end

  # Process timeline events (messages, calls) from a synced room.
  defp process_timeline_events(room_data, state) do
    events = get_in(room_data, ["timeline", "events"]) || []

    Enum.reduce(events, state, fn event, acc ->
      handle_matrix_event(event, acc)
    end)
  end

  # Process state events (membership changes) from a synced room.
  defp process_state_events(room_data, state) do
    events = get_in(room_data, ["state", "events"]) || []

    Enum.reduce(events, state, fn event, acc ->
      handle_matrix_event(event, acc)
    end)
  end

  # ---------------------------------------------------------------------------
  # Private: Matrix event handling
  # ---------------------------------------------------------------------------

  # Handle m.room.message — relay text to Burble room.
  defp handle_matrix_event(
         %{"type" => "m.room.message", "sender" => sender, "content" => content},
         state
       ) do
    # Skip messages from ourselves to avoid loops.
    if sender != state.user_id do
      body = content["body"] || ""
      msgtype = content["msgtype"] || "m.text"

      if msgtype == "m.text" and byte_size(body) > 0 do
        # Extract display name from our member tracking.
        display_name =
          case Map.get(state.matrix_members, sender) do
            %{display_name: name} when is_binary(name) -> name
            _ -> sender
          end

        Phoenix.PubSub.broadcast(
          Burble.PubSub,
          "room:#{state.config.room_id}",
          {:matrix_text, %{
            from: display_name,
            sender: sender,
            body: body,
            bridge: true
          }}
        )
      end
    end

    state
  end

  # Handle m.room.member — track membership changes.
  defp handle_matrix_event(
         %{"type" => "m.room.member", "state_key" => user_id, "content" => content},
         state
       ) do
    membership = content["membership"]
    display_name = content["displayname"]

    case membership do
      "join" ->
        member_info = %{
          user_id: user_id,
          display_name: display_name || user_id,
          membership: :joined
        }

        # Broadcast presence to Burble room.
        Phoenix.PubSub.broadcast(
          Burble.PubSub,
          "room:#{state.config.room_id}",
          {:matrix_presence, %{
            action: :join,
            user_id: user_id,
            display_name: display_name || user_id,
            bridge: true
          }}
        )

        %{state | matrix_members: Map.put(state.matrix_members, user_id, member_info)}

      leave when leave in ["leave", "ban"] ->
        Phoenix.PubSub.broadcast(
          Burble.PubSub,
          "room:#{state.config.room_id}",
          {:matrix_presence, %{
            action: :leave,
            user_id: user_id,
            bridge: true
          }}
        )

        %{state | matrix_members: Map.delete(state.matrix_members, user_id)}

      _ ->
        state
    end
  end

  # Handle m.call.invite — incoming voice call from Matrix.
  defp handle_matrix_event(
         %{"type" => "m.call.invite", "sender" => sender, "content" => content},
         state
       ) do
    call_id = content["call_id"]
    _offer = content["offer"]

    Logger.info("[MatrixBridge] Incoming call from #{sender}, call_id: #{call_id}")

    # Broadcast the call invite to the Burble room so a client can answer.
    Phoenix.PubSub.broadcast(
      Burble.PubSub,
      "room:#{state.config.room_id}",
      {:matrix_call, %{
        action: :invite,
        sender: sender,
        call_id: call_id,
        offer: content["offer"],
        bridge: true
      }}
    )

    state
  end

  # Handle m.call.answer — remote accepted our call.
  defp handle_matrix_event(
         %{"type" => "m.call.answer", "sender" => sender, "content" => content},
         state
       ) do
    call_id = content["call_id"]

    Logger.info("[MatrixBridge] Call answered by #{sender}, call_id: #{call_id}")

    Phoenix.PubSub.broadcast(
      Burble.PubSub,
      "room:#{state.config.room_id}",
      {:matrix_call, %{
        action: :answer,
        sender: sender,
        call_id: call_id,
        answer: content["answer"],
        bridge: true
      }}
    )

    state
  end

  # Handle m.call.candidates — ICE candidates for WebRTC.
  defp handle_matrix_event(
         %{"type" => "m.call.candidates", "sender" => sender, "content" => content},
         state
       ) do
    call_id = content["call_id"]
    candidates = content["candidates"] || []

    Phoenix.PubSub.broadcast(
      Burble.PubSub,
      "room:#{state.config.room_id}",
      {:matrix_call, %{
        action: :candidates,
        sender: sender,
        call_id: call_id,
        candidates: candidates,
        bridge: true
      }}
    )

    state
  end

  # Handle m.call.hangup — call ended.
  defp handle_matrix_event(
         %{"type" => "m.call.hangup", "content" => content},
         state
       ) do
    call_id = content["call_id"]

    Phoenix.PubSub.broadcast(
      Burble.PubSub,
      "room:#{state.config.room_id}",
      {:matrix_call, %{
        action: :hangup,
        call_id: call_id,
        bridge: true
      }}
    )

    state
  end

  # Catch-all for unhandled event types.
  defp handle_matrix_event(_event, state), do: state

  # ---------------------------------------------------------------------------
  # Private: Matrix Client-Server API calls
  # ---------------------------------------------------------------------------

  # GET /_matrix/client/v3/account/whoami — get the authenticated user ID.
  defp whoami(config) do
    case matrix_request(:get, "#{config.homeserver}#{@api_prefix}/account/whoami", config) do
      {:ok, %{"user_id" => user_id}} ->
        {:ok, user_id}

      {:ok, body} ->
        {:error, {:unexpected_response, body}}

      error ->
        error
    end
  end

  # PUT /_matrix/client/v3/profile/{userId}/displayname
  defp set_display_name(user_id, display_name, config) do
    encoded_user = URI.encode(user_id)
    url = "#{config.homeserver}#{@api_prefix}/profile/#{encoded_user}/displayname"
    body = %{"displayname" => display_name}

    case matrix_request(:put, url, config, body) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:set_display_name_failed, reason}}
    end
  end

  # POST /_matrix/client/v3/join/{roomIdOrAlias} — join a room.
  defp join_room(room_id, config) do
    encoded_room = URI.encode(room_id)
    url = "#{config.homeserver}#{@api_prefix}/join/#{encoded_room}"

    case matrix_request(:post, url, config, %{}) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:join_failed, reason}}
    end
  end

  # POST /_matrix/client/v3/rooms/{roomId}/leave — leave a room.
  defp leave_room(room_id, config) do
    encoded_room = URI.encode(room_id)
    url = "#{config.homeserver}#{@api_prefix}/rooms/#{encoded_room}/leave"

    case matrix_request(:post, url, config, %{}) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:leave_failed, reason}}
    end
  end

  # PUT /_matrix/client/v3/rooms/{roomId}/send/{eventType}/{txnId} — send event.
  defp send_room_event(room_id, event_type, content, config) do
    encoded_room = URI.encode(room_id)
    txn_id = generate_txn_id()
    url = "#{config.homeserver}#{@api_prefix}/rooms/#{encoded_room}/send/#{event_type}/#{txn_id}"

    case matrix_request(:put, url, config, content) do
      {:ok, %{"event_id" => event_id}} ->
        {:ok, event_id}

      {:ok, body} ->
        {:error, {:unexpected_response, body}}

      error ->
        error
    end
  end

  # Perform the /sync long-poll request.
  defp do_sync(config, since_token) do
    params =
      %{
        "timeout" => @sync_timeout_ms,
        "filter" => Jason.encode!(@sync_filter)
      }
      |> then(fn p ->
        if since_token, do: Map.put(p, "since", since_token), else: p
      end)

    query = URI.encode_query(params)
    url = "#{config.homeserver}#{@api_prefix}/sync?#{query}"

    # Use a longer HTTP timeout than the sync timeout.
    matrix_request(:get, url, config, nil, @sync_timeout_ms + 10_000)
  end

  # ---------------------------------------------------------------------------
  # Private: HTTP client (using Erlang :httpc)
  # ---------------------------------------------------------------------------

  # Make an authenticated HTTP request to the Matrix homeserver.
  defp matrix_request(method, url, config, body \\ nil, timeout \\ 30_000) do
    headers = [
      {~c"Authorization", String.to_charlist("Bearer #{config.access_token}")},
      {~c"User-Agent", ~c"Burble Bridge/1.0"}
    ]

    request =
      case {method, body} do
        {:get, _} ->
          {String.to_charlist(url), headers}

        {_, nil} ->
          {String.to_charlist(url), headers}

        {_, body_map} ->
          json_body = Jason.encode!(body_map)

          {
            String.to_charlist(url),
            headers ++ [{~c"Content-Type", ~c"application/json"}],
            ~c"application/json",
            json_body
          }
      end

    http_method =
      case method do
        :get -> :get
        :post -> :post
        :put -> :put
        :delete -> :delete
      end

    case :httpc.request(http_method, request, [{:timeout, timeout}], []) do
      {:ok, {{_, status, _}, _resp_headers, resp_body}} when status >= 200 and status < 300 ->
        case Jason.decode(List.to_string(resp_body)) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _} -> {:ok, %{}}
        end

      {:ok, {{_, status, reason}, _resp_headers, resp_body}} ->
        Logger.warning(
          "[MatrixBridge] HTTP #{status} #{reason}: #{String.slice(List.to_string(resp_body), 0, 200)}"
        )

        {:error, {:http_error, status, List.to_string(reason)}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  rescue
    error -> {:error, {:exception, error}}
  end

  # ---------------------------------------------------------------------------
  # Private: Utility functions
  # ---------------------------------------------------------------------------

  # Registry via() name for process lookup.
  defp via(room_id) do
    {:via, Registry, {Burble.RoomRegistry, {:matrix_bridge, room_id}}}
  end

  # Generate a unique transaction ID for Matrix event sending.
  defp generate_txn_id do
    "burble_#{System.system_time(:microsecond)}_#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}"
  end
end
