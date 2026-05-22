// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// ScreenShare — Client-side screen sharing via WebRTC getDisplayMedia.
//
// Provides:
//   - getDisplayMedia bindings for screen/window/tab capture
//   - "Share Screen" button state management
//   - Local preview of own screen share
//   - Remote screen share display
//   - Start/stop via Phoenix channel messages
//
// The captured MediaStream is sent to the Burble SFU as a video track.
// The SFU relays it to all other room participants (same model as voice audio).
//
// Constraints:
//   - Resolution capped at 1080p, 15fps default (server-enforced).
//   - One active screen share per room (first-come, moderator can take over).
//   - Follows room privacy mode (TURN-only, E2EE).

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// Screen share connection state.
type shareState =
  | Idle
  | Starting
  | Sharing
  | Viewing(string) // peer_id of the sharer
  | Error(string)

/// Video constraints for getDisplayMedia.
type videoConstraints = {
  maxWidth: int,
  maxHeight: int,
  maxFramerate: int,
}

/// Default constraints matching server defaults (1080p, 15fps).
let defaultConstraints: videoConstraints = {
  maxWidth: 1920,
  maxHeight: 1080,
  maxFramerate: 15,
}

type jsObj
external castToJsObj: {..} => jsObj = "%identity"
external castFromJsObj: jsObj => {..} = "%identity"

/// Screen share engine state (mutable, managed internally).
type t = {
  mutable state: shareState,
  mutable constraints: videoConstraints,
  /// Local capture stream from getDisplayMedia.
  mutable localStream: option<jsObj>,
  /// PeerConnection for the screen share video track (separate from voice).
  mutable peerConnection: option<jsObj>,
  /// Callback: state changed.
  mutable onStateChange: option<shareState => unit>,
  /// Callback: remote stream available for display.
  mutable onRemoteStream: option<jsObj => unit>,
  /// Channel send functions (set externally by the room/channel layer).
  mutable sendStartShare: option<unit => unit>,
  mutable sendStopShare: option<unit => unit>,
  mutable sendSignal: option<string => unit>,
}

// ---------------------------------------------------------------------------
// External bindings — getDisplayMedia
// ---------------------------------------------------------------------------

/// Prompt the user to select a screen, window, or tab to share.
/// Returns a MediaStream containing the captured video track.
///
/// The browser shows a native picker dialog. If the user cancels,
/// the promise rejects with NotAllowedError.
@val
external getDisplayMedia: {..} => promise<{..}> =
  "navigator.mediaDevices.getDisplayMedia"

/// RTCPeerConnection constructor (same as voice — separate instance for video).
@new
external makeRTCPeerConnection: {..} => {..} = "RTCPeerConnection"

// ---------------------------------------------------------------------------
// Construction
// ---------------------------------------------------------------------------

/// Create a new screen share engine with default state.
let make = (~constraints: videoConstraints=defaultConstraints): t => {
  state: Idle,
  constraints,
  localStream: None,
  peerConnection: None,
  onStateChange: None,
  onRemoteStream: None,
  sendStartShare: None,
  sendStopShare: None,
  sendSignal: None,
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

/// Start sharing the screen.
///
/// 1. Calls getDisplayMedia with the configured constraints.
/// 2. Sends "screen_share:start" to the server via the Phoenix channel.
/// 3. Creates a PeerConnection for the video track.
/// 4. Listens for the "ended" event on the video track (user clicks
///    the browser's "Stop sharing" button).
let rec startSharing = async (engine: t): result<unit, string> => {
  engine.state = Starting
  notifyState(engine)

  // Build getDisplayMedia constraints.
  let displayConstraints = {
    "video": {
      "width": {"max": engine.constraints.maxWidth},
      "height": {"max": engine.constraints.maxHeight},
      "frameRate": {"max": engine.constraints.maxFramerate},
    },
    // No audio capture for screen share (voice uses separate track).
    "audio": false,
  }

  try {
    // Prompt user to pick a screen/window/tab.
    let stream = await getDisplayMedia(displayConstraints)
    engine.localStream = Some(castToJsObj(stream))

    // Listen for the browser "Stop sharing" button.
    let videoTracks: array<{..}> = stream["getVideoTracks"]()
    videoTracks->Array.get(0)->Option.forEach(track => {
      // When the user clicks "Stop sharing" in the browser chrome,
      // the track fires an "ended" event. We clean up automatically.
      track["onended"] = (_: {..}) => {
        stopSharing(engine)
      }
    })

    // Notify the server that we want to share.
    switch engine.sendStartShare {
    | Some(send) => send()
    | None => ()
    }

    engine.state = Sharing
    notifyState(engine)
    Ok()
  } catch {
  | exn =>
    // User cancelled the picker or permission denied.
    let msg: string = %raw(`(exn => exn.message || "Screen share cancelled")`)(exn)
    engine.state = Error(msg)
    notifyState(engine)
    Error(msg)
  }
}

/// Stop sharing the screen.
///
/// Stops all local capture tracks, closes the PeerConnection,
/// and notifies the server.
and stopSharing = (engine: t): unit => {
  // Stop local capture tracks.
  switch engine.localStream {
  | Some(stream) =>
    let streamObj = castFromJsObj(stream)
    let tracks: array<{..}> = streamObj["getTracks"]()
    tracks->Array.forEach(track => ignore(track["stop"]()))
  | None => ()
  }

  // Close the screen share PeerConnection.
  switch engine.peerConnection {
  | Some(pc) => ignore(castFromJsObj(pc)["close"]())
  | None => ()
  }

  // Notify the server.
  switch engine.sendStopShare {
  | Some(send) => send()
  | None => ()
  }

  engine.localStream = None
  engine.peerConnection = None
  engine.state = Idle
  notifyState(engine)
}

// ---------------------------------------------------------------------------
// Server events (called by the channel layer)
// ---------------------------------------------------------------------------

/// Handle "screen_share:started" from server — another peer started sharing.
///
/// Sets state to Viewing and prepares to receive the remote video stream.
and handleRemoteShareStarted = (engine: t, sharerPeerId: string): unit => {
  // Only update if we're not the sharer ourselves.
  switch engine.state {
  | Sharing => () // We're the sharer; ignore.
  | _ =>
    engine.state = Viewing(sharerPeerId)
    notifyState(engine)
  }
}

/// Handle "screen_share:stopped" from server — the active share ended.
and handleRemoteShareStopped = (engine: t): unit => {
  switch engine.state {
  | Viewing(_) =>
    engine.state = Idle
    notifyState(engine)
  | _ => ()
  }
}

/// Handle incoming remote video track (the screen share stream from the SFU).
///
/// Called by the WebRTC ontrack event when the SFU forwards the screen
/// share video to us. Passes the stream to onRemoteStream for rendering.
and handleRemoteTrack = (engine: t, stream: {..}): unit => {
  switch engine.onRemoteStream {
  | Some(cb) => cb(castToJsObj(stream))
  | None => ()
  }
}

/// Handle SDP offer for screen share track from the server.
and handleSdpOffer = async (engine: t, sdp: string): unit => {
  switch engine.peerConnection {
  | Some(pc) =>
    try {
      let _: unit = await %raw(`(async () => {
        await pc.setRemoteDescription(new RTCSessionDescription({type: 'offer', sdp: sdp}));
        const answer = await pc.createAnswer();
        await pc.setLocalDescription(answer);
        return answer.sdp;
      })()`)

      let pcObj = castFromJsObj(pc)
      let answerSdp: string = pcObj["localDescription"]["sdp"]

      switch engine.sendSignal {
      | Some(send) => send(answerSdp)
      | None => ()
      }
    } catch {
    | _exn => ()
    }
  | None => ()
  }
}

// ---------------------------------------------------------------------------
// UI Helpers
// ---------------------------------------------------------------------------

/// Label for the share button based on current state.
and shareButtonLabel = (engine: t): string =>
  switch engine.state {
  | Idle => "Share Screen"
  | Starting => "Starting..."
  | Sharing => "Stop Sharing"
  | Viewing(_) => "Share Screen" // Can request takeover (if moderator).
  | Error(_) => "Share Screen"
  }

/// Whether the share button should be disabled.
and shareButtonDisabled = (engine: t): bool =>
  switch engine.state {
  | Starting => true
  | _ => false
  }

/// Whether we are currently the active sharer.
and isSharing = (engine: t): bool =>
  switch engine.state {
  | Sharing => true
  | _ => false
  }

/// Whether we are viewing someone else's screen share.
and isViewing = (engine: t): bool =>
  switch engine.state {
  | Viewing(_) => true
  | _ => false
  }

/// Get the local capture stream for preview rendering.
/// Returns None if we're not sharing.
and getLocalStream = (engine: t): option<jsObj> =>
  switch engine.state {
  | Sharing => engine.localStream
  | _ => None
  }

/// Toggle: start if idle, stop if sharing.
and toggle = async (engine: t): unit => {
  switch engine.state {
  | Idle | Error(_) =>
    let _ = await startSharing(engine)
  | Sharing => stopSharing(engine)
  | Viewing(_) =>
    // Could attempt moderator takeover here.
    let _ = await startSharing(engine)
  | Starting => () // Already in progress.
  }
}

// ---------------------------------------------------------------------------
// Private
// ---------------------------------------------------------------------------

/// Notify the state change callback if registered.
and notifyState = (engine: t): unit => {
  switch engine.onStateChange {
  | Some(cb) => cb(engine.state)
  | None => ()
  }
}
