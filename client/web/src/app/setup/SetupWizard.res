// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// SetupWizard — First-time audio setup wizard UI.
//
// A 7-step wizard that guides the user through:
//   1. Welcome + audio permission request (getUserMedia)
//   2. Select input device (microphone) from enumerateDevices
//   3. Select output device (speakers) from enumerateDevices
//   4. Test microphone (loopback with level meter)
//   5. Test speakers (play 440Hz test tone)
//   6. Network test (fetch /api/v1/diagnostics/self-test/quick)
//   7. Summary + "Ready to go" button
//
// Completion is persisted to localStorage under the key
// "burble-setup-complete". The wizard is shown on first visit
// and can be re-opened from settings.
//
// Framework-agnostic: no React, no JSX, no TEA. Pure DOM manipulation
// matching the existing codebase pattern (see VoiceControls.res).

// ---------------------------------------------------------------------------
// Type definitions
// ---------------------------------------------------------------------------

/// Wizard step identifiers (1-indexed to match display).
type step =
  | /// Step 1: Welcome screen and audio permission request.
    Welcome
  | /// Step 2: Microphone selection from available input devices.
    SelectInput
  | /// Step 3: Speaker selection from available output devices.
    SelectOutput
  | /// Step 4: Microphone test with real-time level meter.
    TestMicrophone
  | /// Step 5: Speaker test with a 440Hz tone.
    TestSpeakers
  | /// Step 6: Network connectivity test via self-test API.
    NetworkTest
  | /// Step 7: Summary of selections and "Ready to go" confirmation.
    Summary

/// Audio device descriptor (input or output).
type audioDevice = {
  /// Browser-assigned device identifier.
  deviceId: string,
  /// Human-readable device name (e.g., "Built-in Microphone").
  label: string,
  /// Device kind: "audioinput" or "audiooutput".
  kind: string,
}

type jsObj

/// Wizard state — tracks progress, selections, and test results.
type t = {
  /// Current wizard step.
  mutable currentStep: step,
  /// Whether audio permission has been granted via getUserMedia.
  mutable permissionGranted: bool,
  /// Available input (microphone) devices.
  mutable inputDevices: array<audioDevice>,
  /// Available output (speaker) devices.
  mutable outputDevices: array<audioDevice>,
  /// Selected input device ID (empty string = default).
  mutable selectedInputId: string,
  /// Selected output device ID (empty string = default).
  mutable selectedOutputId: string,
  /// Whether the microphone test is currently running.
  mutable micTestRunning: bool,
  /// Current microphone test audio level (0.0 to 1.0).
  mutable micTestLevel: float,
  /// Whether the speaker test tone is currently playing.
  mutable speakerTestPlaying: bool,
  /// Network test result: None = not run, Some(true) = passed.
  mutable networkTestResult: option<bool>,
  /// Network test latency in milliseconds (if run).
  mutable networkTestLatency: option<float>,
  /// Whether the network test is currently running.
  mutable networkTestRunning: bool,
  /// Error message from any step (displayed to user).
  mutable errorMessage: option<string>,
  /// The root DOM element for the wizard overlay.
  mutable rootElement: option<jsObj>,
  /// The local MediaStream used for microphone testing.
  mutable testStream: option<jsObj>,
  /// AudioContext for microphone level monitoring and tone generation.
  mutable audioContext: option<jsObj>,
  /// Interval ID for the microphone level polling timer.
  mutable levelIntervalId: option<float>,
  /// The OscillatorNode used for the speaker test tone.
  mutable oscillator: option<jsObj>,
  /// Animation frame ID for mic test level updates.
  mutable rafId: option<int>,
  /// Callback invoked when the wizard completes successfully.
  mutable onComplete: option<unit => unit>,
}

// ---------------------------------------------------------------------------
// External bindings — DOM, Media, Storage, Fetch
// ---------------------------------------------------------------------------

/// Get the document object for DOM manipulation.
@val external document: {..} = "document"

/// Create a new DOM element by tag name.
@val @scope("document")
external createElement: string => {..} = "createElement"

/// Create a text node for DOM insertion.
@val @scope("document")
external createTextNode: string => {..} = "createTextNode"

/// Access the navigator object for mediaDevices API.
@val external navigator: {..} = "navigator"

/// Access localStorage for persisting setup completion.
@val external localStorage: {..} = "localStorage"

/// Fetch a URL and return a promise of the Response.
@val external fetch: string => promise<{..}> = "fetch"

/// Request the next animation frame for UI updates.
@val external requestAnimationFrame: (float => unit) => int = "requestAnimationFrame"

/// Cancel a pending animation frame request.
@val external cancelAnimationFrame: int => unit = "cancelAnimationFrame"

/// Set a recurring timer for level polling.
@val external setInterval: (unit => unit, int) => float = "setInterval"

/// Cancel a recurring timer.
@val external clearInterval: float => unit = "clearInterval"

/// Access the console for debug logging.
@val external console: {..} = "console"

/// Construct a new AudioContext for Web Audio processing.
@new external makeAudioContext: unit => {..} = "AudioContext"

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// localStorage key for persisting wizard completion.
let storageKey = "burble-setup-complete"

/// localStorage key for persisting selected input device.
let inputDeviceKey = "burble-input-device"

/// localStorage key for persisting selected output device.
let outputDeviceKey = "burble-output-device"

/// Total number of wizard steps.
let totalSteps = 7

/// Test tone frequency in Hz (A4 = 440Hz, universally recognisable).
let testToneHz = 440.0

/// Test tone duration in seconds.
let testToneDuration = 2.0

/// Self-test API endpoint for the network check.
let selfTestUrl = "/api/v1/diagnostics/self-test/quick"

// ---------------------------------------------------------------------------
// Construction
// ---------------------------------------------------------------------------

/// Create initial wizard state. The wizard starts at the Welcome step.
/// Call `render` to build the DOM and display the overlay.
let make = (): t => {
  currentStep: Welcome,
  permissionGranted: false,
  inputDevices: [],
  outputDevices: [],
  selectedInputId: "",
  selectedOutputId: "",
  micTestRunning: false,
  micTestLevel: 0.0,
  speakerTestPlaying: false,
  networkTestResult: None,
  networkTestLatency: None,
  networkTestRunning: false,
  errorMessage: None,
  rootElement: None,
  testStream: None,
  audioContext: None,
  levelIntervalId: None,
  oscillator: None,
  rafId: None,
  onComplete: None,
}

// ---------------------------------------------------------------------------
// Helpers — step metadata
// ---------------------------------------------------------------------------

/// Convert step to a 1-indexed integer for the stepper display.
let stepToIndex = (s: step): int =>
  switch s {
  | Welcome => 1
  | SelectInput => 2
  | SelectOutput => 3
  | TestMicrophone => 4
  | TestSpeakers => 5
  | NetworkTest => 6
  | Summary => 7
  }

/// Display title for each step.
let stepTitle = (s: step): string =>
  switch s {
  | Welcome => "Welcome to Burble"
  | SelectInput => "Select Microphone"
  | SelectOutput => "Select Speakers"
  | TestMicrophone => "Test Microphone"
  | TestSpeakers => "Test Speakers"
  | NetworkTest => "Network Test"
  | Summary => "Ready to Go"
  }

/// Display description for each step.
let stepDescription = (s: step): string =>
  switch s {
  | Welcome => "Let's set up your audio devices for the best experience. We'll need access to your microphone."
  | SelectInput => "Choose which microphone to use for voice chat."
  | SelectOutput => "Choose which speakers or headphones to use for audio playback."
  | TestMicrophone => "Speak into your microphone to verify it's working. You should see the level meter respond."
  | TestSpeakers => "Click the button below to play a test tone through your selected speakers."
  | NetworkTest => "Testing connectivity to the Burble server..."
  | Summary => "Your setup is complete. Here's a summary of your selections."
  }

/// Get the next step (or None if at the end).
let nextStep = (s: step): option<step> =>
  switch s {
  | Welcome => Some(SelectInput)
  | SelectInput => Some(SelectOutput)
  | SelectOutput => Some(TestMicrophone)
  | TestMicrophone => Some(TestSpeakers)
  | TestSpeakers => Some(NetworkTest)
  | NetworkTest => Some(Summary)
  | Summary => None
  }

/// Get the previous step (or None if at the beginning).
let prevStep = (s: step): option<step> =>
  switch s {
  | Welcome => None
  | SelectInput => Some(Welcome)
  | SelectOutput => Some(SelectInput)
  | TestMicrophone => Some(SelectOutput)
  | TestSpeakers => Some(TestMicrophone)
  | NetworkTest => Some(TestSpeakers)
  | Summary => Some(NetworkTest)
  }

// ---------------------------------------------------------------------------
// Check if setup is already complete
// ---------------------------------------------------------------------------

/// Check localStorage to see if the setup wizard has been completed.
/// Returns true if the user has already gone through the wizard.
let isSetupComplete = (): bool => {
  // %raw with a bare identifier cannot see ReScript-bound locals (the compiler
  // doesn't analyse the raw string, so `value` looked unused and the binding
  // was elided — producing `localStorage.getItem(k), value !== null` in the
  // compiled JS, where `value` is undefined). Pass via an arrow function arg
  // so the value flows through explicitly.
  let value: Nullable.t<string> = localStorage["getItem"](storageKey)
  let isNull: bool = (%raw(`v => v === null`))(value)
  !isNull
}

/// Mark the setup as complete in localStorage.
let markSetupComplete = (): unit => {
  localStorage["setItem"](storageKey, "true")
}

// ---------------------------------------------------------------------------
// Media device enumeration
// ---------------------------------------------------------------------------

external castToJsObj: {..} => jsObj = "%identity"
external castFromJsObj: jsObj => {..} = "%identity"

/// Request audio permission and enumerate available devices.
/// Populates inputDevices and outputDevices arrays.
let rec enumerateDevices = async (wizard: t): unit => {
  try {
    // Request microphone permission first — needed for device labels.
    let stream: {..} = await %raw(`navigator.mediaDevices.getUserMedia({ audio: true })`)
    wizard.permissionGranted = true

    // Store the stream temporarily for cleanup.
    wizard.testStream = Some(castToJsObj(stream))

    // Enumerate all media devices.
    let devices: array<{..}> = await %raw(`navigator.mediaDevices.enumerateDevices()`)

    // Filter and map to our audioDevice type.
    let inputs = devices->Array.filterMap(d => {
      let kind: string = d["kind"]
      if kind == "audioinput" {
        let deviceId: string = d["deviceId"]
        let label: string = d["label"]
        let displayLabel = if label == "" { `Microphone (${deviceId->String.slice(~start=0, ~end=8)})` } else { label }
        Some({deviceId, label: displayLabel, kind})
      } else {
        None
      }
    })

    let outputs = devices->Array.filterMap(d => {
      let kind: string = d["kind"]
      if kind == "audiooutput" {
        let deviceId: string = d["deviceId"]
        let label: string = d["label"]
        let displayLabel = if label == "" { `Speaker (${deviceId->String.slice(~start=0, ~end=8)})` } else { label }
        Some({deviceId, label: displayLabel, kind})
      } else {
        None
      }
    })

    wizard.inputDevices = inputs
    wizard.outputDevices = outputs

    // Select defaults if nothing was previously selected.
    if wizard.selectedInputId == "" {
      inputs->Array.get(0)->Option.forEach(d => wizard.selectedInputId = d.deviceId)
    }
    if wizard.selectedOutputId == "" {
      outputs->Array.get(0)->Option.forEach(d => wizard.selectedOutputId = d.deviceId)
    }

    // Restore previous selections from localStorage.
    // Same %raw-scope issue as isSetupComplete: pass values as function args.
    let savedInput: Nullable.t<string> = localStorage["getItem"](inputDeviceKey)
    let savedInputNull: bool = (%raw(`v => v === null`))(savedInput)
    if !savedInputNull {
      let si: string = (%raw(`v => v`))(savedInput)
      wizard.selectedInputId = si
    }
    let savedOutput: Nullable.t<string> = localStorage["getItem"](outputDeviceKey)
    let savedOutputNull: bool = (%raw(`v => v === null`))(savedOutput)
    if !savedOutputNull {
      let so: string = (%raw(`v => v`))(savedOutput)
      wizard.selectedOutputId = so
    }

    wizard.errorMessage = None
    console["log"](`[Burble:Setup] Found ${Int.toString(Array.length(inputs))} inputs, ${Int.toString(Array.length(outputs))} outputs`)
  } catch {
  | exn =>
    let msg: string = %raw(`(exn => exn.message || "Error")`)(exn)
    wizard.errorMessage = Some(`Microphone access failed: ${msg}`)
    wizard.permissionGranted = false
    console["error"](`[Burble:Setup] ${msg}`)
  }
}

// ---------------------------------------------------------------------------
// Microphone test — level metering
// ---------------------------------------------------------------------------

/// Start the microphone test. Creates an AudioContext and AnalyserNode
/// to monitor the selected input device's audio level in real time.
and startMicTest = async (wizard: t): unit => {
  // Stop any existing test first.
  stopMicTest(wizard)

  try {
    // Get a fresh stream from the selected device.
    let constraints: {..} = if wizard.selectedInputId != "" {
      %raw(`({ audio: { deviceId: { exact: wizard.selectedInputId } } })`)
    } else {
      %raw(`({ audio: true })`)
    }
    let stream: {..} = await %raw(`navigator.mediaDevices.getUserMedia(constraints)`)
    wizard.testStream = Some(castToJsObj(stream))

    let ctx = makeAudioContext()
    wizard.audioContext = Some(castToJsObj(ctx))

    let source = ctx["createMediaStreamSource"](stream)
    let analyser = ctx["createAnalyser"]()
    analyser["fftSize"] = 256
    ignore(source["connect"](analyser))

    wizard.micTestRunning = true

    // Poll audio level every 50ms.
    let intervalId = setInterval(() => {
      let rms: float = %raw(`(() => {
        const data = new Uint8Array(analyser.frequencyBinCount);
        analyser.getByteFrequencyData(data);
        let sum = 0;
        for (let i = 0; i < data.length; i++) {
          sum += data[i];
        }
        return sum / data.length / 255.0;
      })()`)
      wizard.micTestLevel = rms
      // Update the level meter in the DOM.
      updateMicLevelDom(wizard)
    }, 50)
    wizard.levelIntervalId = Some(intervalId)
  } catch {
  | exn =>
    let msg: string = %raw(`(exn => exn.message || "Error")`)(exn)
    wizard.errorMessage = Some(msg)
  }
}

/// Stop the microphone test and release resources.
and stopMicTest = (wizard: t): unit => {
  wizard.micTestRunning = false

  // Stop level polling.
  switch wizard.levelIntervalId {
  | Some(id) => clearInterval(id)
  | None => ()
  }
  wizard.levelIntervalId = None

  // Stop the test stream tracks.
  switch wizard.testStream {
  | Some(stream) =>
    let streamObj = castFromJsObj(stream)
    let tracks: array<{..}> = streamObj["getTracks"]()
    tracks->Array.forEach(track => ignore(track["stop"]()))
  | None => ()
  }
  wizard.testStream = None

  // Close AudioContext.
  switch wizard.audioContext {
  | Some(ctx) =>
    let _: unit = %raw(`(() => { try { ctx.close(); } catch(e) {} })()`)
    ignore(ctx)
  | None => ()
  }
  wizard.audioContext = None

  wizard.micTestLevel = 0.0
}

/// Update the microphone level meter DOM element.
and updateMicLevelDom = (wizard: t): unit => {
  switch wizard.rootElement {
  | Some(root) =>
    let fills: array<{..}> = %raw(`Array.from(root.querySelectorAll('[data-role="mic-level-fill"]'))`)
    fills->Array.forEach(fill => {
      let pct = Float.toString(wizard.micTestLevel *. 100.0)
      fill["style"]["width"] = `${pct}%`
      let color = if wizard.micTestLevel > 0.6 {
        "#ff4444"
      } else if wizard.micTestLevel > 0.3 {
        "#ffaa44"
      } else {
        "#44ff44"
      }
      fill["style"]["background"] = color
    })
  | None => ()
  }
}

// ---------------------------------------------------------------------------
// Speaker test — 440Hz tone generation
// ---------------------------------------------------------------------------

/// Play a 440Hz test tone through the selected output device.
/// The tone plays for testToneDuration seconds then stops automatically.
and playTestTone = (wizard: t): unit => {
  // Stop any existing tone first.
  stopTestTone(wizard)

  let ctx = switch wizard.audioContext {
  | Some(ctx) => ctx
  | None =>
    let ctx = makeAudioContext()
    wizard.audioContext = Some(castToJsObj(ctx))
    castToJsObj(ctx)
  }

  let ctxObj = castFromJsObj(ctx)
  let oscillator = ctxObj["createOscillator"]()
  oscillator["type"] = "sine"
  oscillator["frequency"]["setValueAtTime"](testToneHz, ctxObj["currentTime"])

  // Use a gain node to control volume (avoid blasting the user).
  let gain = ctxObj["createGain"]()
  gain["gain"]["setValueAtTime"](0.3, ctxObj["currentTime"])

  ignore(oscillator["connect"](gain))
  ignore(gain["connect"](ctxObj["destination"]))

  ignore(oscillator["start"]())
  wizard.oscillator = Some(castToJsObj(oscillator))
  wizard.speakerTestPlaying = true

  let stopAt = Float.toString(testToneDuration)
  // Auto-stop after the test duration.
  let _: unit = %raw(`((stopAt) => {
    oscillator.stop(ctx.currentTime + parseFloat(stopAt));
    oscillator.onended = () => {
      wizard.speakerTestPlaying = false;
      wizard.oscillator = undefined;
    };
  })(stopAt)`)
  ignore(oscillator)
}

/// Stop the test tone if currently playing.
and stopTestTone = (wizard: t): unit => {
  switch wizard.oscillator {
  | Some(osc) =>
    let _: unit = %raw(`(() => { try { osc.stop(); } catch(e) {} })()`)
    ignore(osc)
  | None => ()
  }
  wizard.oscillator = None
  wizard.speakerTestPlaying = false
}

// ---------------------------------------------------------------------------
// Network test — fetch self-test endpoint
// ---------------------------------------------------------------------------

/// Run a quick network connectivity test by fetching the self-test endpoint.
/// Measures round-trip latency and checks for a successful response.
and runNetworkTest = async (wizard: t): unit => {
  wizard.networkTestRunning = true
  wizard.networkTestResult = None
  wizard.networkTestLatency = None
  wizard.errorMessage = None

  // Update DOM to show loading state.
  updateStepContent(wizard)

  let startTime: float = %raw(`performance.now()`)

  try {
    let response = await fetch(selfTestUrl)
    let endTime: float = %raw(`performance.now()`)
    let latency = endTime -. startTime

    let ok: bool = response["ok"]
    wizard.networkTestResult = Some(ok)
    wizard.networkTestLatency = Some(latency)

    if !ok {
      let status: int = response["status"]
      wizard.errorMessage = Some(`Server returned HTTP ${Int.toString(status)}`)
    }
  } catch {
  | exn =>
    let msg: string = %raw(`(exn => exn.message || "Error")`)(exn)
    wizard.networkTestResult = Some(false)
    wizard.errorMessage = Some(`Connection failed: ${msg}`)
  }

  wizard.networkTestRunning = false
  updateStepContent(wizard)
}

// ---------------------------------------------------------------------------
// DOM construction helpers
// ---------------------------------------------------------------------------

/// Create a styled button matching the VoiceControls.res pattern.
and makeButton = (
  ~text: string,
  ~className: string,
  ~title: string,
  ~onClick: unit => unit,
): {..} => {
  let btn = createElement("button")
  btn["textContent"] = text
  btn["className"] = `burble-sw-btn ${className}`
  btn["title"] = title
  btn["onclick"] = (_: {..}) => onClick()
  btn["style"]["cssText"] = `
    background: #2a2a2a;
    color: #e0e0e0;
    border: 1px solid #444;
    border-radius: 6px;
    padding: 8px 16px;
    cursor: pointer;
    font-size: 14px;
    font-family: inherit;
    transition: background 0.15s, border-color 0.15s;
    white-space: nowrap;
  `
  btn
}

/// Create a primary (highlighted) action button.
and makePrimaryButton = (
  ~text: string,
  ~className: string,
  ~title: string,
  ~onClick: unit => unit,
): {..} => {
  let btn = makeButton(~text, ~className, ~title, ~onClick)
  btn["style"]["background"] = "#2a4a6a"
  btn["style"]["borderColor"] = "#4488cc"
  btn["style"]["color"] = "#ffffff"
  btn
}

/// Create a device selector <select> element populated with the given devices.
and makeDeviceSelector = (
  devices: array<audioDevice>,
  selectedId: string,
  onChange: string => unit,
): {..} => {
  let select = createElement("select")
  select["className"] = "burble-sw-select"
  select["style"]["cssText"] = `
    background: #2a2a2a;
    color: #e0e0e0;
    border: 1px solid #444;
    border-radius: 6px;
    padding: 8px 12px;
    font-size: 14px;
    font-family: inherit;
    width: 100%;
    max-width: 400px;
    cursor: pointer;
    appearance: auto;
  `

  devices->Array.forEach(device => {
    let opt = createElement("option")
    opt["value"] = device.deviceId
    opt["textContent"] = device.label
    if device.deviceId == selectedId {
      opt["selected"] = true
    }
    ignore(select["appendChild"](opt))
  })

  select["onchange"] = (_: {..}) => {
    let value: string = select["value"]
    onChange(value)
  }

  select
}

/// Create the audio level meter bar (wider version for the wizard).
and makeLevelMeter = (): {..} => {
  let container = createElement("div")
  container["className"] = "burble-sw-level-container"
  container["style"]["cssText"] = `
    width: 100%;
    max-width: 400px;
    height: 12px;
    background: #222;
    border-radius: 6px;
    overflow: hidden;
    border: 1px solid #444;
    margin: 12px 0;
  `

  let fill = createElement("div")
  ignore(fill["setAttribute"]("data-role", "mic-level-fill"))
  fill["style"]["cssText"] = `
    width: 0%;
    height: 100%;
    background: #44ff44;
    border-radius: 6px;
    transition: width 0.05s linear;
  `
  ignore(container["appendChild"](fill))

  container
}

/// Build the stepper indicator showing current progress through
/// all wizard steps (1 through 7).
and makeStepper = (currentIdx: int): {..} => {
  let stepper = createElement("div")
  stepper["className"] = "burble-sw-stepper"
  stepper["style"]["cssText"] = `
    display: flex;
    justify-content: center;
    gap: 8px;
    margin-bottom: 24px;
  `

  // Create a circle for each step.
  for i in 1 to totalSteps {
    let circle = createElement("div")
    let (bg, border) = if i < currentIdx {
      // Completed step.
      ("#44ff44", "#2a6a2a")
    } else if i == currentIdx {
      // Current step.
      ("#4488cc", "#2a4a6a")
    } else {
      // Future step.
      ("#333", "#444")
    }
    circle["style"]["cssText"] = `
      width: 28px;
      height: 28px;
      border-radius: 50%;
      background: ${bg};
      border: 2px solid ${border};
      display: flex;
      align-items: center;
      justify-content: center;
      font-size: 12px;
      font-weight: bold;
      color: ${if i <= currentIdx { "#fff" } else { "#666" }};
    `
    circle["textContent"] = Int.toString(i)
    ignore(stepper["appendChild"](circle))

    // Add a connecting line between circles (except after the last).
    if i < totalSteps {
      let line = createElement("div")
      let lineColor = if i < currentIdx { "#44ff44" } else { "#333" }
      line["style"]["cssText"] = `
        width: 20px;
        height: 2px;
        background: ${lineColor};
        align-self: center;
      `
      ignore(stepper["appendChild"](line))
    }
  }

  stepper
}

// ---------------------------------------------------------------------------
// Step content builders — one function per wizard step
// ---------------------------------------------------------------------------

/// Build the Welcome step content (Step 1).
/// Shows a welcome message and a "Grant Permission" button.
and buildWelcomeContent = (wizard: t): {..} => {
  let content = createElement("div")
  content["style"]["cssText"] = "text-align: center; padding: 20px 0;"

  let desc = createElement("p")
  desc["textContent"] = stepDescription(Welcome)
  desc["style"]["cssText"] = "color: #aaa; font-size: 15px; line-height: 1.6; margin-bottom: 24px;"
  ignore(content["appendChild"](desc))

  if wizard.permissionGranted {
    let badge = createElement("div")
    badge["textContent"] = "Permission Granted"
    badge["style"]["cssText"] = `
      display: inline-block;
      background: #1a3a1a;
      color: #44ff44;
      padding: 8px 20px;
      border-radius: 6px;
      font-size: 14px;
      font-weight: 600;
      border: 1px solid #2a6a2a;
    `
    ignore(content["appendChild"](badge))
  } else {
    let permBtn = makePrimaryButton(
      ~text="Grant Microphone Access",
      ~className="burble-sw-perm",
      ~title="Request microphone permission from the browser",
      ~onClick=() => {
        let _ = enumerateDevices(wizard)
        // Re-render after permission is resolved.
        let _: unit = %raw(`(async () => {
          await wizard.constructor ? undefined : undefined;
          setTimeout(() => { updateStepContent(wizard); }, 500);
        })()`)
        // Attempt enumeration and update.
        ignore(enumerateDevices(wizard))
      },
    )
    ignore(content["appendChild"](permBtn))
  }

  // Show error if permission was denied.
  switch wizard.errorMessage {
  | Some(msg) =>
    let err = createElement("p")
    err["textContent"] = msg
    err["style"]["cssText"] = "color: #ff4444; font-size: 13px; margin-top: 16px;"
    ignore(content["appendChild"](err))
  | None => ()
  }

  content
}

/// Build the Select Input step content (Step 2).
and buildSelectInputContent = (wizard: t): {..} => {
  let content = createElement("div")
  content["style"]["cssText"] = "padding: 20px 0;"

  let desc = createElement("p")
  desc["textContent"] = stepDescription(SelectInput)
  desc["style"]["cssText"] = "color: #aaa; font-size: 14px; margin-bottom: 16px;"
  ignore(content["appendChild"](desc))

  if Array.length(wizard.inputDevices) == 0 {
    let noDevices = createElement("p")
    noDevices["textContent"] = "No microphones detected. Please connect a microphone and go back to grant permission again."
    noDevices["style"]["cssText"] = "color: #ff8844; font-size: 14px;"
    ignore(content["appendChild"](noDevices) ) } else {
    let selector = makeDeviceSelector(
      wizard.inputDevices,
      wizard.selectedInputId,
      id => {
        wizard.selectedInputId = id
        localStorage["setItem"](inputDeviceKey, id)
      },
    )
    ignore(content["appendChild"](selector))
  }

  content
}

/// Build the Select Output step content (Step 3).
and buildSelectOutputContent = (wizard: t): {..} => {
  let content = createElement("div")
  content["style"]["cssText"] = "padding: 20px 0;"

  let desc = createElement("p")
  desc["textContent"] = stepDescription(SelectOutput)
  desc["style"]["cssText"] = "color: #aaa; font-size: 14px; margin-bottom: 16px;"
  ignore(content["appendChild"](desc))

  if Array.length(wizard.outputDevices) == 0 {
    let noDevices = createElement("p")
    noDevices["textContent"] = "No output devices detected. Your browser may not support output device selection. The default device will be used."
    noDevices["style"]["cssText"] = "color: #ff8844; font-size: 14px;"
    ignore(content["appendChild"](noDevices))
  } else {
    let selector = makeDeviceSelector(
      wizard.outputDevices,
      wizard.selectedOutputId,
      id => {
        wizard.selectedOutputId = id
        localStorage["setItem"](outputDeviceKey, id)
      },
    )
    ignore(content["appendChild"](selector))
  }

  content
}

/// Build the Test Microphone step content (Step 4).
and buildTestMicContent = (wizard: t): {..} => {
  let content = createElement("div")
  content["style"]["cssText"] = "padding: 20px 0;"

  let desc = createElement("p")
  desc["textContent"] = stepDescription(TestMicrophone)
  desc["style"]["cssText"] = "color: #aaa; font-size: 14px; margin-bottom: 16px;"
  ignore(content["appendChild"](desc))

  // Level meter.
  let meter = makeLevelMeter()
  ignore(content["appendChild"](meter))

  // Start/Stop button.
  if wizard.micTestRunning {
    let stopBtn = makeButton(
      ~text="Stop Test",
      ~className="burble-sw-mic-stop",
      ~title="Stop the microphone test",
      ~onClick=() => {
        stopMicTest(wizard)
        updateStepContent(wizard)
      },
    )
    stopBtn["style"]["background"] = "#4a2a2a"
    stopBtn["style"]["borderColor"] = "#744"
    ignore(content["appendChild"](stopBtn))

    let hint = createElement("p")
    hint["textContent"] = "Speak into your microphone — you should see the green bar respond."
    hint["style"]["cssText"] = "color: #88cc88; font-size: 13px; margin-top: 12px;"
    ignore(content["appendChild"](hint))
  } else {
    let startBtn = makePrimaryButton(
      ~text="Start Microphone Test",
      ~className="burble-sw-mic-start",
      ~title="Begin testing the selected microphone",
      ~onClick=() => {
        let _ = startMicTest(wizard)
        // Update DOM after a short delay for the async operation.
        let _: unit = %raw(`setTimeout(() => { updateStepContent(wizard); }, 300)`)
      },
    )
    ignore(content["appendChild"](startBtn))
  }

  content
}

/// Build the Test Speakers step content (Step 5).
and buildTestSpeakersContent = (wizard: t): {..} => {
  let content = createElement("div")
  content["style"]["cssText"] = "padding: 20px 0;"

  let desc = createElement("p")
  desc["textContent"] = stepDescription(TestSpeakers)
  desc["style"]["cssText"] = "color: #aaa; font-size: 14px; margin-bottom: 16px;"
  ignore(content["appendChild"](desc))

  if wizard.speakerTestPlaying {
    let playingLabel = createElement("div")
    playingLabel["textContent"] = "Playing test tone (440Hz)..."
    playingLabel["style"]["cssText"] = `
      color: #4488cc;
      font-size: 14px;
      margin-bottom: 12px;
      font-weight: 600;
    `
    ignore(content["appendChild"](playingLabel))

    let stopBtn = makeButton(
      ~text="Stop Tone",
      ~className="burble-sw-tone-stop",
      ~title="Stop the test tone",
      ~onClick=() => {
        stopTestTone(wizard)
        updateStepContent(wizard)
      },
    )
    ignore(content["appendChild"](stopBtn))
  } else {
    let playBtn = makePrimaryButton(
      ~text="Play Test Tone",
      ~className="burble-sw-tone-play",
      ~title="Play a 440Hz tone through your speakers",
      ~onClick=() => {
        playTestTone(wizard)
        updateStepContent(wizard)
        let timeoutVal = Float.toString(testToneDuration *. 1000.0 +. 200.0)
        // Auto-refresh when tone ends.
        let _: unit = %raw(`((timeoutVal) => {
          setTimeout(() => { updateStepContent(wizard); }, parseFloat(timeoutVal));
        })(timeoutVal)`)      },
    )
    ignore(content["appendChild"](playBtn))

    let hint = createElement("p")
    hint["textContent"] = "You should hear a steady tone for 2 seconds. Adjust your volume if needed."
    hint["style"]["cssText"] = "color: #888; font-size: 13px; margin-top: 12px;"
    ignore(content["appendChild"](hint))
  }

  content
}

/// Build the Network Test step content (Step 6).
and buildNetworkTestContent = (wizard: t): {..} => {
  let content = createElement("div")
  content["style"]["cssText"] = "padding: 20px 0; text-align: center;"

  if wizard.networkTestRunning {
    // Loading spinner.
    let spinner = createElement("div")
    spinner["style"]["cssText"] = `
      width: 32px;
      height: 32px;
      border: 3px solid #333;
      border-top-color: #4488cc;
      border-radius: 50%;
      animation: burble-spin 0.8s linear infinite;
      margin: 0 auto 16px auto;
    `
    // Inject keyframe if needed.
    let _: unit = %raw(`(() => {
      if (!document.getElementById('burble-sw-keyframes')) {
        const style = document.createElement('style');
        style.id = 'burble-sw-keyframes';
        style.textContent = '@keyframes burble-spin { to { transform: rotate(360deg); } }';
        document.head.appendChild(style);
      }
    })()`)
    ignore(content["appendChild"](spinner))

    let label = createElement("p")
    label["textContent"] = "Testing connection to Burble server..."
    label["style"]["cssText"] = "color: #aaa; font-size: 14px;"
    ignore(content["appendChild"](label))
  } else {
    switch wizard.networkTestResult {
    | Some(passed) =>
      let badge = createElement("div")
      badge["textContent"] = if passed { "Connection Successful" } else { "Connection Failed" }
      let (bg, border, color) = if passed {
        ("#1a3a1a", "#2a6a2a", "#44ff44")
      } else {
        ("#3a1a1a", "#6a2a2a", "#ff4444")
      }
      badge["style"]["cssText"] = `
        display: inline-block;
        background: ${bg};
        color: ${color};
        padding: 10px 24px;
        border-radius: 6px;
        font-size: 15px;
        font-weight: 600;
        border: 1px solid ${border};
        margin-bottom: 12px;
      `
      ignore(content["appendChild"](badge))

      // Show latency if available.
      switch wizard.networkTestLatency {
      | Some(latency) =>
        let latencyEl = createElement("p")
        let latencyColor = if latency < 50.0 {
          "#44ff44"
        } else if latency < 150.0 {
          "#ffaa44"
        } else {
          "#ff4444"
        }
        latencyEl["textContent"] = `Latency: ${Float.toFixed(latency, ~digits=0)}ms`
        latencyEl["style"]["cssText"] = `color: ${latencyColor}; font-size: 14px;`
        ignore(content["appendChild"](latencyEl))
      | None => ()
      }

      // Retry button.
      let retryBtn = makeButton(
        ~text="Test Again",
        ~className="burble-sw-net-retry",
        ~title="Re-run the network test",
        ~onClick=() => {
          let _ = runNetworkTest(wizard)
        },
      )
      retryBtn["style"]["marginTop"] = "12px"
      ignore(content["appendChild"](retryBtn))
    | None =>
      // Test hasn't been run yet — auto-start.
      let startMsg = createElement("p")
      startMsg["textContent"] = "Starting network test..."
      startMsg["style"]["cssText"] = "color: #aaa; font-size: 14px;"
      ignore(content["appendChild"](startMsg))

      // Auto-run the network test.
      let _ = runNetworkTest(wizard)
    }

    // Show error if present.
    switch wizard.errorMessage {
    | Some(msg) =>
      let err = createElement("p")
      err["textContent"] = msg
      err["style"]["cssText"] = "color: #ff4444; font-size: 13px; margin-top: 12px;"
      ignore(content["appendChild"](err))
    | None => ()
    }
  }

  content
}

/// Build the Summary step content (Step 7).
and buildSummaryContent = (wizard: t): {..} => {
  let content = createElement("div")
  content["style"]["cssText"] = "padding: 20px 0;"

  let desc = createElement("p")
  desc["textContent"] = stepDescription(Summary)
  desc["style"]["cssText"] = "color: #aaa; font-size: 14px; margin-bottom: 20px;"
  ignore(content["appendChild"](desc))

  // Summary table.
  let table = createElement("div")
  table["style"]["cssText"] = `
    background: #222;
    border: 1px solid #444;
    border-radius: 8px;
    padding: 16px 20px;
    max-width: 450px;
  `

  // Helper to add a summary row.
  let addRow = (label: string, value: string) => {
    let row = createElement("div")
    row["style"]["cssText"] = `
      display: flex;
      justify-content: space-between;
      padding: 6px 0;
      border-bottom: 1px solid #333;
    `

    let labelEl = createElement("span")
    labelEl["textContent"] = label
    labelEl["style"]["cssText"] = "color: #888; font-size: 13px;"
    ignore(row["appendChild"](labelEl))

    let valueEl = createElement("span")
    valueEl["textContent"] = value
    valueEl["style"]["cssText"] = "color: #e0e0e0; font-size: 13px; font-weight: 600;"
    ignore(row["appendChild"](valueEl))

    ignore(table["appendChild"](row))
  }

  // Find selected device labels.
  let inputLabel =
    wizard.inputDevices
    ->Array.find(d => d.deviceId == wizard.selectedInputId)
    ->Option.map(d => d.label)
    ->Option.getOr("Default")

  let outputLabel =
    wizard.outputDevices
    ->Array.find(d => d.deviceId == wizard.selectedOutputId)
    ->Option.map(d => d.label)
    ->Option.getOr("Default")

  let networkStatus = switch wizard.networkTestResult {
  | Some(true) => "Connected"
  | Some(false) => "Failed"
  | None => "Not tested"
  }

  addRow("Microphone", inputLabel)
  addRow("Speakers", outputLabel)
  addRow("Network", networkStatus)

  ignore(content["appendChild"](table))

  // "Ready to go" button.
  let readyBtn = makePrimaryButton(
    ~text="Ready to Go!",
    ~className="burble-sw-ready",
    ~title="Complete setup and start using Burble",
    ~onClick=() => {
      // Persist device selections.
      localStorage["setItem"](inputDeviceKey, wizard.selectedInputId)
      localStorage["setItem"](outputDeviceKey, wizard.selectedOutputId)

      // Mark setup as complete.
      markSetupComplete()

      // Clean up and notify.
      stopMicTest(wizard)
      stopTestTone(wizard)
      destroy(wizard)

      // Fire completion callback.
      switch wizard.onComplete {
      | Some(cb) => cb()
      | None => ()
      }

      console["log"]("[Burble:Setup] Wizard completed")
    },
  )
  readyBtn["style"]["marginTop"] = "20px"
  readyBtn["style"]["fontSize"] = "16px"
  readyBtn["style"]["padding"] = "12px 32px"
  ignore(content["appendChild"](readyBtn))

  content
}

// ---------------------------------------------------------------------------
// Step content dispatch
// ---------------------------------------------------------------------------

/// Build the content for the current wizard step.
and buildStepContent = (wizard: t): {..} =>
  switch wizard.currentStep {
  | Welcome => buildWelcomeContent(wizard)
  | SelectInput => buildSelectInputContent(wizard)
  | SelectOutput => buildSelectOutputContent(wizard)
  | TestMicrophone => buildTestMicContent(wizard)
  | TestSpeakers => buildTestSpeakersContent(wizard)
  | NetworkTest => buildNetworkTestContent(wizard)
  | Summary => buildSummaryContent(wizard)
  }

/// Update the step content area in the DOM without rebuilding the
/// entire wizard. Preserves the stepper and navigation buttons.
and updateStepContent = (wizard: t): unit => {
  switch wizard.rootElement {
  | Some(root) =>
    // Update step title.
    let titles: array<{..}> = %raw(`Array.from(root.querySelectorAll('[data-role="step-title"]'))`)
    titles->Array.forEach(el => {
      el["textContent"] = stepTitle(wizard.currentStep)
    })

    // Rebuild stepper.
    let stepperContainers: array<{..}> = %raw(`Array.from(root.querySelectorAll('[data-role="stepper"]'))`)
    stepperContainers->Array.forEach(container => {
      container["innerHTML"] = ""
      let newStepper = makeStepper(stepToIndex(wizard.currentStep))
      // Move children from newStepper to container.
      let _: unit = %raw(`(() => {
        while (newStepper.firstChild) {
          container.appendChild(newStepper.firstChild);
        }
      })()`)
      ignore(newStepper)
    })

    // Rebuild content area.
    let contentAreas: array<{..}> = %raw(`Array.from(root.querySelectorAll('[data-role="step-content"]'))`)
    contentAreas->Array.forEach(area => {
      area["innerHTML"] = ""
      ignore(area["appendChild"](buildStepContent(wizard)))
    })

    // Update navigation button visibility and state.
    let backBtns: array<{..}> = %raw(`Array.from(root.querySelectorAll('[data-role="back-btn"]'))`)
    backBtns->Array.forEach(btn => {
      btn["style"]["visibility"] = switch prevStep(wizard.currentStep) {
      | Some(_) => "visible"
      | None => "hidden"
      }
    })

    let nextBtns: array<{..}> = %raw(`Array.from(root.querySelectorAll('[data-role="next-btn"]'))`)
    nextBtns->Array.forEach(btn => {
      switch nextStep(wizard.currentStep) {
      | Some(_) =>
        btn["style"]["display"] = "inline-block"
        // Disable next on Welcome if permission not granted.
        let disabled = wizard.currentStep == Welcome && !wizard.permissionGranted
        btn["disabled"] = disabled
        btn["style"]["opacity"] = if disabled { "0.5" } else { "1" }
      | None =>
        // Last step — hide the Next button (Ready to Go button is in content).
        btn["style"]["display"] = "none"
      }
    })
  | None => ()
  }
}

// ---------------------------------------------------------------------------
// Navigation — step transitions
// ---------------------------------------------------------------------------

/// Navigate to the next wizard step. Handles cleanup of the current
/// step (e.g., stopping mic test) before transitioning.
and goNext = (wizard: t): unit => {
  // Clean up current step resources.
  switch wizard.currentStep {
  | TestMicrophone => stopMicTest(wizard)
  | TestSpeakers => stopTestTone(wizard)
  | _ => ()
  }

  switch nextStep(wizard.currentStep) {
  | Some(next) =>
    wizard.currentStep = next
    wizard.errorMessage = None

    // Auto-start actions for certain steps.
    switch next {
    | SelectInput | SelectOutput =>
      // Ensure devices are enumerated.
      if Array.length(wizard.inputDevices) == 0 {
        let _ = enumerateDevices(wizard)
      }
    | _ => ()
    }

    updateStepContent(wizard)
  | None => ()
  }
}

/// Navigate to the previous wizard step.
and goBack = (wizard: t): unit => {
  // Clean up current step resources.
  switch wizard.currentStep {
  | TestMicrophone => stopMicTest(wizard)
  | TestSpeakers => stopTestTone(wizard)
  | _ => ()
  }

  switch prevStep(wizard.currentStep) {
  | Some(prev) =>
    wizard.currentStep = prev
    wizard.errorMessage = None
    updateStepContent(wizard)
  | None => ()
  }
}

// ---------------------------------------------------------------------------
// Rendering — build the wizard overlay DOM
// ---------------------------------------------------------------------------

/// Render the setup wizard as a full-screen modal overlay.
/// Returns the root DOM element which should be appended to document.body.
///
/// The wizard auto-starts by requesting audio permission on the Welcome step.
/// Call `destroy` to remove the wizard from the DOM.
and render = (wizard: t): {..} => {
  // ── Overlay backdrop ──
  let overlay = createElement("div")
  overlay["className"] = "burble-setup-wizard"
  overlay["style"]["cssText"] = `
    position: fixed;
    top: 0;
    left: 0;
    width: 100vw;
    height: 100vh;
    background: rgba(0, 0, 0, 0.85);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 10000;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
  `

  // ── Modal card ──
  let card = createElement("div")
  card["className"] = "burble-sw-card"
  card["style"]["cssText"] = `
    background: #1a1a1a;
    border: 1px solid #444;
    border-radius: 12px;
    padding: 32px;
    width: 90vw;
    max-width: 560px;
    max-height: 85vh;
    overflow-y: auto;
    box-shadow: 0 8px 32px rgba(0, 0, 0, 0.5);
  `

  // ── Stepper indicator ──
  let stepperContainer = createElement("div")
  ignore(stepperContainer["setAttribute"]("data-role", "stepper"))
  let stepper = makeStepper(stepToIndex(wizard.currentStep))
  // Copy children into the container.
  let _: unit = %raw(`(() => {
    while (stepper.firstChild) {
      stepperContainer.appendChild(stepper.firstChild);
    }
  })()`)
  ignore(stepper)
  ignore(card["appendChild"](stepperContainer))

  // ── Step title ──
  let titleEl = createElement("h2")
  ignore(titleEl["setAttribute"]("data-role", "step-title"))
  titleEl["textContent"] = stepTitle(wizard.currentStep)
  titleEl["style"]["cssText"] = `
    color: #e0e0e0;
    font-size: 20px;
    margin: 0 0 8px 0;
    font-weight: 600;
    text-align: center;
  `
  ignore(card["appendChild"](titleEl))

  // ── Step content area ──
  let contentArea = createElement("div")
  ignore(contentArea["setAttribute"]("data-role", "step-content"))
  ignore(contentArea["appendChild"](buildStepContent(wizard)))
  ignore(card["appendChild"](contentArea))

  // ── Navigation row (Back / Next) ──
  let navRow = createElement("div")
  navRow["style"]["cssText"] = `
    display: flex;
    justify-content: space-between;
    margin-top: 24px;
    padding-top: 16px;
    border-top: 1px solid #333;
  `

  // Back button.
  let backBtn = makeButton(
    ~text="Back",
    ~className="burble-sw-back",
    ~title="Go to the previous step",
    ~onClick=() => goBack(wizard),
  )
  ignore(backBtn["setAttribute"]("data-role", "back-btn"))
  backBtn["style"]["visibility"] = switch prevStep(wizard.currentStep) {
  | Some(_) => "visible"
  | None => "hidden"
  }
  ignore(navRow["appendChild"](backBtn))

  // Next button.
  let nextBtn = makePrimaryButton(
    ~text="Next",
    ~className="burble-sw-next",
    ~title="Continue to the next step",
    ~onClick=() => goNext(wizard),
  )
  ignore(nextBtn["setAttribute"]("data-role", "next-btn"))
  // Disable next on Welcome if permission not granted.
  if wizard.currentStep == Welcome && !wizard.permissionGranted {
    nextBtn["disabled"] = true
    nextBtn["style"]["opacity"] = "0.5"
  }
  // Hide on last step.
  switch nextStep(wizard.currentStep) {
  | None => nextBtn["style"]["display"] = "none"
  | Some(_) => ()
  }
  ignore(navRow["appendChild"](nextBtn))

  ignore(card["appendChild"](navRow))
  ignore(overlay["appendChild"](card))

  wizard.rootElement = Some(castToJsObj(overlay))

  overlay
}

// ---------------------------------------------------------------------------
// Cleanup
// ---------------------------------------------------------------------------

/// Remove the setup wizard from the DOM and release all resources.
/// Call this when the wizard is dismissed or completed.
and destroy = (wizard: t): unit => {
  // Stop any running tests.
  stopMicTest(wizard)
  stopTestTone(wizard)

  // Cancel animation frame.
  switch wizard.rafId {
  | Some(id) => cancelAnimationFrame(id)
  | None => ()
  }
  wizard.rafId = None

  // Remove from DOM.
  switch wizard.rootElement {
  | Some(root) =>
    let rootObj = castFromJsObj(root)
    let parent: Nullable.t<{..}> = rootObj["parentNode"]
    let isNull: bool = (%raw(`v => v === null`))(parent)
    if !isNull {
      let p: {..} = (%raw(`v => v`))(parent)
      ignore(p["removeChild"](root))
    }
  | None => ()
  }
  wizard.rootElement = None
}

// ---------------------------------------------------------------------------
// Public API — registration
// ---------------------------------------------------------------------------

/// Register a callback to be invoked when the wizard completes.
/// The callback receives no arguments; device selections have already
/// been persisted to localStorage at that point.
and onComplete = (wizard: t, cb: unit => unit): unit => {
  wizard.onComplete = Some(cb)
}
