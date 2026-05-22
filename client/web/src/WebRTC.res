// SPDX-License-Identifier: MPL-2.0
//
// WebRTC.res — Low-level WebRTC bindings and helpers.

module RTC = {
  type pc
  type dc
  type stream
  type track
  type sdp = {
    @as("type") type_: string,
    sdp: string,
  }
  type iceCandidate = {
    candidate: string,
    sdpMid: string,
    sdpMLineIndex: int,
  }

  type iceServer = {urls: array<string>}
  type config = {iceServers: array<iceServer>}

  @new external createPC: config => pc = "RTCPeerConnection"
  @send external createOffer: (pc, 'opts) => promise<sdp> = "createOffer"
  @send external createAnswer: (pc, 'opts) => promise<sdp> = "createAnswer"
  @send external setLocalDescription: (pc, sdp) => promise<unit> = "setLocalDescription"
  @send external setRemoteDescription: (pc, sdp) => promise<unit> = "setRemoteDescription"
  @send external addTrack: (pc, track, stream) => unit = "addTrack"
  @send external createDataChannel: (pc, string, 'opts) => dc = "createDataChannel"
  @send external addIceCandidate: (pc, iceCandidate) => promise<unit> = "addIceCandidate"
  @send external close: pc => unit = "close"

  @get external getTracks: stream => array<track> = "getTracks"
  @set external setOnTrack: (pc, 'ev => unit) => unit = "ontrack"
  @set external setOnIceConnectionStateChange: (pc, unit => unit) => unit = "oniceconnectionstatechange"
  @set external setOnIceGatheringStateChange: (pc, unit => unit) => unit = "onicegatheringstatechange"
  @set external setOnDataChannel: (pc, 'ev => unit) => unit = "ondatachannel"
  @get external getIceConnectionState: pc => string = "iceConnectionState"
  @get external getIceGatheringState: pc => string = "iceGatheringState"
  }

  module Media = {
  type constraints = {audio: bool}
  @val external navigator: 'nav = "navigator"
  @get external mediaDevices: 'nav => 'md = "mediaDevices"
  @send external getUserMedia: ('md, constraints) => promise<RTC.stream> = "getUserMedia"
  @send external stop: RTC.track => unit = "stop"
  }

  let default_ice_servers = [
  {RTC.urls: ["stun:stun.l.google.com:19302"]},
  {RTC.urls: ["stun:stun.cloudflare.com:3478"]},
  {RTC.urls: ["stun:stun1.l.google.com:19302"]},
  ]

  let createPC = () => RTC.createPC({iceServers: default_ice_servers})

  let waitForIceGathering = (pc) => {
    if pc->RTC.getIceGatheringState == "complete" {
      Promise.resolve()
    } else {
      Promise.make((resolve, _reject) => {
        pc->RTC.setOnIceGatheringStateChange(() => {
          if pc->RTC.getIceGatheringState == "complete" {
            resolve()
          }
        })
        // Safety timeout
        let _ = setTimeout(() => resolve(), 5000)
      })
    }
  }
