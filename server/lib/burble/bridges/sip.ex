# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Burble.Bridges.SIP — SIP gateway for IP phone and PBX interoperability.
#
# Implements a SIP User Agent (UAC/UAS) that bridges Burble rooms to
# SIP endpoints (IP phones, FreeSWITCH, Asterisk, PBXs).
#
# This is an INTEROP bridge, not a migration tool:
#   - SIP users stay on their phones/PBXs, Burble users stay in Burble
#   - They hear each other through the bridge
#   - No SIP features are replicated (BLF, call parking, IVR)
#   - Bridge must be explicitly enabled by server admin
#
# Protocol: SIP is a text-based signalling protocol (like HTTP):
#   - UDP transport on port 5060 (TCP optional for reliability)
#   - REGISTER for registrar authentication
#   - INVITE/ACK/BYE for call setup and teardown
#   - SDP (Session Description Protocol) in message body for media negotiation
#   - RTP for actual audio media transport
#   - DTMF relay via RFC 2833 (telephone-event in RTP)
#
# Architecture:
#   Burble Room ↔ SIPBridge GenServer ↔ SIP Endpoint
#                        │
#               Audio: Opus ↔ G.711/Opus transcoding
#               via RTP media relay
#
# The bridge acts as a SIP endpoint. Inbound SIP calls are routed to a
# Burble room. Outbound calls dial SIP URIs from a Burble room.
#
# SIP reference: RFC 3261 (core), RFC 4566 (SDP), RFC 2833 (DTMF)

defmodule Burble.Bridges.SIP do
  @moduledoc """
  SIP gateway bridge between Burble and IP telephony.

  Acts as a SIP User Agent that can:
  - Register with a SIP registrar for inbound call routing
  - Accept inbound SIP INVITEs and route them to Burble rooms
  - Place outbound SIP calls from Burble rooms
  - Negotiate media via SDP (Opus only — see codec policy below)
  - Relay RTP audio bidirectionally
  - Handle DTMF digits via RFC 2833 telephone-event

  ## Starting a bridge

      {:ok, pid} = SIP.start_link(
        room_id: "conference_room",
        sip_host: "sip.example.com",
        sip_port: 5060,
        sip_user: "burble-bridge",
        sip_password: "secret",
        local_rtp_port: 10000
      )

  ## Placing outbound calls

      SIP.dial(bridge, "sip:user@example.com")

  ## SIP protocol overview

  - Text-based request/response (INVITE, BYE, REGISTER, etc.)
  - Headers: Via, From, To, Call-ID, CSeq, Contact, Content-Type
  - SDP body describes media capabilities (codecs, ports, IP)
  - RTP transports audio on negotiated ports
  - Dialog model: INVITE → 100 Trying → 180 Ringing → 200 OK → ACK

  ## Codec policy (Phase 1 — Opus-only)

  The bridge advertises and accepts **only** `opus/48000/2` (payload type 111)
  plus `telephone-event/8000` for DTMF.

  If a peer's SDP offer contains no Opus payload type, the bridge responds with
  `488 Not Acceptable Here` and tears the call down immediately. No G.711
  (PCMU/PCMA) transcoding is performed. A transcoder is not wired; previous
  stub code that returned silence was removed in Phase 1 Workstream 1.1.

  SIP peers that support only G.711 (e.g. PSTN gateways) cannot currently
  reach Burble rooms via this bridge. Phase 4 (Option A) will add a real
  libopus NIF to unblock that interop path.

  ## Limitations

  - Single concurrent call per bridge instance (spawn multiple for multi-line)
  - No call transfer, hold, or conference features
  - No T.38 fax support
  - No SRTP (RTP media is unencrypted) — use VPN for security
  - DNS SRV lookup not implemented (direct host:port only)
  - G.711 (PCMU/PCMA) transcoding not implemented — Opus-capable peers only
  """

  use GenServer
  require Logger
  import Bitwise

  # SIP default port.
  @default_sip_port 5060

  # SIP transport protocol.
  @transport "UDP"

  # Default local RTP base port.
  @default_rtp_port 10_000

  # RTP payload types for supported codecs.
  @pt_pcmu 0
  @pt_pcma 8
  @pt_opus 111
  @pt_dtmf 101

  # G.711 µ-law encoding table bias.
  @ulaw_bias 0x84
  @ulaw_clip 32635

  # RTP header size.
  @rtp_header_size 12

  # SIP registration refresh interval (seconds).
  @register_interval_s 3600

  # SIP transaction timeout (milliseconds).
  # @transaction_timeout_ms 32_000  # Reserved — used for SIP transaction retries.

  # Audio frame timing: 20ms frames.
  # @frame_duration_ms 20  # Reserved — 20ms per Opus frame at 48kHz.

  # CRLF for SIP message line endings.
  @crlf "\r\n"

  @type bridge_config :: %{
          room_id: String.t(),
          sip_host: String.t(),
          sip_port: pos_integer(),
          sip_user: String.t(),
          sip_password: String.t() | nil,
          sip_domain: String.t(),
          local_ip: String.t(),
          local_rtp_port: pos_integer()
        }

  @type call_state :: %{
          call_id: String.t(),
          from_tag: String.t(),
          to_tag: String.t() | nil,
          remote_uri: String.t(),
          cseq: pos_integer(),
          state: :idle | :inviting | :ringing | :active | :terminating,
          remote_rtp_ip: String.t() | nil,
          remote_rtp_port: pos_integer() | nil,
          negotiated_codec: atom(),
          rtp_sequence: non_neg_integer(),
          rtp_timestamp: non_neg_integer(),
          rtp_ssrc: non_neg_integer()
        }

  @type bridge_state :: %{
          config: bridge_config(),
          sip_socket: port() | nil,
          rtp_socket: port() | nil,
          registered: boolean(),
          register_timer: reference() | nil,
          call: call_state() | nil,
          pending_transactions: map()
        }

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc """
  Start a SIP bridge for a Burble room.

  ## Required options

    * `:room_id` — The Burble room ID to bridge
    * `:sip_host` — SIP registrar/proxy host
    * `:sip_user` — SIP username for registration

  ## Optional

    * `:sip_port` — SIP port (default 5060)
    * `:sip_password` — SIP password for REGISTER authentication
    * `:sip_domain` — SIP domain (defaults to sip_host)
    * `:local_ip` — Local IP for SDP (auto-detected if omitted)
    * `:local_rtp_port` — Local RTP port (default 10000)
  """
  def start_link(opts) do
    room_id = Keyword.fetch!(opts, :room_id)
    GenServer.start_link(__MODULE__, opts, name: via(room_id))
  end

  @doc "Place an outbound SIP call to the given SIP URI."
  @spec dial(GenServer.name(), String.t()) :: :ok | {:error, :already_in_call}
  def dial(bridge, sip_uri) do
    GenServer.call(bridge, {:dial, sip_uri})
  end

  @doc "Hang up the current call."
  @spec hangup(GenServer.name()) :: :ok
  def hangup(bridge) do
    GenServer.cast(bridge, :hangup)
  end

  @doc "Relay an Opus audio frame from a Burble peer to the SIP call."
  @spec relay_to_sip(GenServer.name(), binary()) :: :ok
  def relay_to_sip(bridge, opus_frame) do
    GenServer.cast(bridge, {:relay_to_sip, opus_frame})
  end

  @doc "Send a DTMF digit to the SIP endpoint."
  @spec send_dtmf(GenServer.name(), String.t()) :: :ok
  def send_dtmf(bridge, digit) do
    GenServer.cast(bridge, {:send_dtmf, digit})
  end

  @doc "Stop the bridge, hang up any active call, and unregister."
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
    local_ip = Keyword.get(opts, :local_ip, detect_local_ip())

    config = %{
      room_id: Keyword.fetch!(opts, :room_id),
      sip_host: Keyword.fetch!(opts, :sip_host),
      sip_port: Keyword.get(opts, :sip_port, @default_sip_port),
      sip_user: Keyword.fetch!(opts, :sip_user),
      sip_password: Keyword.get(opts, :sip_password),
      sip_domain: Keyword.get(opts, :sip_domain, Keyword.fetch!(opts, :sip_host)),
      local_ip: local_ip,
      local_rtp_port: Keyword.get(opts, :local_rtp_port, @default_rtp_port)
    }

    state = %{
      config: config,
      sip_socket: nil,
      rtp_socket: nil,
      registered: false,
      register_timer: nil,
      call: nil,
      pending_transactions: %{}
    }

    # Open sockets asynchronously.
    send(self(), :open_sockets)

    Logger.info(
      "[SIPBridge] Starting bridge: #{config.room_id} ↔ " <>
        "SIP #{config.sip_user}@#{config.sip_host}:#{config.sip_port}"
    )

    {:ok, state}
  end

  # -- Socket initialization -------------------------------------------------

  @impl true
  def handle_info(:open_sockets, state) do
    # Open SIP signalling socket (UDP on port 5060 or configured port).
    case :gen_udp.open(0, [:binary, active: true]) do
      {:ok, sip_socket} ->
        # Open RTP media socket.
        case :gen_udp.open(state.config.local_rtp_port, [:binary, active: true]) do
          {:ok, rtp_socket} ->
            Logger.info("[SIPBridge] SIP and RTP sockets opened")

            # Register with SIP registrar if we have credentials.
            if state.config.sip_password do
              send(self(), :register)
            end

            {:noreply, %{state | sip_socket: sip_socket, rtp_socket: rtp_socket}}

          {:error, reason} ->
            Logger.error("[SIPBridge] RTP socket open failed: #{inspect(reason)}")
            :gen_udp.close(sip_socket)
            Process.send_after(self(), :open_sockets, 5_000)
            {:noreply, state}
        end

      {:error, reason} ->
        Logger.error("[SIPBridge] SIP socket open failed: #{inspect(reason)}")
        Process.send_after(self(), :open_sockets, 5_000)
        {:noreply, state}
    end
  end

  # -- SIP REGISTER ----------------------------------------------------------

  @impl true
  def handle_info(:register, %{sip_socket: socket} = state) when not is_nil(socket) do
    call_id = generate_call_id()
    from_tag = generate_tag()
    branch = generate_branch()
    cseq = 1

    register_msg = build_sip_message("REGISTER", %{
      request_uri: "sip:#{state.config.sip_domain}",
      from: "<sip:#{state.config.sip_user}@#{state.config.sip_domain}>;tag=#{from_tag}",
      to: "<sip:#{state.config.sip_user}@#{state.config.sip_domain}>",
      call_id: call_id,
      cseq: "#{cseq} REGISTER",
      via: "SIP/2.0/#{@transport} #{state.config.local_ip};branch=#{branch}",
      contact: "<sip:#{state.config.sip_user}@#{state.config.local_ip}>",
      expires: "#{@register_interval_s}",
      content_length: "0"
    })

    send_sip(socket, register_msg, state.config.sip_host, state.config.sip_port)

    # Schedule re-registration.
    timer = Process.send_after(self(), :register, @register_interval_s * 1_000)

    {:noreply, %{state | register_timer: timer}}
  end

  @impl true
  def handle_info(:register, state), do: {:noreply, state}

  # -- Incoming UDP (SIP signalling) -----------------------------------------

  @impl true
  def handle_info({:udp, socket, src_ip, src_port, data}, state) do
    cond do
      # SIP message on SIP socket.
      socket == state.sip_socket ->
        state = handle_sip_message(data, src_ip, src_port, state)
        {:noreply, state}

      # RTP audio on RTP socket.
      socket == state.rtp_socket ->
        state = handle_rtp_packet(data, state)
        {:noreply, state}

      true ->
        {:noreply, state}
    end
  end

  # -- Call handling (GenServer calls) ---------------------------------------

  @impl true
  def handle_call({:dial, sip_uri}, _from, %{call: nil} = state) do
    state = initiate_call(sip_uri, state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:dial, _sip_uri}, _from, state) do
    {:reply, {:error, :already_in_call}, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    call_status =
      if state.call do
        %{
          call_id: state.call.call_id,
          state: state.call.state,
          remote_uri: state.call.remote_uri,
          codec: state.call.negotiated_codec
        }
      else
        nil
      end

    status = %{
      room_id: state.config.room_id,
      sip_host: state.config.sip_host,
      registered: state.registered,
      call: call_status
    }

    {:reply, {:ok, status}, state}
  end

  # -- Call handling (GenServer casts) ---------------------------------------

  @impl true
  def handle_cast(:hangup, %{call: call} = state) when not is_nil(call) do
    state = send_bye(state)
    {:noreply, %{state | call: nil}}
  end

  @impl true
  def handle_cast(:hangup, state), do: {:noreply, state}

  @impl true
  def handle_cast({:relay_to_sip, opus_frame}, %{call: %{state: :active}} = state) do
    state = send_rtp_audio(opus_frame, state)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:relay_to_sip, _}, state), do: {:noreply, state}

  @impl true
  def handle_cast({:send_dtmf, digit}, %{call: %{state: :active}} = state) do
    send_rtp_dtmf(digit, state)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:send_dtmf, _}, state), do: {:noreply, state}

  # -- Terminate -------------------------------------------------------------

  @impl true
  def terminate(_reason, state) do
    # Hang up any active call.
    if state.call, do: send_bye(state)

    if state.sip_socket, do: :gen_udp.close(state.sip_socket)
    if state.rtp_socket, do: :gen_udp.close(state.rtp_socket)
    if state.register_timer, do: Process.cancel_timer(state.register_timer)

    Logger.info("[SIPBridge] Bridge stopped for room #{state.config.room_id}")
    :ok
  end

  # ---------------------------------------------------------------------------
  # Private: SIP message parsing
  # ---------------------------------------------------------------------------

  # Parse and handle an incoming SIP message (request or response).
  defp handle_sip_message(data, src_ip, src_port, state) do
    message = String.trim(data)
    lines = String.split(message, @crlf)

    case lines do
      [start_line | header_lines] ->
        {headers, body} = parse_sip_headers(header_lines)

        cond do
          # SIP response (e.g., "SIP/2.0 200 OK").
          String.starts_with?(start_line, "SIP/2.0") ->
            {_version, status_code, reason} = parse_status_line(start_line)
            handle_sip_response(status_code, reason, headers, body, state)

          # SIP request (e.g., "INVITE sip:user@host SIP/2.0").
          true ->
            {method, request_uri, _version} = parse_request_line(start_line)
            handle_sip_request(method, request_uri, headers, body, src_ip, src_port, state)
        end

      _ ->
        Logger.warning("[SIPBridge] Malformed SIP message")
        state
    end
  end

  # Parse SIP headers into a map (lowercase keys). Body is after the empty line.
  defp parse_sip_headers(lines) do
    {header_lines, body_lines} =
      Enum.split_while(lines, fn line -> line != "" end)

    headers =
      header_lines
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(line, ":", parts: 2) do
          [key, value] ->
            Map.put(acc, String.downcase(String.trim(key)), String.trim(value))

          _ ->
            acc
        end
      end)

    body = body_lines |> Enum.drop(1) |> Enum.join(@crlf)

    {headers, body}
  end

  # Parse a SIP status line: "SIP/2.0 200 OK" → {"SIP/2.0", 200, "OK"}.
  defp parse_status_line(line) do
    case String.split(line, " ", parts: 3) do
      [version, code_str, reason] ->
        {version, String.to_integer(code_str), reason}

      [version, code_str] ->
        {version, String.to_integer(code_str), ""}

      _ ->
        {"SIP/2.0", 0, "Unknown"}
    end
  end

  # Parse a SIP request line: "INVITE sip:user@host SIP/2.0".
  defp parse_request_line(line) do
    case String.split(line, " ", parts: 3) do
      [method, uri, version] -> {method, uri, version}
      [method, uri] -> {method, uri, "SIP/2.0"}
      _ -> {"UNKNOWN", "", "SIP/2.0"}
    end
  end

  # ---------------------------------------------------------------------------
  # Private: SIP request handling (inbound calls)
  # ---------------------------------------------------------------------------

  # Handle an inbound INVITE — route to Burble room.
  defp handle_sip_request("INVITE", _uri, headers, body, src_ip, src_port, state) do
    call_id = headers["call-id"] || generate_call_id()
    from = headers["from"] || ""
    _to = headers["to"] || ""

    Logger.info("[SIPBridge] Inbound INVITE from #{from}, Call-ID: #{call_id}")

    # Parse SDP from the body to get remote media info.
    {remote_ip, remote_port, codec} = parse_sdp(body)

    case codec do
      :no_opus ->
        # Refuse offers that contain no Opus payload type.
        # We have no G.711 transcoder; sending silence would be worse than refusing.
        Logger.warning(
          "[SIPBridge] Rejecting INVITE #{call_id} — peer offered no Opus codec (488 Not Acceptable Here)"
        )

        send_sip_response(state.sip_socket, 488, "Not Acceptable Here", headers, src_ip, src_port, state)

        state

      :opus ->
        # Send 100 Trying.
        send_sip_response(state.sip_socket, 100, "Trying", headers, src_ip, src_port, state)

        # Send 180 Ringing.
        send_sip_response(state.sip_socket, 180, "Ringing", headers, src_ip, src_port, state)

        # Build SDP answer with Opus only and send 200 OK.
        sdp_answer = build_sdp_answer(state.config.local_ip, state.config.local_rtp_port, :opus)

        send_sip_response_with_body(
          state.sip_socket, 200, "OK", headers,
          "application/sdp", sdp_answer,
          src_ip, src_port, state
        )

        # Set up the call state.
        call = %{
          call_id: call_id,
          from_tag: extract_tag(from),
          to_tag: generate_tag(),
          remote_uri: extract_uri(from),
          cseq: 1,
          state: :active,
          remote_rtp_ip: remote_ip || to_string(:inet.ntoa(src_ip)),
          remote_rtp_port: remote_port || 0,
          negotiated_codec: :opus,
          rtp_sequence: 0,
          rtp_timestamp: 0,
          rtp_ssrc: :rand.uniform(0xFFFFFFFF)
        }

        # Notify the Burble room that a SIP call has connected.
        Phoenix.PubSub.broadcast(
          Burble.PubSub,
          "room:#{state.config.room_id}",
          {:sip_call, %{action: :connected, from: from, call_id: call_id, bridge: true}}
        )

        %{state | call: call}
    end
  end

  # Handle BYE — the remote side is hanging up.
  defp handle_sip_request("BYE", _uri, headers, _body, src_ip, src_port, state) do
    Logger.info("[SIPBridge] Received BYE for Call-ID: #{headers["call-id"]}")

    # Send 200 OK to acknowledge.
    send_sip_response(state.sip_socket, 200, "OK", headers, src_ip, src_port, state)

    # Notify the Burble room.
    if state.call do
      Phoenix.PubSub.broadcast(
        Burble.PubSub,
        "room:#{state.config.room_id}",
        {:sip_call, %{action: :disconnected, call_id: state.call.call_id, bridge: true}}
      )
    end

    %{state | call: nil}
  end

  # Handle ACK — acknowledgement of our 200 OK (no action needed).
  defp handle_sip_request("ACK", _uri, _headers, _body, _src_ip, _src_port, state) do
    Logger.debug("[SIPBridge] Received ACK")
    state
  end

  # Handle OPTIONS — respond with our capabilities (SIP keep-alive).
  defp handle_sip_request("OPTIONS", _uri, headers, _body, src_ip, src_port, state) do
    send_sip_response(state.sip_socket, 200, "OK", headers, src_ip, src_port, state)
    state
  end

  # Catch-all for unhandled SIP methods.
  defp handle_sip_request(method, _uri, headers, _body, src_ip, src_port, state) do
    Logger.debug("[SIPBridge] Unhandled SIP method: #{method}")
    # Respond with 405 Method Not Allowed.
    send_sip_response(state.sip_socket, 405, "Method Not Allowed", headers, src_ip, src_port, state)
    state
  end

  # ---------------------------------------------------------------------------
  # Private: SIP response handling (outbound call flow)
  # ---------------------------------------------------------------------------

  # Handle SIP responses to our outgoing requests.
  defp handle_sip_response(status_code, reason, headers, body, state) do
    cseq_header = headers["cseq"] || ""
    method = cseq_header |> String.split(" ") |> List.last() || ""

    Logger.debug("[SIPBridge] SIP #{status_code} #{reason} for #{method}")

    case {method, status_code} do
      # REGISTER responses.
      {"REGISTER", code} when code >= 200 and code < 300 ->
        Logger.info("[SIPBridge] Registered successfully")
        %{state | registered: true}

      {"REGISTER", 401} ->
        # Authentication required — resend with credentials.
        Logger.info("[SIPBridge] REGISTER requires auth, resending with credentials")
        handle_register_auth_challenge(headers, state)

      # INVITE responses (outbound call).
      {"INVITE", 100} ->
        # 100 Trying — provisional, no action needed.
        state

      {"INVITE", 180} ->
        # 180 Ringing — update call state.
        if state.call, do: %{state | call: %{state.call | state: :ringing}}, else: state

      {"INVITE", code} when code >= 200 and code < 300 ->
        # 200 OK — call is established, parse SDP and send ACK.
        handle_invite_success(headers, body, state)

      {"INVITE", code} when code >= 400 ->
        # Call failed.
        Logger.warning("[SIPBridge] Outbound call failed: #{code} #{reason}")

        Phoenix.PubSub.broadcast(
          Burble.PubSub,
          "room:#{state.config.room_id}",
          {:sip_call, %{action: :failed, reason: reason, bridge: true}}
        )

        %{state | call: nil}

      _ ->
        state
    end
  end

  # Promote a pending call to :active with the negotiated peer transport.
  # Codec is always :opus after Opus-only SDP negotiation.
  defp activate_call(call, to_tag, remote_ip, remote_port) do
    %{
      call
      | state: :active,
        to_tag: to_tag,
        remote_rtp_ip: remote_ip,
        remote_rtp_port: remote_port,
        negotiated_codec: :opus
    }
  end

  # Handle 200 OK for our outbound INVITE — extract SDP, send ACK.
  # If the peer answered without Opus, we send BYE immediately and error out.
  defp handle_invite_success(headers, body, state) do
    {remote_ip, remote_port, codec} = parse_sdp(body)
    to_tag = extract_tag(headers["to"] || "")

    cond do
      codec == :no_opus ->
        Logger.error(
          "[SIPBridge] Outbound call answered without Opus — sending BYE (no transcoder available)"
        )

        active = state.call && activate_call(state.call, to_tag, remote_ip, remote_port)

        # ACK the 200 OK first (required by RFC 3261), then BYE.
        if active, do: send_ack(active, state)

        Phoenix.PubSub.broadcast(
          Burble.PubSub,
          "room:#{state.config.room_id}",
          {:sip_call, %{action: :failed, reason: "no_opus_in_answer", bridge: true}}
        )

        send_bye(%{state | call: active})
        %{state | call: nil}

      state.call ->
        call = activate_call(state.call, to_tag, remote_ip, remote_port)

        # Send ACK.
        send_ack(call, state)

        Logger.info("[SIPBridge] Call established, codec: opus")

        Phoenix.PubSub.broadcast(
          Burble.PubSub,
          "room:#{state.config.room_id}",
          {:sip_call, %{action: :connected, call_id: call.call_id, bridge: true}}
        )

        %{state | call: call}

      true ->
        state
    end
  end

  # Handle authentication challenge for REGISTER (HTTP Digest Auth).
  defp handle_register_auth_challenge(headers, state) do
    www_authenticate = headers["www-authenticate"] || ""

    # Parse the Digest challenge parameters.
    realm = extract_auth_param(www_authenticate, "realm")
    nonce = extract_auth_param(www_authenticate, "nonce")

    if realm && nonce && state.config.sip_password do
      # Compute Digest response: HA1 = MD5(user:realm:pass), HA2 = MD5(method:uri).
      ha1 =
        :crypto.hash(:md5, "#{state.config.sip_user}:#{realm}:#{state.config.sip_password}")
        |> Base.encode16(case: :lower)

      uri = "sip:#{state.config.sip_domain}"

      ha2 =
        :crypto.hash(:md5, "REGISTER:#{uri}")
        |> Base.encode16(case: :lower)

      response =
        :crypto.hash(:md5, "#{ha1}:#{nonce}:#{ha2}")
        |> Base.encode16(case: :lower)

      # Rebuild REGISTER with Authorization header.
      call_id = generate_call_id()
      from_tag = generate_tag()
      branch = generate_branch()

      auth_header =
        "Digest username=\"#{state.config.sip_user}\", " <>
          "realm=\"#{realm}\", nonce=\"#{nonce}\", " <>
          "uri=\"#{uri}\", response=\"#{response}\""

      register_msg = build_sip_message("REGISTER", %{
        request_uri: uri,
        from: "<sip:#{state.config.sip_user}@#{state.config.sip_domain}>;tag=#{from_tag}",
        to: "<sip:#{state.config.sip_user}@#{state.config.sip_domain}>",
        call_id: call_id,
        cseq: "2 REGISTER",
        via: "SIP/2.0/#{@transport} #{state.config.local_ip};branch=#{branch}",
        contact: "<sip:#{state.config.sip_user}@#{state.config.local_ip}>",
        authorization: auth_header,
        expires: "#{@register_interval_s}",
        content_length: "0"
      })

      send_sip(state.sip_socket, register_msg, state.config.sip_host, state.config.sip_port)
    end

    state
  end

  # ---------------------------------------------------------------------------
  # Private: Outbound call initiation
  # ---------------------------------------------------------------------------

  # Initiate an outbound SIP INVITE to the given URI.
  defp initiate_call(sip_uri, state) do
    call_id = generate_call_id()
    from_tag = generate_tag()
    branch = generate_branch()

    # Build SDP offer with our media capabilities.
    sdp_offer = build_sdp_offer(state.config.local_ip, state.config.local_rtp_port)

    invite_msg = build_sip_message("INVITE", %{
      request_uri: sip_uri,
      from: "<sip:#{state.config.sip_user}@#{state.config.sip_domain}>;tag=#{from_tag}",
      to: "<#{sip_uri}>",
      call_id: call_id,
      cseq: "1 INVITE",
      via: "SIP/2.0/#{@transport} #{state.config.local_ip};branch=#{branch}",
      contact: "<sip:#{state.config.sip_user}@#{state.config.local_ip}:#{state.config.local_rtp_port}>",
      content_type: "application/sdp",
      max_forwards: "70",
      content_length: "#{byte_size(sdp_offer)}"
    }, sdp_offer)

    send_sip(state.sip_socket, invite_msg, state.config.sip_host, state.config.sip_port)

    Logger.info("[SIPBridge] Sending INVITE to #{sip_uri}")

    call = %{
      call_id: call_id,
      from_tag: from_tag,
      to_tag: nil,
      remote_uri: sip_uri,
      cseq: 1,
      state: :inviting,
      remote_rtp_ip: nil,
      remote_rtp_port: nil,
      negotiated_codec: :opus,
      rtp_sequence: 0,
      rtp_timestamp: 0,
      rtp_ssrc: :rand.uniform(0xFFFFFFFF)
    }

    %{state | call: call}
  end

  # ---------------------------------------------------------------------------
  # Private: SIP BYE and ACK
  # ---------------------------------------------------------------------------

  # Send a BYE to terminate the current call.
  defp send_bye(%{call: call, sip_socket: socket} = state) when not is_nil(call) do
    branch = generate_branch()

    bye_msg = build_sip_message("BYE", %{
      request_uri: call.remote_uri,
      from: "<sip:#{state.config.sip_user}@#{state.config.sip_domain}>;tag=#{call.from_tag}",
      to: "<#{call.remote_uri}>" <> if(call.to_tag, do: ";tag=#{call.to_tag}", else: ""),
      call_id: call.call_id,
      cseq: "#{call.cseq + 1} BYE",
      via: "SIP/2.0/#{@transport} #{state.config.local_ip};branch=#{branch}",
      content_length: "0"
    })

    send_sip(socket, bye_msg, state.config.sip_host, state.config.sip_port)

    Logger.info("[SIPBridge] Sent BYE for Call-ID: #{call.call_id}")

    state
  end

  defp send_bye(state), do: state

  # Send an ACK to confirm a 200 OK for INVITE.
  defp send_ack(call, state) do
    branch = generate_branch()

    ack_msg = build_sip_message("ACK", %{
      request_uri: call.remote_uri,
      from: "<sip:#{state.config.sip_user}@#{state.config.sip_domain}>;tag=#{call.from_tag}",
      to: "<#{call.remote_uri}>" <> if(call.to_tag, do: ";tag=#{call.to_tag}", else: ""),
      call_id: call.call_id,
      cseq: "#{call.cseq} ACK",
      via: "SIP/2.0/#{@transport} #{state.config.local_ip};branch=#{branch}",
      content_length: "0"
    })

    send_sip(state.sip_socket, ack_msg, state.config.sip_host, state.config.sip_port)
  end

  # ---------------------------------------------------------------------------
  # Private: SDP (Session Description Protocol)
  # ---------------------------------------------------------------------------

  # Build an SDP offer advertising Opus only.
  # G.711 (PCMU/PCMA) is intentionally omitted: no transcoder is wired.
  # Peers that cannot accept Opus will refuse and we will error out cleanly.
  defp build_sdp_offer(local_ip, rtp_port) do
    session_id = System.system_time(:second)

    [
      "v=0",
      "o=burble #{session_id} #{session_id} IN IP4 #{local_ip}",
      "s=Burble Bridge",
      "c=IN IP4 #{local_ip}",
      "t=0 0",
      "m=audio #{rtp_port} RTP/AVP #{@pt_opus} #{@pt_dtmf}",
      "a=rtpmap:#{@pt_opus} opus/48000/2",
      "a=rtpmap:#{@pt_dtmf} telephone-event/8000",
      "a=fmtp:#{@pt_dtmf} 0-16",
      "a=ptime:20",
      "a=sendrecv"
    ]
    |> Enum.join(@crlf)
  end

  # Build an SDP answer matching the negotiated codec.
  defp build_sdp_answer(local_ip, rtp_port, codec) do
    session_id = System.system_time(:second)
    {pt, rtpmap} = codec_to_sdp(codec)

    [
      "v=0",
      "o=burble #{session_id} #{session_id} IN IP4 #{local_ip}",
      "s=Burble Bridge",
      "c=IN IP4 #{local_ip}",
      "t=0 0",
      "m=audio #{rtp_port} RTP/AVP #{pt} #{@pt_dtmf}",
      "a=rtpmap:#{pt} #{rtpmap}",
      "a=rtpmap:#{@pt_dtmf} telephone-event/8000",
      "a=fmtp:#{@pt_dtmf} 0-16",
      "a=ptime:20",
      "a=sendrecv"
    ]
    |> Enum.join(@crlf)
  end

  # Parse an SDP body to extract remote IP, port, and preferred codec.
  defp parse_sdp(body) when is_binary(body) and byte_size(body) > 0 do
    lines = String.split(body, ~r/[\r\n]+/)

    # Extract connection address (c= line).
    remote_ip =
      lines
      |> Enum.find_value(fn line ->
        case Regex.run(~r/^c=IN IP4 (.+)$/, line) do
          [_, ip] -> String.trim(ip)
          _ -> nil
        end
      end)

    # Extract media port (m= line).
    {remote_port, payload_types} =
      lines
      |> Enum.find_value({nil, []}, fn line ->
        case Regex.run(~r/^m=audio (\d+) RTP\/AVP (.+)$/, line) do
          [_, port, pts] ->
            pt_list =
              pts
              |> String.split()
              |> Enum.map(&String.to_integer/1)

            {String.to_integer(port), pt_list}

          _ ->
            nil
        end
      end)

    # Require Opus — refuse G.711-only or codec-less offers.
    # Returns {:error, :no_opus} when the peer offers no Opus payload type,
    # so the INVITE handler can reply 488 Not Acceptable Here.
    codec =
      if @pt_opus in payload_types do
        :opus
      else
        :no_opus
      end

    {remote_ip, remote_port, codec}
  end

  defp parse_sdp(_), do: {nil, nil, :no_opus}

  # Convert a codec atom to SDP rtpmap string.
  defp codec_to_sdp(:opus), do: {@pt_opus, "opus/48000/2"}

  # Opus-only after Phase-1 SDP negotiation. A non-Opus codec here means the
  # negotiation logic regressed — fail loudly rather than silently emit G.711
  # (mirrors the send_rtp_audio guard).
  defp codec_to_sdp(other) do
    raise "[SIPBridge] Unexpected codec #{inspect(other)} when building SDP — Opus-only after negotiation"
  end

  # ---------------------------------------------------------------------------
  # Private: RTP media handling
  # ---------------------------------------------------------------------------

  # Handle an incoming RTP audio packet.
  defp handle_rtp_packet(packet, %{call: %{state: :active}} = state) when byte_size(packet) > @rtp_header_size do
    <<_flags::8, pt::8, _seq::16-big, _ts::32-big, _ssrc::32-big, audio_payload::binary>> = packet

    # Decode audio based on negotiated codec.
    pcm_samples =
      case pt do
        @pt_pcmu -> decode_ulaw(audio_payload)
        @pt_pcma -> decode_alaw(audio_payload)
        @pt_opus -> audio_payload  # Opus frame — relay as-is to Burble.
        @pt_dtmf -> handle_dtmf_event(audio_payload, state); nil
        _ -> nil
      end

    if pcm_samples do
      # Broadcast to the Burble room.
      Phoenix.PubSub.broadcast(
        Burble.PubSub,
        "room:#{state.config.room_id}",
        {:sip_audio, %{
          audio: pcm_samples,
          codec: state.call.negotiated_codec,
          bridge: true
        }}
      )
    end

    state
  end

  defp handle_rtp_packet(_packet, state), do: state

  # Send an RTP audio frame to the SIP endpoint.
  defp send_rtp_audio(opus_frame, %{call: call, rtp_socket: socket} = state)
       when not is_nil(socket) and not is_nil(call) do
    # Only :opus is reachable here after Opus-only SDP negotiation.
    # Any other codec atom means codec selection logic has a bug — raise loudly
    # rather than sending silence or corrupted audio on the wire.
    {pt, audio_payload} =
      case call.negotiated_codec do
        :opus ->
          # Opus is native — send as-is.
          {@pt_opus, opus_frame}

        other ->
          raise "[SIPBridge] Unexpected codec #{inspect(other)} after Opus-only negotiation — " <>
                  "codec selection bug; no transcoder is available"
      end

    # Build and send RTP packet.
    rtp_header = <<
      0x80::8,
      pt::8,
      call.rtp_sequence::16-big,
      call.rtp_timestamp::32-big,
      call.rtp_ssrc::32-big
    >>

    packet = rtp_header <> audio_payload

    remote_ip_charlist = String.to_charlist(call.remote_rtp_ip)
    :gen_udp.send(socket, remote_ip_charlist, call.remote_rtp_port, packet)

    # Advance sequence and timestamp: Opus at 48kHz, 20ms = 960 samples/frame.
    new_call = %{
      call
      | rtp_sequence: rem(call.rtp_sequence + 1, 0x10000),
        rtp_timestamp: rem(call.rtp_timestamp + 960, 0x100000000)
    }

    %{state | call: new_call}
  end

  defp send_rtp_audio(_opus_frame, state), do: state

  # Send a DTMF digit via RFC 2833 telephone-event RTP packets.
  defp send_rtp_dtmf(digit, %{call: call, rtp_socket: socket} = _state)
       when not is_nil(socket) and not is_nil(call) do
    # Convert digit character to event code.
    event_code = dtmf_char_to_code(digit)

    if event_code do
      # RFC 2833 telephone-event payload:
      # <<event::8, end_flag::1, reserved::1, volume::6, duration::16>>
      # Send 3 packets: start, middle, end (each with increasing duration).
      durations = [160, 320, 320]

      Enum.each(Enum.with_index(durations), fn {duration, idx} ->
        end_flag = if idx == 2, do: 1, else: 0

        dtmf_payload = <<
          event_code::8,
          end_flag::1,
          0::1,
          10::6,
          duration::16-big
        >>

        rtp_header = <<
          0x80::8,
          @pt_dtmf::8,
          (call.rtp_sequence + idx)::16-big,
          call.rtp_timestamp::32-big,
          call.rtp_ssrc::32-big
        >>

        packet = rtp_header <> dtmf_payload
        remote_ip_charlist = String.to_charlist(call.remote_rtp_ip)
        :gen_udp.send(socket, remote_ip_charlist, call.remote_rtp_port, packet)
      end)
    end
  end

  defp send_rtp_dtmf(_digit, _state), do: :ok

  # Handle an incoming DTMF event from RTP.
  defp handle_dtmf_event(<<event::8, end_flag::1, _reserved::1, _volume::6, _duration::16-big>>, state) do
    if end_flag == 1 do
      digit = dtmf_code_to_char(event)

      if digit do
        Phoenix.PubSub.broadcast(
          Burble.PubSub,
          "room:#{state.config.room_id}",
          {:sip_dtmf, %{digit: digit, bridge: true}}
        )
      end
    end
  end

  defp handle_dtmf_event(_payload, _state), do: :ok

  # ---------------------------------------------------------------------------
  # Private: G.711 µ-law (PCMU) codec
  # ---------------------------------------------------------------------------

  # Encode PCM samples (list of floats -1.0..1.0) to G.711 µ-law bytes.
  defp encode_ulaw(pcm_samples) when is_list(pcm_samples) do
    pcm_samples
    |> Enum.map(&encode_ulaw_sample/1)
    |> :binary.list_to_bin()
  end

  defp encode_ulaw(pcm_binary) when is_binary(pcm_binary) do
    # If already binary (raw PCM), assume 16-bit signed LE samples.
    for <<sample::little-signed-16 <- pcm_binary>> do
      encode_ulaw_sample(sample / 32768.0)
    end
    |> :binary.list_to_bin()
  end

  # Encode a single PCM float sample (-1.0..1.0) to a µ-law byte.
  defp encode_ulaw_sample(sample) do
    # Convert float to 16-bit signed integer.
    pcm16 = trunc(max(-1.0, min(1.0, sample)) * 32767.0)

    # µ-law compression algorithm (ITU-T G.711).
    sign = if pcm16 < 0, do: 0x80, else: 0x00
    magnitude = abs(pcm16)
    magnitude = min(magnitude + @ulaw_bias, @ulaw_clip)

    # Find the segment (exponent) and quantisation step.
    {exponent, mantissa} = ulaw_encode_segment(magnitude)

    # Combine sign, exponent, mantissa and complement.
    ulaw_byte = Bitwise.bxor(sign ||| (exponent <<< 4) ||| mantissa, 0xFF)
    ulaw_byte
  end

  # Find µ-law segment and mantissa for a given magnitude.
  defp ulaw_encode_segment(magnitude) do
    # Segment boundaries for µ-law (8 segments).
    segments = [0x84, 0x104, 0x204, 0x404, 0x804, 0x1004, 0x2004, 0x4004]

    exponent =
      segments
      |> Enum.with_index()
      |> Enum.find_value(7, fn {threshold, idx} ->
        if magnitude < threshold, do: idx, else: nil
      end)

    # Compute mantissa: shift right by (exponent + 3), keep 4 bits.
    shift = exponent + 3
    mantissa = Bitwise.band(Bitwise.bsr(magnitude, shift), 0x0F)

    {exponent, mantissa}
  end

  # Decode G.711 µ-law bytes to PCM float samples.
  defp decode_ulaw(ulaw_bytes) do
    for <<byte::8 <- ulaw_bytes>> do
      decode_ulaw_byte(byte)
    end
  end

  # Decode a single µ-law byte to a PCM float.
  defp decode_ulaw_byte(byte) do
    # Complement and extract fields.
    byte = Bitwise.bxor(byte, 0xFF)
    sign = Bitwise.band(byte, 0x80)
    exponent = Bitwise.band(Bitwise.bsr(byte, 4), 0x07)
    mantissa = Bitwise.band(byte, 0x0F)

    # Reconstruct magnitude.
    magnitude = Bitwise.bsl(mantissa, exponent + 3) + Bitwise.bsl(@ulaw_bias, exponent) - @ulaw_bias

    # Apply sign and normalise to float.
    pcm16 = if sign != 0, do: -magnitude, else: magnitude
    pcm16 / 32768.0
  end

  # ---------------------------------------------------------------------------
  # Private: G.711 A-law (PCMA) codec
  # ---------------------------------------------------------------------------

  # Encode PCM samples to G.711 A-law bytes.
  defp encode_alaw(pcm_samples) when is_list(pcm_samples) do
    pcm_samples
    |> Enum.map(&encode_alaw_sample/1)
    |> :binary.list_to_bin()
  end

  defp encode_alaw(pcm_binary) when is_binary(pcm_binary) do
    for <<sample::little-signed-16 <- pcm_binary>> do
      encode_alaw_sample(sample / 32768.0)
    end
    |> :binary.list_to_bin()
  end

  # Encode a single PCM float to an A-law byte.
  defp encode_alaw_sample(sample) do
    pcm16 = trunc(max(-1.0, min(1.0, sample)) * 32767.0)
    sign = if pcm16 < 0, do: 0x80, else: 0x00
    magnitude = abs(pcm16)

    {exponent, mantissa} =
      cond do
        magnitude < 256 ->
          # Linear segment.
          {0, Bitwise.band(Bitwise.bsr(magnitude, 4), 0x0F)}

        true ->
          # Logarithmic segments 1-7.
          exp =
            cond do
              magnitude < 512 -> 1
              magnitude < 1024 -> 2
              magnitude < 2048 -> 3
              magnitude < 4096 -> 4
              magnitude < 8192 -> 5
              magnitude < 16384 -> 6
              true -> 7
            end

          mant = Bitwise.band(Bitwise.bsr(magnitude, exp + 3), 0x0F)
          {exp, mant}
      end

    # A-law: sign, exponent, mantissa, with even-bit inversion (XOR 0x55).
    Bitwise.bxor(sign ||| (exponent <<< 4) ||| mantissa, 0x55)
  end

  # Decode G.711 A-law bytes to PCM float samples.
  defp decode_alaw(alaw_bytes) do
    for <<byte::8 <- alaw_bytes>> do
      decode_alaw_byte(byte)
    end
  end

  # Decode a single A-law byte to a PCM float.
  defp decode_alaw_byte(byte) do
    byte = Bitwise.bxor(byte, 0x55)
    sign = Bitwise.band(byte, 0x80)
    exponent = Bitwise.band(Bitwise.bsr(byte, 4), 0x07)
    mantissa = Bitwise.band(byte, 0x0F)

    magnitude =
      if exponent == 0 do
        # Linear segment.
        Bitwise.bsl(mantissa, 4) + 8
      else
        # Logarithmic segment.
        Bitwise.bsl(Bitwise.bor(mantissa, 0x10), exponent + 3)
      end

    pcm16 = if sign != 0, do: -magnitude, else: magnitude
    pcm16 / 32768.0
  end

  # ---------------------------------------------------------------------------
  # Private: SIP message construction
  # ---------------------------------------------------------------------------

  # Build a SIP message from method, headers, and optional body.
  defp build_sip_message(method, headers, body \\ "") do
    request_uri = headers[:request_uri] || headers["request_uri"]

    start_line = "#{method} #{request_uri} SIP/2.0"

    # Build headers in standard SIP order.
    header_lines =
      [
        {"Via", headers[:via] || headers["via"]},
        {"Max-Forwards", headers[:max_forwards] || headers["max_forwards"]},
        {"From", headers[:from] || headers["from"]},
        {"To", headers[:to] || headers["to"]},
        {"Call-ID", headers[:call_id] || headers["call_id"]},
        {"CSeq", headers[:cseq] || headers["cseq"]},
        {"Contact", headers[:contact] || headers["contact"]},
        {"Content-Type", headers[:content_type] || headers["content_type"]},
        {"Authorization", headers[:authorization] || headers["authorization"]},
        {"Expires", headers[:expires] || headers["expires"]},
        {"User-Agent", "Burble Bridge/1.0"},
        {"Content-Length", headers[:content_length] || headers["content_length"] || "#{byte_size(body)}"}
      ]
      |> Enum.filter(fn {_k, v} -> v != nil end)
      |> Enum.map(fn {k, v} -> "#{k}: #{v}" end)

    Enum.join([start_line | header_lines], @crlf) <> @crlf <> @crlf <> body
  end

  # Send a SIP response to a request.
  defp send_sip_response(socket, status_code, reason, request_headers, src_ip, src_port, state) do
    send_sip_response_with_body(socket, status_code, reason, request_headers, nil, "", src_ip, src_port, state)
  end

  # Send a SIP response with an optional body.
  defp send_sip_response_with_body(socket, status_code, reason, request_headers, content_type, body, src_ip, src_port, state) do
    via = request_headers["via"] || ""
    from = request_headers["from"] || ""
    to = request_headers["to"] || ""
    call_id = request_headers["call-id"] || ""
    cseq = request_headers["cseq"] || ""

    response_lines = [
      "SIP/2.0 #{status_code} #{reason}",
      "Via: #{via}",
      "From: #{from}",
      "To: #{to}",
      "Call-ID: #{call_id}",
      "CSeq: #{cseq}",
      "Contact: <sip:#{state.config.sip_user}@#{state.config.local_ip}>",
      "User-Agent: Burble Bridge/1.0"
    ]

    response_lines =
      if content_type do
        response_lines ++ ["Content-Type: #{content_type}"]
      else
        response_lines
      end

    response_lines = response_lines ++ ["Content-Length: #{byte_size(body)}"]
    response = Enum.join(response_lines, @crlf) <> @crlf <> @crlf <> body

    send_sip(socket, response, src_ip, src_port)
  end

  # Send a raw SIP message over UDP.
  defp send_sip(socket, message, host, port) when is_binary(host) do
    send_sip(socket, message, String.to_charlist(host), port)
  end

  defp send_sip(socket, message, host, port) when is_list(host) do
    case :inet.getaddr(host, :inet) do
      {:ok, ip} -> :gen_udp.send(socket, ip, port, message)
      {:error, reason} -> Logger.error("[SIPBridge] DNS resolution failed: #{inspect(reason)}")
    end
  end

  defp send_sip(socket, message, host, port) when is_tuple(host) do
    :gen_udp.send(socket, host, port, message)
  end

  # ---------------------------------------------------------------------------
  # Private: Utility functions
  # ---------------------------------------------------------------------------

  # Registry via() name for process lookup.
  defp via(room_id) do
    {:via, Registry, {Burble.RoomRegistry, {:sip_bridge, room_id}}}
  end

  # Generate a unique SIP Call-ID.
  defp generate_call_id do
    "#{:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)}@burble"
  end

  # Generate a SIP tag (From/To header).
  defp generate_tag do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  # Generate a SIP Via branch parameter (must start with "z9hG4bK" per RFC 3261).
  defp generate_branch do
    "z9hG4bK-#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"
  end

  # Extract the tag parameter from a From/To header value.
  defp extract_tag(header_value) do
    case Regex.run(~r/;tag=([^\s;>]+)/, header_value) do
      [_, tag] -> tag
      _ -> nil
    end
  end

  # Extract the SIP URI from a From/To header value.
  defp extract_uri(header_value) do
    case Regex.run(~r/<([^>]+)>/, header_value) do
      [_, uri] -> uri
      _ -> header_value
    end
  end

  # Extract a parameter from a WWW-Authenticate/Proxy-Authenticate header.
  defp extract_auth_param(header, param_name) do
    case Regex.run(~r/#{param_name}="([^"]+)"/, header) do
      [_, value] -> value
      _ -> nil
    end
  end

  # Detect local IP address by opening a UDP socket to a public address.
  defp detect_local_ip do
    case :gen_udp.open(0, [:binary]) do
      {:ok, socket} ->
        # Connect to a public DNS server to determine our outbound IP.
        :gen_udp.connect(socket, ~c"8.8.8.8", 53)

        case :inet.sockname(socket) do
          {:ok, {ip, _port}} ->
            :gen_udp.close(socket)
            :inet.ntoa(ip) |> List.to_string()

          _ ->
            :gen_udp.close(socket)
            "127.0.0.1"
        end

      _ ->
        "127.0.0.1"
    end
  end

  # Convert DTMF digit character to RFC 2833 event code.
  defp dtmf_char_to_code(digit) do
    case digit do
      "0" -> 0; "1" -> 1; "2" -> 2; "3" -> 3; "4" -> 4
      "5" -> 5; "6" -> 6; "7" -> 7; "8" -> 8; "9" -> 9
      "*" -> 10; "#" -> 11; "A" -> 12; "B" -> 13; "C" -> 14; "D" -> 15
      _ -> nil
    end
  end

  # Convert RFC 2833 event code to DTMF digit character.
  defp dtmf_code_to_char(code) do
    case code do
      0 -> "0"; 1 -> "1"; 2 -> "2"; 3 -> "3"; 4 -> "4"
      5 -> "5"; 6 -> "6"; 7 -> "7"; 8 -> "8"; 9 -> "9"
      10 -> "*"; 11 -> "#"; 12 -> "A"; 13 -> "B"; 14 -> "C"; 15 -> "D"
      _ -> nil
    end
  end
end
