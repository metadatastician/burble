# SPDX-License-Identifier: MPL-2.0
#
# Burble.Bridges.Mumble — Bidirectional bridge to Mumble/Murmur servers.
#
# EXPERIMENTAL (ADR-0009): this module is not started by the supervision
# tree and has never been validated against a real Murmur server. It lives
# under experimental/ until both are true. Tests exercise lifecycle against
# a refused socket only.
#
# Connects to a Murmur server as a bot client and relays audio
# bidirectionally between Burble rooms and Mumble channels.
#
# This is an INTEROP bridge, not a migration tool:
#   - Mumble users stay in Mumble, Burble users stay in Burble
#   - They hear each other through the bridge
#   - No Mumble features are replicated (ACLs, channel tree, positional audio)
#   - Mumble server admin must explicitly enable the bridge
#
# Protocol: Mumble uses a TCP control channel (protobuf messages) and
# a UDP voice channel (Opus/CELT frames with custom header). Both are
# encrypted with TLS (TCP) and OCB-AES128 (UDP).
#
# Architecture:
#   Burble Room ↔ MumbleBridge GenServer ↔ Mumble Channel
#                        │
#               Audio frames relayed
#               bidirectionally
#
# The bridge appears as a "Burble Bridge" user in Mumble, and Mumble
# participants appear as "phantom participants" in the Burble room.
#
# Mumble protocol reference: https://mumble-protocol.readthedocs.io/

defmodule Burble.Bridges.Mumble do
  @moduledoc """
  EXPERIMENTAL — Bidirectional voice bridge between Burble and Mumble/Murmur.

  Not started by the supervision tree; never validated against a real
  Murmur server (ADR-0009). Start manually via `start_link/1` at your
  own risk.

  Connects to a Murmur server as a bot client and relays audio
  between a Burble room and a Mumble channel. Both communities
  hear each other without leaving their platform.

  ## Starting a bridge

      {:ok, pid} = Mumble.start_link(
        room_id: "my_room",
        mumble_host: "mumble.example.com",
        mumble_port: 64738,
        mumble_channel: "General",
        bot_name: "Burble Bridge"
      )

  ## How it works

  1. Bridge connects to Murmur as a regular Mumble client
  2. Joins the specified channel
  3. Audio from Burble room → encoded as Opus → sent to Mumble channel
  4. Audio from Mumble channel → decoded → sent to Burble room
  5. Presence is synced: Mumble users appear in Burble, Burble users
     appear as the bot's "linked" users in Mumble

  ## Mumble protocol overview

  - TCP control: TLS-encrypted protobuf messages (auth, channel, user state)
  - UDP voice: AES-128-OCB encrypted, Opus or CELT codec
  - Both use the same session after initial TLS handshake
  - Ping/keepalive every 15 seconds

  ## Limitations

  - Bridge appears as a single user in Mumble (bot client)
  - Mumble positional audio is not bridged (different coordinate system)
  - Mumble ACLs are not enforced in Burble (and vice versa)
  - Bridge must be explicitly enabled by both server admins
  """

  use GenServer
  require Logger
  import Bitwise

  # Mumble protocol constants.
  @default_port 64738
  @ping_interval_ms 15_000
  # Opus codec version: 0x40000BB8 (used in codec version negotiation).

  # Mumble message types (protobuf IDs).
  @msg_version 0
  @msg_udp_tunnel 1
  @msg_authenticate 2
  @msg_ping 3
  @msg_user_remove 8
  @msg_channel_state 7
  @msg_user_state 9
  @msg_text_message 11
  @msg_codec_version 21
  @msg_permission_denied 24

  # Mumble UDP codec type for Opus (upper 3 bits of type_target byte).
  @opus_type 4

  @type bridge_config :: %{
          room_id: String.t(),
          mumble_host: String.t(),
          mumble_port: pos_integer(),
          mumble_channel: String.t(),
          bot_name: String.t(),
          password: String.t() | nil,
          positional_audio: boolean()
        }

  @type bridge_state :: %{
          config: bridge_config(),
          tcp_socket: port() | nil,
          udp_socket: port() | nil,
          session_id: non_neg_integer() | nil,
          channel_id: non_neg_integer() | nil,
          mumble_users: map(),
          user_positions: %{non_neg_integer() => {float(), float(), float()}},
          connected: boolean(),
          ping_ref: reference() | nil
        }

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc "Start a Mumble bridge for a Burble room."
  def start_link(opts) do
    room_id = Keyword.fetch!(opts, :room_id)
    GenServer.start_link(__MODULE__, opts, name: via(room_id))
  end

  @doc "Get the list of Mumble users currently in the bridged channel."
  @spec mumble_users(GenServer.name()) :: {:ok, [map()]}
  def mumble_users(bridge) do
    GenServer.call(bridge, :mumble_users)
  end

  @doc "Send a text message from Burble to the Mumble channel."
  @spec send_text(GenServer.name(), String.t(), String.t()) :: :ok
  def send_text(bridge, sender_name, message) do
    GenServer.cast(bridge, {:send_text, sender_name, message})
  end

  @doc """
  Relay an audio frame from a Burble peer to Mumble.

  `position` is an optional `{x, y, z}` float tuple. When provided and the
  bridge was started with `positional_audio: true`, coordinates are appended
  to the voice packet so Mumble clients can spatialise the audio.
  """
  @spec relay_to_mumble(GenServer.name(), binary(), {float(), float(), float()} | nil) :: :ok
  def relay_to_mumble(bridge, opus_frame, position \\ nil) do
    GenServer.cast(bridge, {:relay_to_mumble, opus_frame, position})
  end

  @doc "Get the last known positional audio coordinates for a Mumble user."
  @spec user_position(GenServer.name(), non_neg_integer()) :: {:ok, {float(), float(), float()}} | :unknown
  def user_position(bridge, session_id) do
    GenServer.call(bridge, {:user_position, session_id})
  end

  @doc "Stop the bridge and disconnect from Mumble."
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
      mumble_host: Keyword.fetch!(opts, :mumble_host),
      mumble_port: Keyword.get(opts, :mumble_port, @default_port),
      mumble_channel: Keyword.get(opts, :mumble_channel, "Root"),
      bot_name: Keyword.get(opts, :bot_name, "Burble Bridge"),
      password: Keyword.get(opts, :password),
      positional_audio: Keyword.get(opts, :positional_audio, false)
    }

    state = %{
      config: config,
      tcp_socket: nil,
      udp_socket: nil,
      session_id: nil,
      channel_id: nil,
      mumble_users: %{},
      user_positions: %{},
      connected: false,
      ping_ref: nil
    }

    # Connect asynchronously to avoid blocking the supervisor.
    send(self(), :connect)

    Logger.info("[MumbleBridge] Starting bridge: #{config.room_id} ↔ #{config.mumble_host}:#{config.mumble_port}/#{config.mumble_channel}")

    {:ok, state}
  end

  @impl true
  def handle_info(:connect, state) do
    case connect_to_mumble(state.config) do
      {:ok, tcp_socket} ->
        # Send version + authenticate messages.
        send_version(tcp_socket)
        send_authenticate(tcp_socket, state.config)

        # Start ping timer.
        ping_ref = Process.send_after(self(), :ping, @ping_interval_ms)

        Logger.info("[MumbleBridge] Connected to #{state.config.mumble_host}")

        {:noreply, %{state | tcp_socket: tcp_socket, connected: true, ping_ref: ping_ref}}

      {:error, reason} ->
        Logger.error("[MumbleBridge] Connection failed: #{inspect(reason)}")
        # Retry after 5 seconds.
        Process.send_after(self(), :connect, 5_000)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:ping, %{tcp_socket: socket} = state) when not is_nil(socket) do
    send_ping(socket)
    ping_ref = Process.send_after(self(), :ping, @ping_interval_ms)
    {:noreply, %{state | ping_ref: ping_ref}}
  end

  @impl true
  def handle_info(:ping, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:tcp, _socket, data}, state) do
    # Parse Mumble protobuf message.
    state = handle_mumble_message(data, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:tcp_closed, _socket}, state) do
    Logger.warning("[MumbleBridge] TCP connection closed, reconnecting...")
    if state.ping_ref, do: Process.cancel_timer(state.ping_ref)
    Process.send_after(self(), :connect, 5_000)
    {:noreply, %{state | tcp_socket: nil, connected: false, ping_ref: nil}}
  end

  @impl true
  def handle_info({:tcp_error, _socket, reason}, state) do
    Logger.error("[MumbleBridge] TCP error: #{inspect(reason)}")
    if state.ping_ref, do: Process.cancel_timer(state.ping_ref)
    Process.send_after(self(), :connect, 5_000)
    {:noreply, %{state | tcp_socket: nil, connected: false, ping_ref: nil}}
  end

  @impl true
  def handle_call(:mumble_users, _from, state) do
    users = Map.values(state.mumble_users)
    {:reply, {:ok, users}, state}
  end

  @impl true
  def handle_call({:user_position, session_id}, _from, state) do
    case Map.fetch(state.user_positions, session_id) do
      {:ok, pos} -> {:reply, {:ok, pos}, state}
      :error -> {:reply, :unknown, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      room_id: state.config.room_id,
      mumble_host: state.config.mumble_host,
      mumble_channel: state.config.mumble_channel,
      connected: state.connected,
      session_id: state.session_id,
      channel_id: state.channel_id,
      mumble_user_count: map_size(state.mumble_users),
      bot_name: state.config.bot_name
    }

    {:reply, {:ok, status}, state}
  end

  @impl true
  def handle_cast({:send_text, sender_name, message}, %{tcp_socket: socket} = state) when not is_nil(socket) do
    # Encode as Mumble TextMessage protobuf.
    text = "[#{sender_name}] #{message}"
    send_text_message(socket, text, state.channel_id)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:send_text, _, _}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_cast({:relay_to_mumble, opus_frame, position}, %{tcp_socket: socket} = state) when not is_nil(socket) do
    # Voice is tunneled over the TCP control channel via UDPTunnel (msg type 1).
    # This avoids OCB-AES128 UDP encryption complexity and works through firewalls.
    # Mumble servers support UDPTunnel for exactly this case.
    pos = if state.config.positional_audio, do: position, else: nil
    voice_packet = build_voice_packet(state.session_id, opus_frame, pos)
    send_mumble_packet(socket, @msg_udp_tunnel, voice_packet)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:relay_to_mumble, _opus_frame, _position}, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.tcp_socket, do: :gen_tcp.close(state.tcp_socket)
    if state.udp_socket, do: :gen_udp.close(state.udp_socket)
    if state.ping_ref, do: Process.cancel_timer(state.ping_ref)
    Logger.info("[MumbleBridge] Bridge stopped for room #{state.config.room_id}")
    :ok
  end

  # ---------------------------------------------------------------------------
  # Private: Mumble protocol implementation
  # ---------------------------------------------------------------------------

  defp via(room_id) do
    {:via, Registry, {Burble.RoomRegistry, {:mumble_bridge, room_id}}}
  end

  # Connect to Murmur via TLS.
  defp connect_to_mumble(config) do
    host = String.to_charlist(config.mumble_host)
    port = config.mumble_port

    tcp_opts = [:binary, active: true, packet: :raw]

    case :gen_tcp.connect(host, port, tcp_opts, 10_000) do
      {:ok, tcp_socket} ->
        # Upgrade to TLS.
        tls_opts = [
          verify: :verify_none,
          versions: [:"tlsv1.2", :"tlsv1.3"]
        ]

        case :ssl.connect(tcp_socket, tls_opts, 10_000) do
          {:ok, ssl_socket} -> {:ok, ssl_socket}
          {:error, reason} -> {:error, {:tls_upgrade_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:tcp_connect_failed, reason}}
    end
  end

  # Send Mumble Version message (type 0).
  defp send_version(socket) do
    # Version: v1.5.0 (protocol compatible).
    # Protobuf fields: version (uint32), release (string), os (string), os_version (string).
    version_payload = <<1::32-big, 5::32-big, 0::32-big>>
    send_mumble_packet(socket, @msg_version, version_payload)
  end

  # Send Mumble Authenticate message (type 2).
  defp send_authenticate(socket, config) do
    # Protobuf: username (string), password (string), tokens (repeated string),
    # celt_versions (repeated int32), opus (bool).
    username = config.bot_name
    password = config.password || ""

    # Simplified protobuf encoding for Authenticate.
    # Field 1 (username): tag 0x0A, length-delimited string.
    # Field 2 (password): tag 0x12, length-delimited string.
    # Field 5 (opus): tag 0x28, varint 1 (true).
    payload =
      encode_string_field(1, username) <>
      encode_string_field(2, password) <>
      encode_varint_field(5, 1)

    send_mumble_packet(socket, @msg_authenticate, payload)
  end

  # Send Mumble Ping message (type 3).
  defp send_ping(socket) do
    timestamp = System.system_time(:millisecond)
    # Protobuf field 1 (timestamp): tag 0x08, varint.
    payload = encode_varint_field(1, timestamp)
    send_mumble_packet(socket, @msg_ping, payload)
  end

  # Send a text message to a Mumble channel.
  defp send_text_message(socket, text, channel_id) do
    # TextMessage: channel_id (repeated uint32), message (string).
    payload =
      encode_varint_field(3, channel_id || 0) <>
      encode_string_field(5, text)

    send_mumble_packet(socket, @msg_text_message, payload)
  end

  # Build a Mumble voice UDP packet for tunneling over TCP.
  # Optionally appends positional audio (x, y, z) as three little-endian float32s.
  defp build_voice_packet(session_id, opus_frame, position) do
    type_target = @opus_type <<< 5  # Opus codec, target = 0 (normal talking).
    opus_len = byte_size(opus_frame)

    base =
      <<type_target::8>> <>
      encode_varint(session_id || 0) <>
      encode_varint(0) <>            # sequence number — simplified; production should increment
      encode_varint(opus_len) <>
      opus_frame

    case position do
      {x, y, z} ->
        base <> <<x::little-float-32, y::little-float-32, z::little-float-32>>
      _ ->
        base
    end
  end

  # Send a Mumble TCP packet: <<type::16-big, length::32-big, payload::binary>>.
  defp send_mumble_packet(socket, msg_type, payload) do
    header = <<msg_type::16-big, byte_size(payload)::32-big>>
    :ssl.send(socket, header <> payload)
  end

  # Handle an incoming Mumble protobuf message.
  defp handle_mumble_message(<<msg_type::16-big, length::32-big, payload::binary-size(length), rest::binary>>, state) do
    state =
      case msg_type do
        @msg_user_state ->
          handle_user_state(payload, state)

        @msg_user_remove ->
          handle_user_remove(payload, state)

        @msg_channel_state ->
          handle_channel_state(payload, state)

        @msg_text_message ->
          handle_text_from_mumble(payload, state)

        @msg_udp_tunnel ->
          # Incoming voice packet tunneled over TCP — parse Opus + optional position.
          handle_udp_tunnel(payload, state)

        @msg_permission_denied ->
          reason = decode_string_field(payload, 2) || "unknown"
          Logger.warning("[MumbleBridge] Permission denied by Mumble server: #{reason}")
          state

        @msg_codec_version ->
          Logger.debug("[MumbleBridge] Codec version received")
          state

        @msg_ping ->
          state

        _ ->
          state
      end

    # Process remaining data if multiple messages arrived.
    if byte_size(rest) > 6 do
      handle_mumble_message(rest, state)
    else
      state
    end
  end

  defp handle_mumble_message(_data, state), do: state

  # Handle UserState message — track users and mirror mute/suppress to Burble.
  #
  # Mumble UserState protobuf fields used here:
  #   1 = session (uint32)     — unique per-connection session ID
  #   2 = name (string)        — display name
  #   3 = channel_id (uint32)  — current channel
  #   7 = mute (bool)          — server-muted by admin
  #   8 = deaf (bool)          — server-deafened by admin
  #   9 = suppress (bool)      — suppressed (no permission to speak in channel)
  defp handle_user_state(payload, state) do
    session_id = decode_varint_field(payload, 1)

    unless session_id do
      state
    else
      existing = Map.get(state.mumble_users, session_id, %{})

      user = %{
        session_id: session_id,
        name:       decode_string_field(payload, 2) || existing[:name],
        channel_id: decode_varint_field(payload, 3) || existing[:channel_id],
        muted:      decode_bool_field(payload, 7, existing[:muted] || false),
        deaf:       decode_bool_field(payload, 8, existing[:deaf] || false),
        suppress:   decode_bool_field(payload, 9, existing[:suppress] || false)
      }

      Logger.debug("[MumbleBridge] UserState: #{user.name} mute=#{user.muted} suppress=#{user.suppress}")

      # Mirror server-mute/suppress into the Burble room so the user can't
      # be heard in Burble either when Mumble has silenced them.
      if user.muted or user.suppress do
        Phoenix.PubSub.broadcast(Burble.PubSub, "room:#{state.config.room_id}",
          {:mumble_user_muted, %{session_id: session_id, name: user.name, muted: true}})
      end

      mumble_users = Map.put(state.mumble_users, session_id, user)
      %{state | mumble_users: mumble_users}
    end
  end

  # Handle UserRemove — a Mumble user left or was kicked/banned.
  defp handle_user_remove(payload, state) do
    session_id = decode_varint_field(payload, 1)
    actor      = decode_varint_field(payload, 2)
    reason_str = decode_string_field(payload, 3)
    banned     = decode_bool_field(payload, 4, false)

    if session_id do
      user = Map.get(state.mumble_users, session_id, %{name: "unknown"})
      action = if banned, do: "banned", else: if(actor, do: "kicked", else: "left")
      Logger.info("[MumbleBridge] #{user.name} #{action}#{if reason_str, do: ": #{reason_str}", else: ""}")

      Phoenix.PubSub.broadcast(Burble.PubSub, "room:#{state.config.room_id}",
        {:mumble_user_left, %{session_id: session_id, name: user.name, reason: action}})

      %{state | mumble_users: Map.delete(state.mumble_users, session_id)}
    else
      state
    end
  end

  # Handle incoming voice tunnel — parse Opus frame and optional positional data.
  #
  # Mumble UDP voice packet layout (tunneled over TCP in UDPTunnel):
  #   1 byte:  type_target  (bits 7-5 = codec type, bits 4-0 = target)
  #   VarInt:  session ID   (whose voice this is)
  #   VarInt:  sequence number
  #   VarInt:  opus payload length (bit 13 set = last frame in talk burst)
  #   N bytes: opus frame
  #   [optional] 3 × float32-LE: x, y, z positional coordinates
  defp handle_udp_tunnel(<<type_target::8, rest::binary>>, state) do
    codec_type = type_target >>> 5

    if codec_type == @opus_type do
      {session_id, rest} = decode_varint_value(rest)
      {_seq, rest} = decode_varint_value(rest)
      {len_flags, rest} = decode_varint_value(rest)
      opus_len = len_flags &&& 0x1FFF  # mask off the last-frame flag bit

      case rest do
        <<_opus::binary-size(opus_len), pos_rest::binary>> when byte_size(pos_rest) >= 12 ->
          # Positional audio present — extract and store per-user coordinates.
          <<x::little-float-32, y::little-float-32, z::little-float-32, _::binary>> = pos_rest
          Logger.debug("[MumbleBridge] Positional audio: session=#{session_id} pos={#{x}, #{y}, #{z}}")

          Phoenix.PubSub.broadcast(Burble.PubSub, "room:#{state.config.room_id}",
            {:mumble_user_position, %{session_id: session_id, x: x, y: y, z: z}})

          %{state | user_positions: Map.put(state.user_positions, session_id, {x, y, z})}

        _ ->
          state
      end
    else
      state
    end
  rescue
    _ -> state
  end

  # Handle ChannelState — find our target channel ID.
  defp handle_channel_state(payload, state) do
    channel_name = decode_string_field(payload, 3)
    channel_id = decode_varint_field(payload, 1)

    if channel_name == state.config.mumble_channel and channel_id do
      Logger.info("[MumbleBridge] Found channel '#{channel_name}' (ID: #{channel_id})")
      %{state | channel_id: channel_id}
    else
      state
    end
  end

  # Handle text message from Mumble — relay to Burble room.
  defp handle_text_from_mumble(payload, state) do
    message = decode_string_field(payload, 5)

    if message do
      # Broadcast to the Burble room via PubSub.
      Phoenix.PubSub.broadcast(
        Burble.PubSub,
        "room:#{state.config.room_id}",
        {:mumble_text, %{
          from: "Mumble",
          body: message,
          bridge: true
        }}
      )
    end

    state
  end

  # ---------------------------------------------------------------------------
  # Private: Protobuf encoding/decoding helpers (simplified)
  # ---------------------------------------------------------------------------

  # Encode a varint field: <<(field_number << 3 | 0)::varint, value::varint>>.
  defp encode_varint_field(field_number, value) do
    tag = field_number * 8 + 0  # Wire type 0 = varint.
    encode_varint(tag) <> encode_varint(value)
  end

  # Encode a length-delimited string field.
  defp encode_string_field(field_number, string) do
    tag = field_number * 8 + 2  # Wire type 2 = length-delimited.
    data = :erlang.iolist_to_binary(string)
    encode_varint(tag) <> encode_varint(byte_size(data)) <> data
  end

  # Encode a protobuf varint.
  defp encode_varint(value) when value < 128, do: <<value::8>>
  defp encode_varint(value) do
    <<1::1, value &&& 0x7F::7>> <> encode_varint(value >>> 7)
  end

  # Decode a bool field (wire type 0 varint: 0 = false, 1 = true).
  # Returns `default` if the field is absent.
  defp decode_bool_field(payload, target_field, default) do
    case decode_varint_field(payload, target_field) do
      nil -> default
      0   -> false
      _   -> true
    end
  end

  # Decode a varint field from protobuf payload (simplified, finds first match).
  defp decode_varint_field(<<>>, _target_field), do: nil
  defp decode_varint_field(payload, target_field) do
    case decode_tag(payload) do
      {^target_field, 0, rest} ->
        {value, _rest} = decode_varint_value(rest)
        value

      {_field, wire_type, rest} ->
        skip_field(rest, wire_type)
        |> case do
          rest when is_binary(rest) -> decode_varint_field(rest, target_field)
          _ -> nil
        end
    end
  rescue
    _ -> nil
  end

  # Decode a string field from protobuf payload.
  defp decode_string_field(<<>>, _target_field), do: nil
  defp decode_string_field(payload, target_field) do
    case decode_tag(payload) do
      {^target_field, 2, rest} ->
        {length, rest} = decode_varint_value(rest)
        <<string::binary-size(length), _::binary>> = rest
        string

      {_field, wire_type, rest} ->
        case skip_field(rest, wire_type) do
          rest when is_binary(rest) -> decode_string_field(rest, target_field)
          _ -> nil
        end
    end
  rescue
    _ -> nil
  end

  # Decode a protobuf tag (field number + wire type).
  defp decode_tag(data) do
    {tag, rest} = decode_varint_value(data)
    field_number = tag >>> 3
    wire_type = tag &&& 0x07
    {field_number, wire_type, rest}
  end

  # Decode a varint value.
  defp decode_varint_value(<<0::1, byte::7, rest::binary>>), do: {byte, rest}
  defp decode_varint_value(<<1::1, byte::7, rest::binary>>) do
    {next, rest2} = decode_varint_value(rest)
    {byte + (next <<< 7), rest2}
  end

  # Skip a field based on wire type.
  defp skip_field(data, 0) do  # Varint
    {_value, rest} = decode_varint_value(data)
    rest
  end
  defp skip_field(<<_::64, rest::binary>>, 1), do: rest  # 64-bit
  defp skip_field(data, 2) do  # Length-delimited
    {length, rest} = decode_varint_value(data)
    <<_::binary-size(length), rest2::binary>> = rest
    rest2
  end
  defp skip_field(<<_::32, rest::binary>>, 5), do: rest  # 32-bit
  defp skip_field(_, _), do: <<>>
end
