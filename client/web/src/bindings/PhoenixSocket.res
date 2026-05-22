// SPDX-License-Identifier: MPL-2.0
//
// PhoenixSocket — ReScript bindings for Phoenix WebSocket channels.
//
// Connects to Burble's Phoenix backend for:
//   - Room signaling (join/leave, voice state, WebRTC SDP/ICE)
//   - Presence tracking (who's in the room)
//   - Text messages (NNTPS-backed channels)
//   - Real-time events (moderation, room state changes)
//
// Uses the Phoenix JS client library pattern:
//   Socket → Channel → push/on events

/// Phoenix Socket instance (opaque JS object).
type socket

/// Phoenix Channel instance.
type channel

/// Phoenix Presence instance.
type presence

/// Channel push response.
type pushResponse = {
  status: string,
  response: JSON.t,
}

// ── Socket ──

/// Create a new Phoenix Socket connection.
@new @module("phoenix")
external makeSocket: (string, {"params": {"token": string}}) => socket = "Socket"

/// Connect the socket to the server.
@send external connect: socket => unit = "connect"

/// Disconnect the socket.
@send external disconnect: socket => unit = "disconnect"

/// Join a channel on the socket.
@send external channel: (socket, string, {..}) => channel = "channel"

// ── Channel ──

/// Join a channel. Returns a push that resolves with the channel state.
@send external join: channel => pushResponse = "join"

/// Leave a channel.
@send external leave: channel => unit = "leave"

/// Push an event to the channel.
@send external push: (channel, string, {..}) => unit = "push"

/// Listen for an event on the channel.
@send external on: (channel, string, JSON.t => unit) => unit = "on"

/// Remove an event listener.
@send external off: (channel, string) => unit = "off"

// ── Presence ──

/// Create a Presence tracker for a channel.
@new @module("phoenix")
external makePresence: channel => presence = "Presence"

/// Sync presence state from a "presence_state" event.
@send external syncState: (presence, JSON.t) => unit = "syncState"

/// Sync presence diff from a "presence_diff" event.
@send external syncDiff: (presence, JSON.t) => unit = "syncDiff"

/// List all presences.
@send external list: presence => array<JSON.t> = "list"

// ── Helpers ──

/// Connect to the Burble server and return a socket.
let connectToServer = (~url: string, ~token: string): socket => {
  let sock = makeSocket(url, {"params": {"token": token}})
  connect(sock)
  sock
}

/// Join a room channel on the socket.
let joinRoom = (sock: socket, ~roomId: string, ~displayName: string): channel => {
  let ch = channel(sock, `room:${roomId}`, {"display_name": displayName})
  let _ = join(ch)
  ch
}

/// Send a voice state update.
let sendVoiceState = (ch: channel, ~state: string): unit => {
  push(ch, "voice_state", {"state": state})
}

/// Send a text message.
let sendText = (ch: channel, ~body: string): unit => {
  push(ch, "text", {"body": body})
}

/// Send a WebRTC signaling message.
let sendSignal = (ch: channel, ~to: string, ~signalType: string, ~payload: JSON.t): unit => {
  push(ch, "signal", {"to": to, "type": signalType, "payload": payload})
}

/// Send a whisper request (directed audio).
let sendWhisper = (ch: channel, ~to: string): unit => {
  push(ch, "whisper", {"to": to})
}
