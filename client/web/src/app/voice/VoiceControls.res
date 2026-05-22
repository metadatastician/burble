// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// VoiceControls — Voice control bar UI state and DOM rendering.
//
// The persistent bottom bar showing:
//   - Mute button (toggle, shows mic icon state)
//   - Deafen button (toggle, shows headphone icon state)
//   - PTT indicator (shows when transmitting)
//   - Input mode selector (VAD / PTT toggle)
//   - Connection status indicator (with colour coding)
//   - Self-test button (links to /api/v1/diagnostics/self-test/quick)
//   - Settings gear (opens device selector)
//   - Current room name display
//   - Leave/disconnect button
//
// This module manages both state and DOM rendering. It constructs
// a control bar element that can be appended to any container.
// The bar auto-updates via requestAnimationFrame polling.
//
// Framework-agnostic: no React, no JSX, no TEA. Pure DOM manipulation
// matching the existing codebase pattern.

// ---------------------------------------------------------------------------
// Type definitions
// ---------------------------------------------------------------------------

/// Network quality indicator levels for the connection badge.
type networkQuality =
  | /// Latency < 50ms, no packet loss.
    Excellent
  | /// Latency < 100ms, minimal packet loss.
    Good
  | /// Latency < 200ms, some packet loss.
    Fair
  | /// Latency > 200ms or significant packet loss.
    Poor
  | /// Not connected to any voice room.
    Disconnected

/// Opaque JS object type — re-exported from VoiceEngine for consistency.
type jsObj = VoiceEngine.jsObj
let castToJsObj = VoiceEngine.castToJsObj
let castFromJsObj = VoiceEngine.castFromJsObj

/// Voice control bar state — mirrors VoiceEngine state for UI rendering.
type t = {
  /// Current mute/deafen state.
  mutable voiceState: VoiceEngine.voiceState,
  /// Current WebRTC connection lifecycle state.
  mutable connectionState: VoiceEngine.connectionState,
  /// Whether the local user is currently speaking.
  mutable isSpeaking: bool,
  /// Current RMS audio level (0.0 to 1.0) for the level meter.
  mutable audioLevel: float,
  /// Network quality estimate (derived from connection stats).
  mutable networkQuality: networkQuality,
  /// Current input mode (VAD or PTT).
  mutable inputMode: VoiceEngine.inputMode,
  /// Whether PTT key is currently held (for the PTT indicator).
  mutable pttActive: bool,
  /// Name of the currently connected room (empty if none).
  mutable roomName: string,
  /// Number of participants in the current room.
  mutable participantCount: int,
  /// Whether the settings panel is currently open.
  mutable settingsOpen: bool,
  /// The root DOM element for the control bar (created by render).
  mutable rootElement: option<jsObj>,
  /// Reference to the VoiceEngine for dispatching actions.
  mutable engine: option<VoiceEngine.t>,
  /// The requestAnimationFrame ID for the update loop.
  mutable rafId: option<int>,
}

// ---------------------------------------------------------------------------
// External bindings — DOM manipulation
// ---------------------------------------------------------------------------

/// Get the document object.
@val external document: {..} = "document"

/// Create a new DOM element.
@val @scope("document")
external createElement: string => {..} = "createElement"

/// Create a text node.
@val @scope("document")
external createTextNode: string => {..} = "createTextNode"

/// Request the next animation frame for UI updates.
@val external requestAnimationFrame: (float => unit) => int = "requestAnimationFrame"

/// Cancel a pending animation frame request.
@val external cancelAnimationFrame: int => unit = "cancelAnimationFrame"

/// Open a URL in a new tab.
@val @scope("window")
external windowOpen: (string, string) => unit = "open"

// ---------------------------------------------------------------------------
// Construction
// ---------------------------------------------------------------------------

/// Create initial voice controls state.
/// The controls start disconnected with no room. Call syncFromEngine
/// and render to populate the UI.
let make = (): t => {
  voiceState: Active,
  connectionState: VoiceEngine.Disconnected,
  isSpeaking: false,
  audioLevel: 0.0,
  networkQuality: Disconnected,
  inputMode: VoiceActivity,
  pttActive: false,
  roomName: "",
  participantCount: 0,
  settingsOpen: false,
  rootElement: None,
  engine: None,
  rafId: None,
}

// ---------------------------------------------------------------------------
// State synchronisation
// ---------------------------------------------------------------------------

/// Update controls state from the current VoiceEngine state.
/// Call this whenever the engine state changes (via onStateChange callback).
let syncFromEngine = (controls: t, engine: VoiceEngine.t): unit => {
  controls.voiceState = VoiceEngine.getVoiceState(engine)
  controls.connectionState = VoiceEngine.getState(engine)
  controls.isSpeaking = VoiceEngine.isSpeaking(engine)
  controls.audioLevel = VoiceEngine.getAudioLevel(engine)
  controls.inputMode = VoiceEngine.getInputMode(engine)
  controls.pttActive = VoiceEngine.isPttActive(engine)
}

// ---------------------------------------------------------------------------
// Display helpers — text labels and colours
// ---------------------------------------------------------------------------

/// Display text for the mute button based on current voice state.
let muteButtonLabel = (controls: t): string =>
  switch controls.voiceState {
  | Active => "Mute"
  | Muted => "Unmute"
  | Deafened => "Unmute"
  }

/// Unicode icon for the mute button (mic on/off).
let muteButtonIcon = (controls: t): string =>
  switch controls.voiceState {
  | Active => "Mic"
  | Muted => "Mic Off"
  | Deafened => "Mic Off"
  }

/// Display text for the deafen button.
let deafenButtonLabel = (controls: t): string =>
  switch controls.voiceState {
  | Deafened => "Undeafen"
  | _ => "Deafen"
  }

/// Unicode icon for the deafen button (headphones on/off).
let deafenButtonIcon = (controls: t): string =>
  switch controls.voiceState {
  | Deafened => "Headphones Off"
  | _ => "Headphones"
  }

/// Connection status display string for the status indicator.
let connectionLabel = (controls: t): string =>
  switch controls.connectionState {
  | VoiceEngine.Disconnected => "Not connected"
  | VoiceEngine.Connecting => "Connecting..."
  | VoiceEngine.Connected =>
    if controls.participantCount > 0 {
      `${controls.roomName} (${Int.toString(controls.participantCount)})`
    } else {
      controls.roomName
    }
  | VoiceEngine.Reconnecting => "Reconnecting..."
  | VoiceEngine.Failed(msg) => `Failed: ${msg}`
  }

/// CSS colour for the connection status indicator dot.
let connectionColor = (controls: t): string =>
  switch controls.connectionState {
  | VoiceEngine.Disconnected => "#666666"
  | VoiceEngine.Connecting => "#ffaa44"
  | VoiceEngine.Connected => "#44ff44"
  | VoiceEngine.Reconnecting => "#ffaa44"
  | VoiceEngine.Failed(_) => "#ff4444"
  }

/// Network quality colour (CSS hex string).
let networkQualityColor = (quality: networkQuality): string =>
  switch quality {
  | Excellent => "#44ff44"
  | Good => "#aaff44"
  | Fair => "#ffaa44"
  | Poor => "#ff4444"
  | Disconnected => "#666666"
  }

/// Input mode display label for the toggle button.
let inputModeLabel = (controls: t): string =>
  switch controls.inputMode {
  | VoiceActivity => "VAD"
  | PushToTalk => "PTT"
  }

// ---------------------------------------------------------------------------
// DOM construction helpers
// ---------------------------------------------------------------------------

/// Create a styled button element with the given text, CSS class, and
/// click handler. All buttons share a common base style.
let makeButton = (
  ~text: string,
  ~className: string,
  ~title: string,
  ~onClick: unit => unit,
): {..} => {
  let btn = createElement("button")
  btn["textContent"] = text
  btn["className"] = `burble-vc-btn ${className}`
  btn["title"] = title
  btn["onclick"] = (_: {..}) => onClick()
  btn["style"]["cssText"] = `
    background: #2a2a2a;
    color: #e0e0e0;
    border: 1px solid #444;
    border-radius: 6px;
    padding: 6px 12px;
    cursor: pointer;
    font-size: 13px;
    font-family: inherit;
    transition: background 0.15s, border-color 0.15s;
    white-space: nowrap;
  `
  btn
}

/// Create a status indicator dot with the given colour.
let makeStatusDot = (color: string): {..} => {
  let dot = createElement("span")
  dot["className"] = "burble-vc-status-dot"
  dot["style"]["cssText"] = `
    display: inline-block;
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: ${color};
    margin-right: 6px;
    vertical-align: middle;
  `
  dot
}

/// Create a text label span.
let makeLabel = (text: string): {..} => {
  let span = createElement("span")
  span["textContent"] = text
  span["style"]["cssText"] = `
    color: #ccc;
    font-size: 13px;
    vertical-align: middle;
  `
  span
}

/// Create a separator element between button groups.
let makeSeparator = (): {..} => {
  let sep = createElement("span")
  sep["className"] = "burble-vc-separator"
  sep["style"]["cssText"] = `
    display: inline-block;
    width: 1px;
    height: 20px;
    background: #444;
    margin: 0 8px;
    vertical-align: middle;
  `
  sep
}

/// Create the audio level meter (a thin horizontal bar).
let makeLevelMeter = (): {..} => {
  let container = createElement("div")
  container["className"] = "burble-vc-level-container"
  container["style"]["cssText"] = `
    display: inline-block;
    width: 40px;
    height: 4px;
    background: #333;
    border-radius: 2px;
    margin: 0 6px;
    vertical-align: middle;
    overflow: hidden;
  `

  let fill = createElement("div")
  fill["className"] = "burble-vc-level-fill"
  fill["style"]["cssText"] = `
    width: 0%;
    height: 100%;
    background: #44ff44;
    border-radius: 2px;
    transition: width 0.05s linear;
  `

  let _ = container["appendChild"](fill)
  container
}

// ---------------------------------------------------------------------------
// Rendering — build the control bar DOM
// ---------------------------------------------------------------------------

/// Render the voice control bar and return the root DOM element.
/// The bar is a fixed-position bottom bar with all controls laid out
/// horizontally. It self-updates via requestAnimationFrame.
///
/// Call this once and append the returned element to your page container.
/// Subsequent updates are handled by the internal update loop.
let rec render = (controls: t, engine: VoiceEngine.t): {..} => {
  controls.engine = Some(engine)

  // ── Root container ──
  let bar = createElement("div")
  bar["className"] = "burble-voice-controls"
  bar["style"]["cssText"] = `
    display: flex;
    align-items: center;
    gap: 4px;
    padding: 8px 16px;
    background: #1a1a1a;
    border-top: 1px solid #333;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    user-select: none;
  `

  // ── Room name / connection status ──
  let statusGroup = createElement("div")
  statusGroup["className"] = "burble-vc-status-group"
  statusGroup["style"]["cssText"] = "display: flex; align-items: center; margin-right: 8px;"

  let statusDot = makeStatusDot(connectionColor(controls))
  let _ = statusDot["setAttribute"]("data-role", "status-dot")
  let statusLabel = makeLabel(connectionLabel(controls))
  let _ = statusLabel["setAttribute"]("data-role", "status-label")
  let _ = statusGroup["appendChild"](statusDot)
  let _ = statusGroup["appendChild"](statusLabel)
  let _ = bar["appendChild"](statusGroup)

  // ── Audio level meter ──
  let levelMeter = makeLevelMeter()
  let _ = levelMeter["setAttribute"]("data-role", "level-meter")
  let _ = bar["appendChild"](levelMeter)

  let _ = bar["appendChild"](makeSeparator())

  // ── Mute button ──
  let muteBtn = makeButton(
    ~text=muteButtonLabel(controls),
    ~className="burble-vc-mute",
    ~title=muteButtonIcon(controls),
    ~onClick=() => {
      switch controls.engine {
      | Some(eng) =>
        let _ = VoiceEngine.toggleMute(eng)
        syncFromEngine(controls, eng)
      | None => ()
      }
    },
  )
  let _ = muteBtn["setAttribute"]("data-role", "mute-btn")
  let _ = bar["appendChild"](muteBtn)

  // ── Deafen button ──
  let deafenBtn = makeButton(
    ~text=deafenButtonLabel(controls),
    ~className="burble-vc-deafen",
    ~title=deafenButtonIcon(controls),
    ~onClick=() => {
      switch controls.engine {
      | Some(eng) =>
        let _ = VoiceEngine.toggleDeafen(eng)
        syncFromEngine(controls, eng)
      | None => ()
      }
    },
  )
  let _ = deafenBtn["setAttribute"]("data-role", "deafen-btn")
  let _ = bar["appendChild"](deafenBtn)

  let _ = bar["appendChild"](makeSeparator())

  // ── Input mode toggle (VAD / PTT) ──
  let modeBtn = makeButton(
    ~text=inputModeLabel(controls),
    ~className="burble-vc-mode",
    ~title="Toggle between Voice Activity Detection and Push-to-Talk",
    ~onClick=() => {
      switch controls.engine {
      | Some(eng) =>
        let newMode = switch controls.inputMode {
        | VoiceActivity => VoiceEngine.PushToTalk
        | PushToTalk => VoiceEngine.VoiceActivity
        }
        VoiceEngine.setInputMode(eng, newMode)
        controls.inputMode = newMode
      | None => ()
      }
    },
  )
  let _ = modeBtn["setAttribute"]("data-role", "mode-btn")
  let _ = bar["appendChild"](modeBtn)

  // ── PTT indicator ──
  let pttIndicator = createElement("span")
  pttIndicator["className"] = "burble-vc-ptt-indicator"
  let _ = pttIndicator["setAttribute"]("data-role", "ptt-indicator")
  pttIndicator["textContent"] = "TX"
  pttIndicator["style"]["cssText"] = `
    display: none;
    background: #ff4444;
    color: white;
    padding: 2px 8px;
    border-radius: 4px;
    font-size: 11px;
    font-weight: bold;
    margin-left: 4px;
  `
  let _ = bar["appendChild"](pttIndicator)

  let _ = bar["appendChild"](makeSeparator())

  // ── Self-test button ──
  let selfTestBtn = makeButton(
    ~text="Self-Test",
    ~className="burble-vc-selftest",
    ~title="Run audio diagnostics self-test",
    ~onClick=() => {
      windowOpen("/api/v1/diagnostics/self-test/quick", "_blank")
    },
  )
  let _ = selfTestBtn["setAttribute"]("data-role", "selftest-btn")
  let _ = bar["appendChild"](selfTestBtn)

  // ── Settings gear ──
  let settingsBtn = makeButton(
    ~text="Settings",
    ~className="burble-vc-settings",
    ~title="Open audio device settings",
    ~onClick=() => {
      controls.settingsOpen = !controls.settingsOpen
      // Toggle a settings panel (rendered separately).
      Console.log2("[Burble] Settings panel:", if controls.settingsOpen { "open" } else { "closed" })
    },
  )
  let _ = settingsBtn["setAttribute"]("data-role", "settings-btn")
  let _ = bar["appendChild"](settingsBtn)

  let _ = bar["appendChild"](makeSeparator())

  // ── Leave / disconnect button ──
  let leaveBtn = makeButton(
    ~text="Leave",
    ~className="burble-vc-leave",
    ~title="Disconnect from voice channel",
    ~onClick=() => {
      switch controls.engine {
      | Some(eng) =>
        VoiceEngine.disconnect(eng)
        syncFromEngine(controls, eng)
        controls.roomName = ""
        controls.participantCount = 0
      | None => ()
      }
    },
  )
  let _ = leaveBtn["setAttribute"]("data-role", "leave-btn")
  leaveBtn["style"]["background"] = "#4a1a1a"
  leaveBtn["style"]["borderColor"] = "#744"
  let _ = bar["appendChild"](leaveBtn)

  controls.rootElement = Some(castToJsObj(bar))

  // ── Start the update loop ──
  startUpdateLoop(controls)

  bar
}

/// Start the requestAnimationFrame update loop that syncs DOM elements
/// with the current controls state. Runs at display refresh rate but
/// only updates elements whose values have changed.
and startUpdateLoop = (controls: t): unit => {
  let rec loop = (_timestamp: float): unit => {
    // Sync from engine on every frame for smooth audio level display.
    switch controls.engine {
    | Some(eng) => syncFromEngine(controls, eng)
    | None => ()
    }

    // Update DOM elements.
    switch controls.rootElement {
    | Some(root) =>
      // ── Update status dot colour ──
      let dots: array<{..}> = %raw(`Array.from(root.querySelectorAll('[data-role="status-dot"]'))`)
      dots->Array.forEach(dot => {
        dot["style"]["background"] = connectionColor(controls)
      })

      // ── Update status label text ──
      let labels: array<{..}> = %raw(`Array.from(root.querySelectorAll('[data-role="status-label"]'))`)
      labels->Array.forEach(label => {
        label["textContent"] = connectionLabel(controls)
      })

      // ── Update audio level meter fill ──
      let meters: array<{..}> = %raw(`Array.from(root.querySelectorAll('[data-role="level-meter"]'))`)
      meters->Array.forEach(meter => {
        let fill: {..} = meter["firstChild"]
        let pct = Float.toString(controls.audioLevel *. 100.0)
        fill["style"]["width"] = `${pct}%`
        // Colour transitions: green -> yellow -> red based on level.
        let color = if controls.audioLevel > 0.6 {
          "#ff4444"
        } else if controls.audioLevel > 0.3 {
          "#ffaa44"
        } else {
          "#44ff44"
        }
        fill["style"]["background"] = color
      })

      // ── Update mute button label ──
      let muteBtns: array<{..}> = %raw(`Array.from(root.querySelectorAll('[data-role="mute-btn"]'))`)
      muteBtns->Array.forEach(btn => {
        btn["textContent"] = muteButtonLabel(controls)
        btn["title"] = muteButtonIcon(controls)
        // Visual feedback: red background when muted.
        if controls.voiceState == Muted || controls.voiceState == Deafened {
          btn["style"]["background"] = "#4a1a1a"
          btn["style"]["borderColor"] = "#744"
        } else {
          btn["style"]["background"] = "#2a2a2a"
          btn["style"]["borderColor"] = "#444"
        }
      })

      // ── Update deafen button label ──
      let deafenBtns: array<{..}> = %raw(`Array.from(root.querySelectorAll('[data-role="deafen-btn"]'))`)
      deafenBtns->Array.forEach(btn => {
        btn["textContent"] = deafenButtonLabel(controls)
        btn["title"] = deafenButtonIcon(controls)
        // Visual feedback: orange background when deafened.
        if controls.voiceState == Deafened {
          btn["style"]["background"] = "#4a3a1a"
          btn["style"]["borderColor"] = "#864"
        } else {
          btn["style"]["background"] = "#2a2a2a"
          btn["style"]["borderColor"] = "#444"
        }
      })

      // ── Update mode button label ──
      let modeBtns: array<{..}> = %raw(`Array.from(root.querySelectorAll('[data-role="mode-btn"]'))`)
      modeBtns->Array.forEach(btn => {
        btn["textContent"] = inputModeLabel(controls)
      })

      // ── Update PTT indicator visibility ──
      let pttInds: array<{..}> = %raw(`Array.from(root.querySelectorAll('[data-role="ptt-indicator"]'))`)
      pttInds->Array.forEach(ind => {
        if controls.inputMode == PushToTalk && controls.pttActive {
          ind["style"]["display"] = "inline-block"
        } else {
          ind["style"]["display"] = "none"
        }
      })

      // ── Update leave button visibility ──
      let leaveBtns: array<{..}> = %raw(`Array.from(root.querySelectorAll('[data-role="leave-btn"]'))`)
      leaveBtns->Array.forEach(btn => {
        let isConnected = switch controls.connectionState {
        | VoiceEngine.Connected | VoiceEngine.Reconnecting => true
        | _ => false
        }
        btn["style"]["display"] = if isConnected { "inline-block" } else { "none" }
      })
    | None => ()
    }

    // Schedule next frame.
    let id = requestAnimationFrame(loop)
    controls.rafId = Some(id)
  }

  let id = requestAnimationFrame(loop)
  controls.rafId = Some(id)
}

/// Stop the update loop and remove the control bar from the DOM.
/// Call this when the component is being unmounted.
let destroy = (controls: t): unit => {
  // Cancel the animation frame loop.
  switch controls.rafId {
  | Some(id) => cancelAnimationFrame(id)
  | None => ()
  }
  controls.rafId = None

  // Remove the root element from the DOM.
  switch controls.rootElement {
  | Some(root) =>
    let rootObj = castFromJsObj(root)
    let parent: Nullable.t<{..}> = rootObj["parentNode"]
    let isNull: bool = (%raw(`v => v === null`))(parent)
    if !isNull {
      let p: {..} = (%raw(`v => v`))(parent)
      let _ = p["removeChild"](rootObj)
    }
  | None => ()
  }
  controls.rootElement = None
  controls.engine = None
}
