// SPDX-License-Identifier: MPL-2.0
//
// BurbleSignaling — Phoenix WebSocket signaling for BurbleClient.
//
// Handles the signaling plane: connects to the Burble server via
// Phoenix Channels, manages room channel subscriptions, and relays
// WebRTC signaling messages (SDP offers/answers, ICE candidates).
//
// Both IDApTIK and PanLL already have PhoenixSocket implementations.
// This module provides a STANDALONE signaling layer so consumers
// don't need to share their Phoenix socket — Burble gets its own
// connection on the /voice path.
//
// Protocol:
//   Client → Server: join "room:<id>", voice_state, signal, text
//   Server → Client: presence_state, voice_state_changed, signal, text

/// Signaling event types received from the server.
type serverEvent =
  | PresenceState(JSON.t)
  | PresenceDiff({joins: JSON.t, leaves: JSON.t})
  | VoiceStateChanged({userId: string, voiceState: string})
  | Signal({from: string, toSelf: string, signalType: string, payload: JSON.t})
  | TextMessage({userId: string, displayName: string, body: string, sentAt: string})
  | RoomState(JSON.t)
  | Error(string)

/// Signaling callbacks.
type callbacks = {
  onEvent: serverEvent => unit,
  onJoined: JSON.t => unit,
  onError: string => unit,
}

/// Signaling connection state.
type signalingState = {
  mutable socket: option<JSON.t>,
  mutable channel: option<JSON.t>,
  mutable connected: bool,
  mutable roomId: option<string>,
  serverUrl: string,
  callbacks: callbacks,
}

// ---------------------------------------------------------------------------
// External: Phoenix JS client bindings
// ---------------------------------------------------------------------------

/// Phoenix Socket constructor.
@new @module("phoenix") external makeSocket: (string, {..}) => JSON.t = "Socket"

// ---------------------------------------------------------------------------
// External: property access and method call helpers for opaque JS objects
// ---------------------------------------------------------------------------

/// Call a no-arg method on a JSON.t value (e.g. socket.connect()).
@send external callMethod0: (JSON.t, @as(json`undefined`) _, string) => unit = "call"

/// Generic: call connect() on a socket.
@send external socketConnect: JSON.t => unit = "connect"

/// Generic: call disconnect() on a socket.
@send external socketDisconnect: JSON.t => unit = "disconnect"

/// Get a channel from a socket.
@send external socketChannel: (JSON.t, string, {..}) => JSON.t = "channel"

/// Register an event handler on a channel.
@send external channelOn: (JSON.t, string, JSON.t => unit) => unit = "on"

/// Join a channel, returns a push object.
@send external channelJoin: JSON.t => JSON.t = "join"

/// Leave a channel.
@send external channelLeave: JSON.t => unit = "leave"

/// Push a message to a channel.
@send external channelPush: (JSON.t, string, {..}) => unit = "push"

/// Register a callback on a push result.
@send external pushReceive: (JSON.t, string, JSON.t => unit) => JSON.t = "receive"

/// Get a string property from a JSON.t value.
@get_index external getStr: (JSON.t, string) => string = ""

/// Get a JSON.t property from a JSON.t value.
@get_index external getJson: (JSON.t, string) => JSON.t = ""

// ---------------------------------------------------------------------------
// Construction
// ---------------------------------------------------------------------------

/// Create a signaling connection.
let make = (serverUrl: string, callbacks: callbacks): signalingState => {
  {
    socket: None,
    channel: None,
    connected: false,
    roomId: None,
    serverUrl,
    callbacks,
  }
}

// ---------------------------------------------------------------------------
// Connection
// ---------------------------------------------------------------------------

/// Connect to the Burble server's voice WebSocket endpoint.
let connect = (state: signalingState, token: string): unit => {
  let socket = makeSocket(state.serverUrl, {"params": {"token": token}})
  socketConnect(socket)
  state.socket = Some(socket)
  state.connected = true
}

/// Connect as a guest (no auth token).
let connectGuest = (state: signalingState, displayName: string): unit => {
  let socket = makeSocket(state.serverUrl, {
    "params": {"guest": "true", "display_name": displayName},
  })
  socketConnect(socket)
  state.socket = Some(socket)
  state.connected = true
}

/// Disconnect from the server.
let disconnect = (state: signalingState): unit => {
  switch state.channel {
  | Some(ch) => channelLeave(ch)
  | None => ()
  }

  switch state.socket {
  | Some(s) => socketDisconnect(s)
  | None => ()
  }

  state.socket = None
  state.channel = None
  state.connected = false
  state.roomId = None
}

// ---------------------------------------------------------------------------
// Room channel
// ---------------------------------------------------------------------------

/// Join a room channel. Sets up event handlers for voice signaling.
let joinRoom = (state: signalingState, roomId: string, displayName: string): unit => {
  switch state.socket {
  | None => state.callbacks.onError("Not connected")
  | Some(socket) =>
    let topic = "room:" ++ roomId
    let channel = socketChannel(socket, topic, {"display_name": displayName})

    // Wire server event handlers.
    channelOn(channel, "presence_state", (payload) => {
      state.callbacks.onEvent(PresenceState(payload))
    })

    channelOn(channel, "voice_state_changed", (payload) => {
      state.callbacks.onEvent(VoiceStateChanged({
        userId: getStr(payload, "user_id"),
        voiceState: getStr(payload, "voice_state"),
      }))
    })

    channelOn(channel, "signal", (payload) => {
      state.callbacks.onEvent(Signal({
        from: getStr(payload, "from"),
        toSelf: getStr(payload, "to"),
        signalType: getStr(payload, "type"),
        payload: getJson(payload, "payload"),
      }))
    })

    channelOn(channel, "text", (payload) => {
      state.callbacks.onEvent(TextMessage({
        userId: getStr(payload, "user_id"),
        displayName: getStr(payload, "display_name"),
        body: getStr(payload, "body"),
        sentAt: getStr(payload, "sent_at"),
      }))
    })

    // Join the channel.
    let joinPush = channelJoin(channel)
    let _ = pushReceive(joinPush, "ok", (resp) => {
      state.roomId = Some(roomId)
      state.callbacks.onJoined(resp)
    })
    let _ = pushReceive(joinPush, "error", (resp) => {
      state.callbacks.onError("Join failed: " ++ JSON.stringify(resp))
    })

    state.channel = Some(channel)
  }
}

/// Leave the current room channel.
let leaveRoom = (state: signalingState): unit => {
  switch state.channel {
  | Some(ch) => channelLeave(ch)
  | None => ()
  }
  state.channel = None
  state.roomId = None
}

// ---------------------------------------------------------------------------
// Sending events
// ---------------------------------------------------------------------------

/// Send a voice state update.
let sendVoiceState = (state: signalingState, voiceState: string): unit => {
  switch state.channel {
  | Some(ch) => channelPush(ch, "voice_state", {"state": voiceState})
  | None => ()
  }
}

/// Send a WebRTC signaling message (SDP offer/answer, ICE candidate).
let sendSignal = (state: signalingState, to: string, signalType: string, payload: JSON.t): unit => {
  switch state.channel {
  | Some(ch) =>
    channelPush(ch, "signal", {"to": to, "type": signalType, "payload": payload})
  | None => ()
  }
}

/// Send a text message in the room.
let sendText = (state: signalingState, body: string): unit => {
  switch state.channel {
  | Some(ch) => channelPush(ch, "text", {"body": body})
  | None => ()
  }
}

/// Send a whisper (directed audio) request.
let sendWhisper = (state: signalingState, to: string): unit => {
  switch state.channel {
  | Some(ch) => channelPush(ch, "whisper", {"to": to})
  | None => ()
  }
}
