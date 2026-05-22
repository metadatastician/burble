# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Burble.Bridges.Discord — Bidirectional bridge to Discord voice channels.
#
# Connects to Discord as a bot client and relays audio bidirectionally
# between Burble rooms and Discord voice channels.
#
# This is an INTEROP bridge, not a migration tool:
#   - Discord users stay in Discord, Burble users stay in Burble
#   - They hear each other through the bridge
#   - No Discord features are replicated (roles, permissions, reactions)
#   - Bridge must be explicitly enabled by bot token holder
#
# Protocol: Discord uses two WebSocket connections and a UDP socket:
#   1. Gateway WebSocket — events (identify, voice_state_update, presence)
#   2. Voice Gateway WebSocket — voice session (identify, select_protocol, speaking)
#   3. Voice UDP — RTP with Opus frames, encrypted with aead_xchacha20_poly1305_rtpsize
#
# Architecture:
#   Burble Room ↔ DiscordBridge GenServer ↔ Discord Voice Channel
#                        │
#               Audio frames relayed
#               bidirectionally (Opus native on both sides)
#
# The bridge appears as a bot user in Discord, and Discord participants
# appear as "phantom participants" in the Burble room.
#
# Discord API reference: https://discord.com/developers/docs

defmodule Burble.Bridges.Discord do
  @moduledoc """
  Bidirectional voice and text bridge between Burble and Discord.

  Connects to Discord as a bot user and relays audio between a Burble
  room and a Discord voice channel. Both communities hear each other
  without leaving their platform. Text messages are also bridged
  bidirectionally between a Burble room and a Discord text channel.

  ## Starting a bridge

      {:ok, pid} = Discord.start_link(
        room_id: "my_room",
        bot_token: "Bot XXXXXXXXX",
        guild_id: "123456789",
        voice_channel_id: "987654321",
        text_channel_id: "111222333"
      )

  ## How it works

  1. Bridge connects to Discord Gateway via WebSocket
  2. Identifies as a bot, receives READY event with session info
  3. Sends voice_state_update to join the voice channel
  4. Receives VOICE_SERVER_UPDATE with voice endpoint + token
  5. Connects to Voice Gateway WebSocket, identifies, selects protocol
  6. Opens UDP socket for RTP/Opus audio (aead_xchacha20_poly1305_rtpsize encrypted)
  7. Audio from Burble → Opus frames → RTP → encrypted → UDP to Discord
  8. Audio from Discord → UDP → decrypt → RTP → Opus frames → Burble room
  9. Discord users appear as phantom participants in Burble
  10. Text messages relay via Discord REST API and Gateway events

  ## Discord protocol overview

  - Gateway: wss://gateway.discord.gg/?v=10&encoding=json
  - Auth: "Bot TOKEN" in Authorization header
  - Heartbeat: sent every heartbeat_interval ms (from HELLO event)
  - Voice Gateway: wss://{endpoint}/?v=4
  - Voice UDP: RTP header + aead_xchacha20_poly1305_rtpsize encrypted Opus
  - Text: POST /channels/{id}/messages for outbound, MESSAGE_CREATE event for inbound

  ## Cipher policy

  This bridge requires `aead_xchacha20_poly1305_rtpsize` mode, implemented via
  `:crypto.crypto_one_time_aead(:xchacha20_poly1305, ...)` from OTP `:crypto`.
  The older `xsalsa20_poly1305` mode (NaCl secretbox) is NOT supported because
  OTP `:crypto` does not provide it and adding `:enacl` is a Phase 2 decision.
  If Discord's Voice READY payload does not include `aead_xchacha20_poly1305_rtpsize`
  in its `modes` list, the bridge refuses to start the session and logs an error.

  The startup probe in `init/1` verifies that `:crypto.crypto_one_time_aead/6`
  works for `:xchacha20_poly1305` before the bridge accepts any connections.
  If the probe fails, the bridge returns `{:stop, :cipher_unavailable}`.

  Under no circumstances does this bridge transmit a plaintext Opus frame as if
  it were encrypted. On cipher failure the bridge process crashes — the supervisor
  restart is the correct response.

  ## Limitations

  - Bridge appears as a single bot user in Discord
  - Discord permissions (roles) are not enforced in Burble
  - Discord-specific features (reactions, threads, embeds) are not bridged
  - Requires a Discord bot token with voice + message intents
  - Requires `aead_xchacha20_poly1305_rtpsize` mode support from Discord
  """

  use GenServer
  require Logger

  # Module atom for the optional :gun HTTP/WebSocket client — referenced
  # via apply/3 to avoid compile-time warnings when :gun is not installed.
  @gun :gun

  # Discord Gateway API version and encoding.
  @gateway_url "wss://gateway.discord.gg/?v=10&encoding=json"
  @api_base "https://discord.com/api/v10"

  # Discord Gateway opcodes.
  @op_dispatch 0
  @op_heartbeat 1
  @op_identify 2
  @op_resume 6
  @op_reconnect 7
  @op_invalid_session 9
  @op_hello 10
  @op_heartbeat_ack 11

  # Discord Voice Gateway opcodes.
  @voice_op_identify 0
  @voice_op_select_protocol 1
  @voice_op_ready 2
  @voice_op_heartbeat 3
  @voice_op_session_description 4
  @voice_op_speaking 5
  @voice_op_heartbeat_ack 6
  # @voice_op_resume 7  # Reserved — used during voice session resumption.
  @voice_op_hello 8
  @voice_op_resumed 9

  # Gateway intents: GUILDS | GUILD_VOICE_STATES | GUILD_MESSAGES | MESSAGE_CONTENT.
  # Bitfield: (1 << 0) | (1 << 7) | (1 << 9) | (1 << 15)
  @gateway_intents 0x8281

  # RTP header size (12 bytes): version(2), payload_type(1), sequence(2),
  # timestamp(4), ssrc(4).
  @rtp_header_size 12

  # Audio timing: 48kHz, 20ms frames = 960 samples per frame.
  @samples_per_frame 960
  # @frame_duration_ms 20  # Reserved — 20ms per Opus frame at 48kHz.

  # Reconnection delay in milliseconds.
  @reconnect_delay_ms 5_000

  # Silence frame: 5 bytes of Opus silence (required by Discord when not speaking).
  # @opus_silence <<0xF8, 0xFF, 0xFE>>  # Reserved — sent when not speaking.

  @type bridge_config :: %{
          room_id: String.t(),
          bot_token: String.t(),
          guild_id: String.t(),
          voice_channel_id: String.t(),
          text_channel_id: String.t() | nil
        }

  @type bridge_state :: %{
          config: bridge_config(),
          gateway_ws: pid() | nil,
          voice_ws: pid() | nil,
          voice_udp: port() | nil,
          session_id: String.t() | nil,
          voice_token: String.t() | nil,
          voice_endpoint: String.t() | nil,
          voice_ssrc: non_neg_integer() | nil,
          voice_secret_key: binary() | nil,
          voice_ip: String.t() | nil,
          voice_port: non_neg_integer() | nil,
          heartbeat_interval: non_neg_integer() | nil,
          heartbeat_ref: reference() | nil,
          voice_heartbeat_ref: reference() | nil,
          last_sequence: integer() | nil,
          rtp_sequence: non_neg_integer(),
          rtp_timestamp: non_neg_integer(),
          discord_users: map(),
          connected: boolean(),
          voice_connected: boolean(),
          speaking: boolean()
        }

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc """
  Start a Discord bridge for a Burble room.

  ## Required options

    * `:room_id` — The Burble room ID to bridge
    * `:bot_token` — Discord bot token (without "Bot " prefix)
    * `:guild_id` — Discord guild (server) ID
    * `:voice_channel_id` — Discord voice channel ID to join

  ## Optional

    * `:text_channel_id` — Discord text channel for message bridging (nil to skip)
  """
  def start_link(opts) do
    room_id = Keyword.fetch!(opts, :room_id)
    GenServer.start_link(__MODULE__, opts, name: via(room_id))
  end

  @doc "Get the list of Discord users currently in the bridged voice channel."
  @spec discord_users(GenServer.name()) :: {:ok, [map()]}
  def discord_users(bridge) do
    GenServer.call(bridge, :discord_users)
  end

  @doc "Send a text message from Burble to the Discord text channel."
  @spec send_text(GenServer.name(), String.t(), String.t()) :: :ok
  def send_text(bridge, sender_name, message) do
    GenServer.cast(bridge, {:send_text, sender_name, message})
  end

  @doc "Relay an Opus audio frame from a Burble peer to Discord voice."
  @spec relay_to_discord(GenServer.name(), binary()) :: :ok
  def relay_to_discord(bridge, opus_frame) do
    GenServer.cast(bridge, {:relay_to_discord, opus_frame})
  end

  @doc "Stop the bridge and disconnect from Discord."
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
    # Startup probe: verify the xchacha20_poly1305 cipher is available in this
    # OTP installation before accepting any connections.  If :crypto raises, the
    # bridge refuses to start — sending plaintext as if it were encrypted is not
    # an acceptable fallback.
    probe_key   = :crypto.strong_rand_bytes(32)
    probe_nonce = :crypto.strong_rand_bytes(24)
    probe_plain = <<"burble-cipher-probe">>

    probe_result =
      try do
        {_ct, _tag} = :crypto.crypto_one_time_aead(
          :xchacha20_poly1305,
          probe_key,
          probe_nonce,
          probe_plain,
          <<>>,
          true
        )
        :ok
      rescue
        exn ->
          Logger.error(
            "[DiscordBridge] Startup cipher probe failed — " <>
              ":xchacha20_poly1305 unavailable in this OTP build: #{inspect(exn)}"
          )
          {:error, :cipher_unavailable}
      end

    case probe_result do
      {:error, :cipher_unavailable} ->
        {:stop, :cipher_unavailable}

      :ok ->
        config = %{
          room_id: Keyword.fetch!(opts, :room_id),
          bot_token: Keyword.fetch!(opts, :bot_token),
          guild_id: Keyword.fetch!(opts, :guild_id),
          voice_channel_id: Keyword.fetch!(opts, :voice_channel_id),
          text_channel_id: Keyword.get(opts, :text_channel_id)
        }

        state = %{
          config: config,
          gateway_ws: nil,
          voice_ws: nil,
          voice_udp: nil,
          session_id: nil,
          voice_token: nil,
          voice_endpoint: nil,
          voice_ssrc: nil,
          voice_secret_key: nil,
          voice_ip: nil,
          voice_port: nil,
          heartbeat_interval: nil,
          heartbeat_ref: nil,
          voice_heartbeat_ref: nil,
          last_sequence: nil,
          rtp_sequence: 0,
          rtp_timestamp: 0,
          discord_users: %{},
          connected: false,
          voice_connected: false,
          speaking: false
        }

        # Connect asynchronously to avoid blocking the supervisor.
        send(self(), :connect_gateway)

        Logger.info(
          "[DiscordBridge] Starting bridge: #{config.room_id} ↔ " <>
            "Discord guild=#{config.guild_id} voice=#{config.voice_channel_id}"
        )

        {:ok, state}
    end
  end

  # -- Gateway connection lifecycle ------------------------------------------

  @impl true
  def handle_info(:connect_gateway, state) do
    case connect_websocket(@gateway_url) do
      {:ok, ws_pid} ->
        Logger.info("[DiscordBridge] Gateway WebSocket connected")
        {:noreply, %{state | gateway_ws: ws_pid, connected: true}}

      {:error, reason} ->
        Logger.error("[DiscordBridge] Gateway connection failed: #{inspect(reason)}")
        Process.send_after(self(), :connect_gateway, @reconnect_delay_ms)
        {:noreply, state}
    end
  end

  # -- Gateway heartbeat -----------------------------------------------------

  @impl true
  def handle_info(:gateway_heartbeat, %{gateway_ws: ws} = state) when not is_nil(ws) do
    # Send heartbeat with last received sequence number.
    payload = Jason.encode!(%{"op" => @op_heartbeat, "d" => state.last_sequence})
    send_ws(ws, payload)
    ref = Process.send_after(self(), :gateway_heartbeat, state.heartbeat_interval)
    {:noreply, %{state | heartbeat_ref: ref}}
  end

  @impl true
  def handle_info(:gateway_heartbeat, state), do: {:noreply, state}

  # -- Voice Gateway heartbeat -----------------------------------------------

  @impl true
  def handle_info(:voice_heartbeat, %{voice_ws: ws} = state) when not is_nil(ws) do
    nonce = System.system_time(:millisecond)
    payload = Jason.encode!(%{"op" => @voice_op_heartbeat, "d" => nonce})
    send_ws(ws, payload)
    # Voice heartbeat interval is typically ~13.75 seconds.
    ref = Process.send_after(self(), :voice_heartbeat, 13_750)
    {:noreply, %{state | voice_heartbeat_ref: ref}}
  end

  @impl true
  def handle_info(:voice_heartbeat, state), do: {:noreply, state}

  # -- Gateway WebSocket messages --------------------------------------------

  @impl true
  def handle_info({:ws_message, :gateway, text}, state) do
    case Jason.decode(text) do
      {:ok, payload} ->
        state = handle_gateway_payload(payload, state)
        {:noreply, state}

      {:error, _} ->
        Logger.warning("[DiscordBridge] Failed to decode Gateway message")
        {:noreply, state}
    end
  end

  # -- Voice Gateway WebSocket messages --------------------------------------

  @impl true
  def handle_info({:ws_message, :voice, text}, state) do
    case Jason.decode(text) do
      {:ok, payload} ->
        state = handle_voice_gateway_payload(payload, state)
        {:noreply, state}

      {:error, _} ->
        Logger.warning("[DiscordBridge] Failed to decode Voice Gateway message")
        {:noreply, state}
    end
  end

  # -- Voice UDP incoming audio ----------------------------------------------

  @impl true
  def handle_info({:udp, _socket, _ip, _port, packet}, state) do
    state = handle_voice_udp_packet(packet, state)
    {:noreply, state}
  end

  # -- WebSocket disconnection -----------------------------------------------

  @impl true
  def handle_info({:ws_closed, :gateway, reason}, state) do
    Logger.warning("[DiscordBridge] Gateway disconnected: #{inspect(reason)}, reconnecting...")
    cancel_timer(state.heartbeat_ref)
    Process.send_after(self(), :connect_gateway, @reconnect_delay_ms)
    {:noreply, %{state | gateway_ws: nil, connected: false, heartbeat_ref: nil}}
  end

  @impl true
  def handle_info({:ws_closed, :voice, reason}, state) do
    Logger.warning("[DiscordBridge] Voice Gateway disconnected: #{inspect(reason)}")
    cancel_timer(state.voice_heartbeat_ref)

    {:noreply,
     %{state | voice_ws: nil, voice_connected: false, voice_heartbeat_ref: nil, speaking: false}}
  end

  # -- GenServer call handlers -----------------------------------------------

  @impl true
  def handle_call(:discord_users, _from, state) do
    users = Map.values(state.discord_users)
    {:reply, {:ok, users}, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      room_id: state.config.room_id,
      guild_id: state.config.guild_id,
      voice_channel_id: state.config.voice_channel_id,
      text_channel_id: state.config.text_channel_id,
      connected: state.connected,
      voice_connected: state.voice_connected,
      speaking: state.speaking,
      discord_user_count: map_size(state.discord_users),
      rtp_sequence: state.rtp_sequence
    }

    {:reply, {:ok, status}, state}
  end

  # -- GenServer cast handlers -----------------------------------------------

  @impl true
  def handle_cast({:send_text, sender_name, message}, state) do
    if state.config.text_channel_id do
      text = "[#{sender_name}] #{message}"
      send_discord_message(state.config.text_channel_id, text, state.config.bot_token)
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:relay_to_discord, opus_frame}, state) do
    state = send_voice_frame(opus_frame, state)
    {:noreply, state}
  end

  # -- Terminate -------------------------------------------------------------

  @impl true
  def terminate(_reason, state) do
    # Send voice disconnect if connected.
    if state.gateway_ws do
      # Send voice_state_update with channel_id: null to disconnect from voice.
      disconnect_payload =
        Jason.encode!(%{
          "op" => @op_dispatch,
          "d" => %{
            "guild_id" => state.config.guild_id,
            "channel_id" => nil,
            "self_mute" => false,
            "self_deaf" => false
          }
        })

      send_ws(state.gateway_ws, disconnect_payload)
    end

    if state.voice_udp, do: :gen_udp.close(state.voice_udp)
    cancel_timer(state.heartbeat_ref)
    cancel_timer(state.voice_heartbeat_ref)

    Logger.info("[DiscordBridge] Bridge stopped for room #{state.config.room_id}")
    :ok
  end

  # ---------------------------------------------------------------------------
  # Private: Gateway protocol handling
  # ---------------------------------------------------------------------------

  # Process a Discord Gateway payload by opcode.
  defp handle_gateway_payload(%{"op" => @op_hello, "d" => data}, state) do
    # HELLO — start heartbeating and send IDENTIFY.
    heartbeat_interval = data["heartbeat_interval"]
    Logger.info("[DiscordBridge] Gateway HELLO, heartbeat interval: #{heartbeat_interval}ms")

    # Send first heartbeat immediately, then schedule periodic.
    ref = Process.send_after(self(), :gateway_heartbeat, heartbeat_interval)

    # Send IDENTIFY with bot token and intents.
    identify =
      Jason.encode!(%{
        "op" => @op_identify,
        "d" => %{
          "token" => state.config.bot_token,
          "intents" => @gateway_intents,
          "properties" => %{
            "os" => "linux",
            "browser" => "burble",
            "device" => "burble"
          }
        }
      })

    send_ws(state.gateway_ws, identify)

    %{state | heartbeat_interval: heartbeat_interval, heartbeat_ref: ref}
  end

  defp handle_gateway_payload(%{"op" => @op_heartbeat_ack}, state) do
    # Heartbeat acknowledged — connection is healthy.
    state
  end

  defp handle_gateway_payload(%{"op" => @op_dispatch, "t" => event_type, "d" => data, "s" => seq}, state) do
    # Dispatch event — update sequence number and route by event type.
    state = %{state | last_sequence: seq}
    handle_gateway_event(event_type, data, state)
  end

  defp handle_gateway_payload(%{"op" => @op_reconnect}, state) do
    # Discord is asking us to reconnect.
    Logger.info("[DiscordBridge] Gateway requested reconnect")
    send(self(), {:ws_closed, :gateway, :reconnect_requested})
    state
  end

  defp handle_gateway_payload(%{"op" => @op_invalid_session, "d" => resumable}, state) do
    # Invalid session — if resumable, try to resume; otherwise re-identify.
    if resumable do
      Logger.info("[DiscordBridge] Invalid session (resumable), attempting resume")
      send_resume(state)
    else
      Logger.info("[DiscordBridge] Invalid session (not resumable), re-identifying")
      # Wait a bit then reconnect cleanly.
      Process.send_after(self(), {:ws_closed, :gateway, :invalid_session}, 1_000)
    end

    state
  end

  defp handle_gateway_payload(_payload, state), do: state

  # ---------------------------------------------------------------------------
  # Private: Gateway event dispatch
  # ---------------------------------------------------------------------------

  # READY — we are authenticated, store session_id.
  defp handle_gateway_event("READY", %{"session_id" => sid} = _data, state) do
    Logger.info("[DiscordBridge] Gateway READY, session: #{sid}")

    # Now join the voice channel by sending voice_state_update.
    join_voice_payload =
      Jason.encode!(%{
        "op" => 4,
        "d" => %{
          "guild_id" => state.config.guild_id,
          "channel_id" => state.config.voice_channel_id,
          "self_mute" => false,
          "self_deaf" => false
        }
      })

    send_ws(state.gateway_ws, join_voice_payload)

    %{state | session_id: sid}
  end

  # VOICE_STATE_UPDATE — track who is in the voice channel.
  defp handle_gateway_event("VOICE_STATE_UPDATE", data, state) do
    user_id = get_in(data, ["member", "user", "id"]) || data["user_id"]
    channel_id = data["channel_id"]
    username = get_in(data, ["member", "user", "username"]) || "Unknown"

    if channel_id == state.config.voice_channel_id and user_id do
      # User joined or is in our voice channel — register as phantom participant.
      user_info = %{
        user_id: user_id,
        username: username,
        channel_id: channel_id,
        self_mute: data["self_mute"] || false,
        self_deaf: data["self_deaf"] || false
      }

      Logger.debug("[DiscordBridge] Voice state update: #{username} (#{user_id})")

      discord_users = Map.put(state.discord_users, user_id, user_info)

      # Broadcast presence to Burble room.
      Phoenix.PubSub.broadcast(
        Burble.PubSub,
        "room:#{state.config.room_id}",
        {:discord_presence, %{
          action: :join,
          user_id: user_id,
          username: username,
          bridge: true
        }}
      )

      %{state | discord_users: discord_users}
    else
      # User left our voice channel — remove phantom participant.
      if Map.has_key?(state.discord_users, user_id) do
        Phoenix.PubSub.broadcast(
          Burble.PubSub,
          "room:#{state.config.room_id}",
          {:discord_presence, %{
            action: :leave,
            user_id: user_id,
            username: username,
            bridge: true
          }}
        )
      end

      %{state | discord_users: Map.delete(state.discord_users, user_id)}
    end
  end

  # VOICE_SERVER_UPDATE — we have the voice endpoint, connect to Voice Gateway.
  defp handle_gateway_event("VOICE_SERVER_UPDATE", data, state) do
    voice_token = data["token"]
    voice_endpoint = data["endpoint"]

    Logger.info("[DiscordBridge] Voice server update: endpoint=#{voice_endpoint}")

    # Connect to the Voice Gateway WebSocket.
    voice_ws_url = "wss://#{voice_endpoint}/?v=4"

    state = %{state | voice_token: voice_token, voice_endpoint: voice_endpoint}

    case connect_websocket(voice_ws_url, :voice) do
      {:ok, ws_pid} ->
        Logger.info("[DiscordBridge] Voice Gateway connected")
        %{state | voice_ws: ws_pid}

      {:error, reason} ->
        Logger.error("[DiscordBridge] Voice Gateway connection failed: #{inspect(reason)}")
        state
    end
  end

  # MESSAGE_CREATE — text message from Discord, relay to Burble room.
  defp handle_gateway_event("MESSAGE_CREATE", data, state) do
    channel_id = data["channel_id"]
    author = data["author"]
    content = data["content"]

    # Only relay messages from the configured text channel, and not from bots.
    if channel_id == state.config.text_channel_id and
         author != nil and
         not (author["bot"] || false) and
         content != nil do
      username = author["username"] || "Unknown"

      Phoenix.PubSub.broadcast(
        Burble.PubSub,
        "room:#{state.config.room_id}",
        {:discord_text, %{
          from: username,
          body: content,
          bridge: true
        }}
      )
    end

    state
  end

  # Catch-all for unhandled Gateway events.
  defp handle_gateway_event(_event_type, _data, state), do: state

  # ---------------------------------------------------------------------------
  # Private: Voice Gateway protocol handling
  # ---------------------------------------------------------------------------

  # Voice HELLO — start voice heartbeat.
  defp handle_voice_gateway_payload(%{"op" => @voice_op_hello, "d" => data}, state) do
    heartbeat_interval = data["heartbeat_interval"] |> trunc()
    Logger.info("[DiscordBridge] Voice HELLO, heartbeat: #{heartbeat_interval}ms")

    # Start voice heartbeat.
    ref = Process.send_after(self(), :voice_heartbeat, heartbeat_interval)

    # Send voice IDENTIFY.
    voice_identify =
      Jason.encode!(%{
        "op" => @voice_op_identify,
        "d" => %{
          "server_id" => state.config.guild_id,
          "user_id" => state.session_id,
          "session_id" => state.session_id,
          "token" => state.voice_token
        }
      })

    send_ws(state.voice_ws, voice_identify)

    %{state | voice_heartbeat_ref: ref}
  end

  # The only cipher mode this bridge supports (requires OTP :crypto xchacha20_poly1305).
  @preferred_cipher_mode "aead_xchacha20_poly1305_rtpsize"

  # Voice READY — we have our SSRC, IP, and port. Perform IP discovery, then select protocol.
  defp handle_voice_gateway_payload(%{"op" => @voice_op_ready, "d" => data}, state) do
    ssrc = data["ssrc"]
    voice_ip = data["ip"]
    voice_port = data["port"]
    modes = data["modes"] || []

    Logger.info(
      "[DiscordBridge] Voice READY: ssrc=#{ssrc} ip=#{voice_ip} port=#{voice_port} " <>
        "offered_modes=#{inspect(modes)}"
    )

    if @preferred_cipher_mode not in modes do
      # Refuse to connect — the server does not offer our required cipher mode.
      # Transmitting with the wrong cipher (or no cipher) is not acceptable.
      # Return state unchanged without opening a UDP socket; the voice session
      # will time out naturally and the voice gateway disconnect handler will
      # trigger a reconnect attempt.
      Logger.error(
        "[DiscordBridge] Voice READY does not include required cipher mode " <>
          "#{@preferred_cipher_mode} (offered: #{inspect(modes)}). " <>
          "Refusing voice session."
      )

      state
    else
      # Open UDP socket for voice.
      {:ok, udp_socket} = :gen_udp.open(0, [:binary, active: true])

      # Perform IP discovery: send a 74-byte packet with our SSRC.
      # Discord responds with our external IP and port.
      ip_discovery_packet = <<
        0x0001::16-big,
        70::16-big,
        ssrc::32-big,
        0::512
      >>

      :gen_udp.send(
        udp_socket,
        String.to_charlist(voice_ip),
        voice_port,
        ip_discovery_packet
      )

      # After IP discovery response (handled in UDP handler), we send select_protocol.
      # For now, store the info and let the UDP handler complete the handshake.
      %{
        state
        | voice_udp: udp_socket,
          voice_ssrc: ssrc,
          voice_ip: voice_ip,
          voice_port: voice_port
      }
    end
  end

  # Voice SESSION_DESCRIPTION — we have the secret key for encryption.
  defp handle_voice_gateway_payload(%{"op" => @voice_op_session_description, "d" => data}, state) do
    secret_key = data["secret_key"] |> :erlang.list_to_binary()
    mode = data["mode"]

    Logger.info("[DiscordBridge] Voice session established, mode: #{mode}")

    %{state | voice_secret_key: secret_key, voice_connected: true}
  end

  # Voice HEARTBEAT_ACK — connection is healthy.
  defp handle_voice_gateway_payload(%{"op" => @voice_op_heartbeat_ack}, state), do: state

  # Voice RESUMED — session was successfully resumed.
  defp handle_voice_gateway_payload(%{"op" => @voice_op_resumed}, state) do
    Logger.info("[DiscordBridge] Voice session resumed")
    state
  end

  # Voice SPEAKING — a user started or stopped speaking in Discord.
  defp handle_voice_gateway_payload(%{"op" => @voice_op_speaking, "d" => data}, state) do
    user_id = data["user_id"]
    _ssrc = data["ssrc"]
    speaking = data["speaking"]

    if user_id do
      Phoenix.PubSub.broadcast(
        Burble.PubSub,
        "room:#{state.config.room_id}",
        {:discord_speaking, %{
          user_id: user_id,
          speaking: speaking != 0,
          bridge: true
        }}
      )
    end

    state
  end

  # Catch-all for unhandled Voice Gateway payloads.
  defp handle_voice_gateway_payload(_payload, state), do: state

  # ---------------------------------------------------------------------------
  # Private: Voice UDP handling (RTP + aead_xchacha20_poly1305_rtpsize)
  # ---------------------------------------------------------------------------

  # Handle incoming UDP packet from Discord Voice.
  defp handle_voice_udp_packet(packet, state) do
    cond do
      # IP discovery response: 74-byte packet starting with 0x0002.
      byte_size(packet) >= 74 and match?(<<0x00, 0x02, _::binary>>, packet) ->
        handle_ip_discovery_response(packet, state)

      # RTP audio packet: starts with RTP header (version 2, payload type 0x78).
      byte_size(packet) > @rtp_header_size ->
        handle_rtp_audio_packet(packet, state)

      true ->
        state
    end
  end

  # Handle IP discovery response — extract our external IP, then send select_protocol.
  defp handle_ip_discovery_response(packet, state) do
    <<_type::16, _length::16, _ssrc::32, ip_bytes::binary-size(64), port::16-big>> = packet

    # Extract null-terminated IP string.
    external_ip =
      ip_bytes
      |> :binary.bin_to_list()
      |> Enum.take_while(&(&1 != 0))
      |> List.to_string()

    Logger.info("[DiscordBridge] IP discovery: external=#{external_ip}:#{port}")

    # Now send select_protocol to the Voice Gateway with our external address.
    # We always negotiate aead_xchacha20_poly1305_rtpsize — the voice READY handler
    # already verified this mode is in the server's offered list.
    select_protocol =
      Jason.encode!(%{
        "op" => @voice_op_select_protocol,
        "d" => %{
          "protocol" => "udp",
          "data" => %{
            "address" => external_ip,
            "port" => port,
            "mode" => @preferred_cipher_mode
          }
        }
      })

    send_ws(state.voice_ws, select_protocol)

    state
  end

  # Handle an incoming RTP audio packet from a Discord user.
  # Decrypt, extract Opus frame, and relay to Burble room.
  defp handle_rtp_audio_packet(packet, %{voice_secret_key: secret_key} = state)
       when not is_nil(secret_key) do
    # RTP header: <<version:2, padding:1, extension:1, cc:4, marker:1, pt:7,
    #               sequence:16, timestamp:32, ssrc:32>>
    <<_flags::8, _pt::8, _seq::16-big, _ts::32-big, _ssrc::32-big,
      encrypted_audio::binary>> = packet

    # Build nonce from RTP header (first 12 bytes, padded to 24 bytes for xchacha20_poly1305).
    <<rtp_header::binary-size(@rtp_header_size), _::binary>> = packet
    nonce = rtp_header <> <<0::96>>

    # Decrypt the audio using xchacha20_poly1305 (aead_xchacha20_poly1305_rtpsize mode).
    case decrypt_xchacha20_poly1305(encrypted_audio, secret_key, nonce) do
      {:ok, opus_frame} ->
        # Relay the Opus frame to the Burble room via PubSub.
        Phoenix.PubSub.broadcast(
          Burble.PubSub,
          "room:#{state.config.room_id}",
          {:discord_audio, %{
            opus_frame: opus_frame,
            bridge: true
          }}
        )

        state

      {:error, _reason} ->
        # Decryption failed — could be a keep-alive or malformed packet.
        state
    end
  end

  defp handle_rtp_audio_packet(_packet, state), do: state

  # ---------------------------------------------------------------------------
  # Private: Sending voice frames to Discord
  # ---------------------------------------------------------------------------

  # Send an Opus frame to Discord Voice as an encrypted RTP packet.
  defp send_voice_frame(opus_frame, %{voice_connected: true, voice_secret_key: key} = state)
       when not is_nil(key) do
    # Set speaking flag if not already speaking.
    state =
      if not state.speaking do
        set_speaking(state, true)
      else
        state
      end

    # Build RTP header.
    rtp_header = <<
      0x80::8,
      0x78::8,
      state.rtp_sequence::16-big,
      state.rtp_timestamp::32-big,
      state.voice_ssrc::32-big
    >>

    # Build nonce (RTP header padded to 24 bytes).
    nonce = rtp_header <> <<0::96>>

    # Encrypt the Opus frame using xchacha20_poly1305 (aead_xchacha20_poly1305_rtpsize mode).
    # This call raises on cipher failure — the supervisor restart is the correct response.
    encrypted = encrypt_xchacha20_poly1305(opus_frame, key, nonce)

    # Send RTP header + encrypted audio over UDP.
    packet = rtp_header <> encrypted

    :gen_udp.send(
      state.voice_udp,
      String.to_charlist(state.voice_ip),
      state.voice_port,
      packet
    )

    # Advance RTP sequence and timestamp.
    # Sequence wraps at 65535 (16-bit unsigned), timestamp at 2^32.
    new_seq = rem(state.rtp_sequence + 1, 0x10000)
    new_ts = rem(state.rtp_timestamp + @samples_per_frame, 0x100000000)

    %{state | rtp_sequence: new_seq, rtp_timestamp: new_ts}
  end

  defp send_voice_frame(_opus_frame, state), do: state

  # Send a SPEAKING opcode to the Voice Gateway.
  defp set_speaking(state, speaking) do
    speaking_flag = if speaking, do: 1, else: 0

    payload =
      Jason.encode!(%{
        "op" => @voice_op_speaking,
        "d" => %{
          "speaking" => speaking_flag,
          "delay" => 0,
          "ssrc" => state.voice_ssrc
        }
      })

    send_ws(state.voice_ws, payload)

    %{state | speaking: speaking}
  end

  # ---------------------------------------------------------------------------
  # Private: Discord REST API (text message sending)
  # ---------------------------------------------------------------------------

  # Send a text message to a Discord channel via the REST API.
  defp send_discord_message(channel_id, content, bot_token) do
    url = "#{@api_base}/channels/#{channel_id}/messages"

    headers = [
      {"Authorization", "Bot #{bot_token}"},
      {"Content-Type", "application/json"},
      {"User-Agent", "Burble Bridge (https://github.com/hyperpolymath/burble, v1.0)"}
    ]

    body = Jason.encode!(%{"content" => content})

    # Use :httpc from Erlang for HTTP requests (no external deps).
    :httpc.request(
      :post,
      {String.to_charlist(url), Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end),
       ~c"application/json", body},
      [],
      []
    )
  rescue
    error ->
      Logger.error("[DiscordBridge] Failed to send text message: #{inspect(error)}")
  end

  # ---------------------------------------------------------------------------
  # Private: xchacha20_poly1305 encryption/decryption
  #
  # Discord voice uses "aead_xchacha20_poly1305_rtpsize" mode (introduced 2024).
  # OTP :crypto exposes this as :xchacha20_poly1305 via crypto_one_time_aead/6.
  #
  # Wire format:
  #   encrypt output  →  tag (16 bytes) <> ciphertext
  #   decrypt input   →  tag (16 bytes) <> ciphertext
  #
  # The nonce is always the 12-byte RTP header zero-padded to 24 bytes.
  # The key is the 32-byte secret_key from the SESSION_DESCRIPTION payload.
  #
  # SECURITY INVARIANT: encrypt_xchacha20_poly1305/3 MUST NEVER return a
  # plaintext frame.  On any cipher failure it raises, which crashes the
  # GenServer.  The supervisor restart is the correct response.  Sending
  # plaintext over the encrypted voice channel is an unacceptable
  # confidentiality failure and is explicitly prohibited.
  # ---------------------------------------------------------------------------

  # Encrypt an Opus frame using xchacha20_poly1305.
  # Raises on any cipher error — the caller must NOT rescue this.
  defp encrypt_xchacha20_poly1305(plaintext, key, nonce) do
    # OTP :crypto.crypto_one_time_aead/6 returns {ciphertext, tag}.
    # We prepend the 16-byte Poly1305 MAC so the wire format matches Discord.
    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :xchacha20_poly1305,
        key,
        nonce,
        plaintext,
        <<>>,
        true
      )

    tag <> ciphertext
  rescue
    exn ->
      raise "Discord bridge cipher unavailable: #{inspect(exn)} — " <>
              "refusing to send unencrypted voice frame"
  end

  # Decrypt an incoming RTP audio payload using xchacha20_poly1305.
  # Returns {:ok, plaintext} | {:error, reason}.
  # Decrypt failures are honest — a bad packet is dropped, not a crash.
  defp decrypt_xchacha20_poly1305(ciphertext, key, nonce) do
    # The first 16 bytes are the Poly1305 MAC, remainder is ciphertext.
    if byte_size(ciphertext) < 16 do
      {:error, :too_short}
    else
      <<tag::binary-size(16), encrypted::binary>> = ciphertext

      case :crypto.crypto_one_time_aead(
             :xchacha20_poly1305,
             key,
             nonce,
             encrypted,
             <<>>,
             tag,
             false
           ) do
        :error -> {:error, :decrypt_failed}
        plaintext -> {:ok, plaintext}
      end
    end
  rescue
    _exn ->
      Logger.warning("[DiscordBridge] xchacha20_poly1305 decrypt not available in this OTP build")
      {:error, :not_available}
  end

  # ---------------------------------------------------------------------------
  # Private: WebSocket connection helpers
  # ---------------------------------------------------------------------------

  # Connect to a WebSocket URL. Returns {:ok, pid} | {:error, reason}.
  # In production, this would use :gun or :mint_web_socket.
  # This implementation uses :gun for WebSocket transport.
  defp connect_websocket(url, label \\ :gateway) do
    uri = URI.parse(url)
    host = String.to_charlist(uri.host)
    port = uri.port || 443
    path = uri.path || "/"
    query = if uri.query, do: "?#{uri.query}", else: ""
    full_path = "#{path}#{query}"

    case apply(@gun, :open, [host, port, %{protocols: [:http], transport: :tls}]) do
      {:ok, conn_pid} ->
        case apply(@gun, :await_up, [conn_pid, 10_000]) do
          {:ok, _protocol} ->
            stream_ref = apply(@gun, :ws_upgrade, [conn_pid, String.to_charlist(full_path)])

            receive do
              {:gun_upgrade, ^conn_pid, ^stream_ref, [<<"websocket">>], _headers} ->
                # Spawn a reader process that forwards messages to us.
                bridge_pid = self()

                reader_pid =
                  spawn_link(fn ->
                    ws_reader_loop(conn_pid, stream_ref, bridge_pid, label)
                  end)

                {:ok, {conn_pid, stream_ref, reader_pid}}

              {:gun_response, ^conn_pid, ^stream_ref, _fin, status, _headers} ->
                apply(@gun, :close, [conn_pid])
                {:error, {:ws_upgrade_failed, status}}
            after
              10_000 ->
                apply(@gun, :close, [conn_pid])
                {:error, :ws_upgrade_timeout}
            end

          {:error, reason} ->
            apply(@gun, :close, [conn_pid])
            {:error, {:connection_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:gun_open_failed, reason}}
    end
  rescue
    error -> {:error, {:connect_exception, error}}
  end

  # WebSocket reader loop — forwards messages to the bridge GenServer.
  #
  # SECURITY FIX: Added receive timeout for dead connection detection.
  # Without a timeout, if the remote end dies silently (e.g., network
  # partition, remote server crash without TCP FIN), this process blocks
  # indefinitely in receive, leaking a process and its associated memory.
  # The 60-second timeout detects dead connections and notifies the bridge
  # GenServer to clean up and attempt reconnection.
  @ws_reader_timeout_ms 60_000

  defp ws_reader_loop(conn_pid, stream_ref, bridge_pid, label) do
    receive do
      {:gun_ws, ^conn_pid, ^stream_ref, {:text, text}} ->
        send(bridge_pid, {:ws_message, label, text})
        ws_reader_loop(conn_pid, stream_ref, bridge_pid, label)

      {:gun_ws, ^conn_pid, ^stream_ref, {:binary, data}} ->
        send(bridge_pid, {:ws_message, label, data})
        ws_reader_loop(conn_pid, stream_ref, bridge_pid, label)

      {:gun_ws, ^conn_pid, ^stream_ref, :close} ->
        send(bridge_pid, {:ws_closed, label, :normal})

      {:gun_down, ^conn_pid, _protocol, reason, _killed} ->
        send(bridge_pid, {:ws_closed, label, reason})

      {:send_ws, data} ->
        apply(@gun, :ws_send, [conn_pid, stream_ref, {:text, data}])
        ws_reader_loop(conn_pid, stream_ref, bridge_pid, label)
    after
      # SECURITY FIX: Timeout fires when no message arrives for 60 seconds.
      # Discord sends heartbeat ACKs every ~41.25s, so 60s without any
      # message strongly indicates a dead connection. Notify the bridge
      # GenServer so it can clean up and reconnect.
      @ws_reader_timeout_ms ->
        Logger.warning(
          "[DiscordBridge] WebSocket reader timeout for #{label} — " <>
          "no message in #{div(@ws_reader_timeout_ms, 1000)}s, assuming dead connection"
        )
        send(bridge_pid, {:ws_closed, label, :receive_timeout})
    end
  end

  # Send data to a WebSocket connection.
  defp send_ws({_conn, _ref, reader_pid}, data) when is_pid(reader_pid) do
    send(reader_pid, {:send_ws, data})
  end

  defp send_ws(nil, _data), do: :ok

  # Send a RESUME payload to the Gateway to restore a session.
  defp send_resume(state) do
    resume_payload =
      Jason.encode!(%{
        "op" => @op_resume,
        "d" => %{
          "token" => state.config.bot_token,
          "session_id" => state.session_id,
          "seq" => state.last_sequence
        }
      })

    send_ws(state.gateway_ws, resume_payload)
  end

  # ---------------------------------------------------------------------------
  # Private: Registry via() name
  # ---------------------------------------------------------------------------

  defp via(room_id) do
    {:via, Registry, {Burble.RoomRegistry, {:discord_bridge, room_id}}}
  end

  # ---------------------------------------------------------------------------
  # Private: Timer utility
  # ---------------------------------------------------------------------------

  # Cancel a timer reference if it exists.
  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)
end
