// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// SelfTestPanel — Visual self-test diagnostics panel.
//
// Fetches results from /api/v1/diagnostics/self-test/:mode and renders
// them as a card grid. Each card shows a test name, pass/fail badge,
// timing, and detail text. An overall pass/fail banner appears at the top.
//
// Features:
//   - Mode selector buttons (Quick / Voice / Full)
//   - Auto-run quick test on panel open
//   - Progress indicator while test is running
//   - Latency display with colour coding (green < 5ms, yellow < 15ms, red > 15ms)
//   - "Run Again" button
//
// Framework-agnostic: no React, no JSX, no TEA. Pure DOM manipulation
// matching the existing codebase pattern (see VoiceControls.res).

// ---------------------------------------------------------------------------
// Type definitions
// ---------------------------------------------------------------------------

/// Test mode — determines which subset of diagnostics to run.
type testMode =
  | /// Fast connectivity and basic health checks (~1s).
    Quick
  | /// Audio pipeline and codec tests (~3s).
    Voice
  | /// Comprehensive suite including network and WebRTC (~10s).
    Full

/// Result of a single diagnostic test.
type testResult = {
  /// Human-readable test name (e.g., "WebSocket Connectivity").
  name: string,
  /// Whether the test passed.
  passed: bool,
  /// Execution time in milliseconds.
  durationMs: float,
  /// Detailed result message or error description.
  detail: string,
}

/// Overall self-test response from the server.
type selfTestResponse = {
  /// Whether all tests passed.
  allPassed: bool,
  /// The test mode that was run.
  mode: string,
  /// Individual test results.
  tests: array<testResult>,
  /// Total execution time in milliseconds.
  totalDurationMs: float,
}

type jsObj
external castToJsObj: {..} => jsObj = "%identity"
external castFromJsObj: jsObj => {..} = "%identity"

/// Panel state — tracks the current test run and rendered DOM.
type t = {
  /// Currently selected test mode.
  mutable currentMode: testMode,
  /// Whether a test is currently running.
  mutable isRunning: bool,
  /// Most recent test response (None if no test has been run).
  mutable lastResponse: option<selfTestResponse>,
  /// Error message if the fetch failed.
  mutable errorMessage: option<string>,
  /// The root DOM element for the panel.
  mutable rootElement: option<jsObj>,
}

// ---------------------------------------------------------------------------
// External bindings — DOM and Fetch
// ---------------------------------------------------------------------------

/// Get the document object for DOM manipulation.
@val external document: {..} = "document"

/// Create a new DOM element by tag name.
@val @scope("document")
external createElement: string => {..} = "createElement"

/// Create a text node for DOM insertion.
@val @scope("document")
external createTextNode: string => {..} = "createTextNode"

/// Fetch a URL and return a promise of the Response.
@val external fetch: string => promise<{..}> = "fetch"

/// Access the console for debug logging.
@val external console: {..} = "console"

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Base URL for the self-test API endpoint.
let apiBase = "/api/v1/diagnostics/self-test"

/// Latency threshold for green colour (< 5ms is excellent).
let latencyGreenMs = 5.0

/// Latency threshold for yellow colour (< 15ms is acceptable).
let latencyYellowMs = 15.0

// ---------------------------------------------------------------------------
// Construction
// ---------------------------------------------------------------------------

/// Create initial self-test panel state.
/// The panel starts with no results. Call `render` to build the DOM,
/// which will auto-run a quick test on creation.
let make = (): t => {
  currentMode: Quick,
  isRunning: false,
  lastResponse: None,
  errorMessage: None,
  rootElement: None,
}

// ---------------------------------------------------------------------------
// Helpers — test mode to API path
// ---------------------------------------------------------------------------

/// Convert a test mode to the API endpoint path segment.
let modeToPath = (mode: testMode): string =>
  switch mode {
  | Quick => "quick"
  | Voice => "voice"
  | Full => "full"
  }

/// Display label for a test mode.
let modeLabel = (mode: testMode): string =>
  switch mode {
  | Quick => "Quick"
  | Voice => "Voice"
  | Full => "Full"
  }

// ---------------------------------------------------------------------------
// Helpers — colour coding
// ---------------------------------------------------------------------------

/// Latency colour: green for fast, yellow for moderate, red for slow.
let latencyColor = (ms: float): string =>
  if ms < latencyGreenMs {
    "#44ff44"
  } else if ms < latencyYellowMs {
    "#ffaa44"
  } else {
    "#ff4444"
  }

/// Pass/fail badge colour.
let passFailColor = (passed: bool): string =>
  if passed { "#44ff44" } else { "#ff4444" }

/// Pass/fail badge background.
let passFailBg = (passed: bool): string =>
  if passed { "#1a3a1a" } else { "#3a1a1a" }

// ---------------------------------------------------------------------------
// API fetch — run self-test
// ---------------------------------------------------------------------------

/// Parse the JSON response from the self-test endpoint into our
/// typed selfTestResponse structure.
let parseResponse = (json: {..}): selfTestResponse => {
  let tests: array<{..}> = %raw(`json.tests || []`)
  let parsedTests = tests->Array.map(t => {
    let name: string = %raw(`t.name || "Unknown"`)
    let passed: bool = %raw(`!!t.passed`)
    let durationMs: float = %raw(`t.duration_ms || t.durationMs || 0`)
    let detail: string = %raw(`t.detail || ""`)
    {name, passed, durationMs, detail}
  })

  {
    allPassed: %raw(`!!json.all_passed || !!json.allPassed`),
    mode: %raw(`json.mode || "unknown"`),
    tests: parsedTests,
    totalDurationMs: %raw(`json.total_duration_ms || json.totalDurationMs || 0`),
  }
}

/// Fetch self-test results from the API and update panel state.
/// Triggers a DOM re-render after completion.
let rec runTest = async (panel: t): unit => {
  panel.isRunning = true
  panel.errorMessage = None

  // Update DOM to show loading state.
  updateDom(panel)

  let path = `${apiBase}/${modeToPath(panel.currentMode)}`

  try {
    let response = await fetch(path)
    let ok: bool = response["ok"]
    if ok {
      let json: {..} = await %raw(`response.json()`)
      let result = parseResponse(json)
      panel.lastResponse = Some(result)
      panel.errorMessage = None
    } else {
      let status: int = response["status"]
      panel.errorMessage = Some(`HTTP ${Int.toString(status)}: Self-test request failed`)
      panel.lastResponse = None
    }
  } catch {
  | exn =>
    let msg: string = %raw(`(exn => exn.message || "Network error")`)(exn)
    panel.errorMessage = Some(`Fetch failed: ${msg}`)
    panel.lastResponse = None
    ignore(console["error"](`[Burble:SelfTest] ${msg}`))
  }

  panel.isRunning = false
  updateDom(panel)
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
  btn["className"] = `burble-st-btn ${className}`
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

/// Create a mode selector button with active-state highlighting.
and makeModeButton = (panel: t, mode: testMode): {..} => {
  let isActive = panel.currentMode == mode
  let btn = makeButton(
    ~text=modeLabel(mode),
    ~className=`burble-st-mode-${modeToPath(mode)}`,
    ~title=`Run ${modeLabel(mode)} self-test`,
    ~onClick=() => {
      panel.currentMode = mode
      let _ = runTest(panel)
    },
  )
  if isActive {
    btn["style"]["background"] = "#2a3a4a"
    btn["style"]["borderColor"] = "#4488cc"
  }
  btn
}

/// Create a test result card element. Each card shows the test name,
/// pass/fail badge, timing, and detail text.
and makeTestCard = (result: testResult): {..} => {
  let card = createElement("div")
  card["className"] = "burble-st-card"
  card["style"]["cssText"] = `
    background: #222;
    border: 1px solid ${if result.passed { "#2a4a2a" } else { "#4a2a2a" }};
    border-radius: 8px;
    padding: 12px 16px;
    display: flex;
    flex-direction: column;
    gap: 6px;
    min-width: 200px;
  `

  // ── Header row: test name + pass/fail badge ──
  let header = createElement("div")
  header["style"]["cssText"] = "display: flex; justify-content: space-between; align-items: center;"

  let nameEl = createElement("span")
  nameEl["textContent"] = result.name
  nameEl["style"]["cssText"] = "color: #e0e0e0; font-size: 14px; font-weight: 600;"
  ignore(header["appendChild"](nameEl))

  let badge = createElement("span")
  badge["textContent"] = if result.passed { "PASS" } else { "FAIL" }
  badge["style"]["cssText"] = `
    background: ${passFailBg(result.passed)};
    color: ${passFailColor(result.passed)};
    padding: 2px 8px;
    border-radius: 4px;
    font-size: 11px;
    font-weight: bold;
  `
  ignore(header["appendChild"](badge))
  ignore(card["appendChild"](header))

  // ── Timing row ──
  let timing = createElement("div")
  timing["style"]["cssText"] = "display: flex; align-items: center; gap: 6px;"

  let timingDot = createElement("span")
  timingDot["style"]["cssText"] = `
    display: inline-block;
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: ${latencyColor(result.durationMs)};
  `
  ignore(timing["appendChild"](timingDot))

  let timingText = createElement("span")
  timingText["textContent"] = `${Float.toFixed(result.durationMs, ~digits=1)}ms`
  timingText["style"]["cssText"] = `color: ${latencyColor(result.durationMs)}; font-size: 12px;`
  ignore(timing["appendChild"](timingText))
  ignore(card["appendChild"](timing))

  // ── Detail text ──
  if result.detail != "" {
    let detailEl = createElement("div")
    detailEl["textContent"] = result.detail
    detailEl["style"]["cssText"] = `
      color: #999;
      font-size: 12px;
      line-height: 1.4;
      word-break: break-word;
    `
    ignore(card["appendChild"](detailEl))
  }

  card
}

/// Build the overall pass/fail banner at the top of the panel.
and makeOverallBanner = (response: selfTestResponse): {..} => {
  let banner = createElement("div")
  banner["className"] = "burble-st-banner"
  let bgColor = if response.allPassed { "#1a3a1a" } else { "#3a1a1a" }
  let borderColor = if response.allPassed { "#2a6a2a" } else { "#6a2a2a" }
  let textColor = if response.allPassed { "#44ff44" } else { "#ff4444" }
  banner["style"]["cssText"] = `
    background: ${bgColor};
    border: 1px solid ${borderColor};
    border-radius: 8px;
    padding: 12px 20px;
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 12px;
  `

  let statusText = createElement("span")
  statusText["textContent"] = if response.allPassed {
    "All Tests Passed"
  } else {
    "Some Tests Failed"
  }
  statusText["style"]["cssText"] = `
    color: ${textColor};
    font-size: 16px;
    font-weight: bold;
  `
  ignore(banner["appendChild"](statusText))

  // Show pass/fail counts and total time.
  let passCount = response.tests->Array.filter(t => t.passed)->Array.length
  let totalCount = Array.length(response.tests)
  let summaryText = createElement("span")
  summaryText["textContent"] = `${Int.toString(passCount)}/${Int.toString(totalCount)} passed in ${Float.toFixed(response.totalDurationMs, ~digits=1)}ms`
  summaryText["style"]["cssText"] = "color: #aaa; font-size: 13px;"
  ignore(banner["appendChild"](summaryText))

  banner
}

/// Build the loading/progress indicator element.
and makeLoadingIndicator = (): {..} => {
  let container = createElement("div")
  container["className"] = "burble-st-loading"
  container["style"]["cssText"] = `
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 40px;
    gap: 12px;
  `

  // Simple animated spinner using CSS.
  let spinner = createElement("div")
  spinner["style"]["cssText"] = `
    width: 24px;
    height: 24px;
    border: 3px solid #333;
    border-top-color: #4488cc;
    border-radius: 50%;
    animation: burble-spin 0.8s linear infinite;
  `

  // Inject the keyframe animation if not already present.
  let _: unit = %raw(`(() => {
    if (!document.getElementById('burble-st-keyframes')) {
      const style = document.createElement('style');
      style.id = 'burble-st-keyframes';
      style.textContent = '@keyframes burble-spin { to { transform: rotate(360deg); } }';
      document.head.appendChild(style);
    }
  })()`)

  ignore(container["appendChild"](spinner))

  let label = createElement("span")
  label["textContent"] = "Running diagnostics..."
  label["style"]["cssText"] = "color: #aaa; font-size: 14px;"
  ignore(container["appendChild"](label))

  container
}

/// Build the error display element.
and makeErrorDisplay = (message: string): {..} => {
  let container = createElement("div")
  container["className"] = "burble-st-error"
  container["style"]["cssText"] = `
    background: #3a1a1a;
    border: 1px solid #6a2a2a;
    border-radius: 8px;
    padding: 16px 20px;
    margin-bottom: 12px;
  `

  let icon = createElement("span")
  icon["textContent"] = "Error: "
  icon["style"]["cssText"] = "color: #ff4444; font-weight: bold;"
  ignore(container["appendChild"](icon))

  let text = createElement("span")
  text["textContent"] = message
  text["style"]["cssText"] = "color: #cc8888;"
  ignore(container["appendChild"](text))

  container
}

// ---------------------------------------------------------------------------
// DOM update — rebuild panel content from current state
// ---------------------------------------------------------------------------

/// Update the panel DOM to reflect the current state.
/// Called after each test run completes or mode change.
/// Clears and rebuilds the content area while preserving the root element.
and updateDom = (panel: t): unit => {
  switch panel.rootElement {
  | Some(root) =>
    // Find the content area within the root element.
    let contentArea: {..} = %raw(`root.querySelector('[data-role="content"]')`)
    let isNull: bool = (%raw(`v => v === null`))(contentArea)
    if isNull {
      () // Panel hasn't been rendered yet.
    } else {
      // Clear existing content.
      contentArea["innerHTML"] = ""

      if panel.isRunning {
        // ── Show loading indicator ──
        ignore(contentArea["appendChild"](makeLoadingIndicator()))
      } else {
        // ── Show error if present ──
        switch panel.errorMessage {
        | Some(msg) =>
          ignore(contentArea["appendChild"](makeErrorDisplay(msg)))
        | None => ()
        }

        // ── Show test results ──
        switch panel.lastResponse {
        | Some(response) =>
          // Overall banner.
          ignore(contentArea["appendChild"](makeOverallBanner(response)))

          // Card grid.
          let grid = createElement("div")
          grid["className"] = "burble-st-grid"
          grid["style"]["cssText"] = `
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(220px, 1fr));
            gap: 10px;
          `
          response.tests->Array.forEach(test => {
            ignore(grid["appendChild"](makeTestCard(test)))
          })
          ignore(contentArea["appendChild"](grid))
        | None =>
          if panel.errorMessage == None {
            // No results yet and no error — show placeholder.
            let placeholder = createElement("div")
            placeholder["textContent"] = "No test results yet. Select a mode and run."
            placeholder["style"]["cssText"] = "color: #666; text-align: center; padding: 40px;"
            ignore(contentArea["appendChild"](placeholder))
          }
        }
      }

      // ── Update mode buttons active state ──
      let modeBtns: array<{..}> = %raw(`Array.from(root.querySelectorAll('[data-role="mode-btn"]'))`)
      modeBtns->Array.forEach(btn => {
        let mode: string = btn["getAttribute"]("data-mode")
        let isActive = mode == modeToPath(panel.currentMode)
        if isActive {
          btn["style"]["background"] = "#2a3a4a"
          btn["style"]["borderColor"] = "#4488cc"
        } else {
          btn["style"]["background"] = "#2a2a2a"
          btn["style"]["borderColor"] = "#444"
        }
      })
    }
  | None => ()
  }
}

// ---------------------------------------------------------------------------
// Rendering — build the self-test panel DOM
// ---------------------------------------------------------------------------

/// Render the self-test panel and return the root DOM element.
/// The panel includes a header with mode selector buttons, a content
/// area for results, and a "Run Again" button. A quick test is
/// automatically triggered on render.
///
/// Call this once and append the returned element to your page container.
let render = (panel: t): {..} => {
  // ── Root container ──
  let root = createElement("div")
  root["className"] = "burble-selftest-panel"
  root["style"]["cssText"] = `
    background: #1a1a1a;
    border: 1px solid #333;
    border-radius: 10px;
    padding: 20px;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    max-width: 800px;
    user-select: none;
  `

  // ── Panel title ──
  let title = createElement("h2")
  title["textContent"] = "Diagnostics Self-Test"
  title["style"]["cssText"] = `
    color: #e0e0e0;
    font-size: 18px;
    margin: 0 0 16px 0;
    font-weight: 600;
  `
  ignore(root["appendChild"](title))

  // ── Mode selector row ──
  let modeRow = createElement("div")
  modeRow["style"]["cssText"] = `
    display: flex;
    gap: 8px;
    margin-bottom: 16px;
    align-items: center;
  `

  let modeLabel_ = createElement("span")
  modeLabel_["textContent"] = "Mode:"
  modeLabel_["style"]["cssText"] = "color: #aaa; font-size: 13px; margin-right: 4px;"
  ignore(modeRow["appendChild"](modeLabel_))

  // Create mode buttons with data-mode attribute for update targeting.
  let modes = [Quick, Voice, Full]
  modes->Array.forEach(mode => {
    let btn = makeModeButton(panel, mode)
    ignore(btn["setAttribute"]("data-role", "mode-btn"))
    ignore(btn["setAttribute"]("data-mode", modeToPath(mode)))
    ignore(modeRow["appendChild"](btn))
  })

  // ── Run Again button ──
  let runAgainBtn = makeButton(
    ~text="Run Again",
    ~className="burble-st-run-again",
    ~title="Re-run the current test mode",
    ~onClick=() => {
      let _ = runTest(panel)
    },
  )
  runAgainBtn["style"]["marginLeft"] = "auto"
  ignore(modeRow["appendChild"](runAgainBtn))

  ignore(root["appendChild"](modeRow))

  // ── Content area (populated by updateDom) ──
  let content = createElement("div")
  ignore(content["setAttribute"]("data-role", "content"))
  ignore(root["appendChild"](content))

  panel.rootElement = Some(castToJsObj(root))

  // ── Auto-run quick test on panel open ──
  let _ = runTest(panel)

  root
}

// ---------------------------------------------------------------------------
// Cleanup
// ---------------------------------------------------------------------------

/// Remove the self-test panel from the DOM and reset state.
let destroy = (panel: t): unit => {
  // Remove the root element from the DOM.
  switch panel.rootElement {
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
  panel.rootElement = None
  panel.lastResponse = None
  panel.errorMessage = None
  panel.isRunning = false
}
