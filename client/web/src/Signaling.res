// SPDX-License-Identifier: MPL-2.0
//
// Signaling.res — Relay and WebSocket signaling.

open WebRTC

module Relay = {
  let putOffer = (relay_url, room_id, sdp) => {
    let url = relay_url ++ "/room/" ++ room_id ++ "/offer"
    %raw(`fetch(url, {
      method: "PUT",
      body: JSON.stringify(sdp)
    })`)
  }

  let getOffer = (relay_url, room_id) => {
    let url = relay_url ++ "/room/" ++ room_id ++ "/offer"
    %raw(`fetch(url).then(res => res.json())`)
  }

  let putAnswer = (relay_url, room_id, sdp) => {
    let url = relay_url ++ "/room/" ++ room_id ++ "/answer"
    %raw(`fetch(url, {
      method: "PUT",
      body: JSON.stringify(sdp)
    })`)
  }

  let getAnswer = (relay_url, room_id) => {
    let url = relay_url ++ "/room/" ++ room_id ++ "/answer"
    %raw(`fetch(url).then(res => res.json())`)
  }
}

module Phoenix = {
  type socket
  type channel

  @new @module("phoenix")
  external createSocket: (string, 'opts) => socket = "Socket"
  @send external connectSocket: socket => unit = "connect"
  @send external channel: (socket, string, 'params) => channel = "channel"
  @send external joinChannel: channel => 'push = "join"
  @send external onChannel: (channel, string, 'msg => unit) => unit = "on"
  @send external pushChannel: (channel, string, 'payload) => 'push = "push"
}
