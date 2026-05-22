// SPDX-License-Identifier: MPL-2.0
//
// App — Burble web client application root.
//
// Manages top-level state and route handling.
// Framework-agnostic core — the rendering layer is separate.
//
// State hierarchy:
//   App
//   ├── AuthState (login/guest/anonymous)
//   ├── Routes (current page via cadre-router)
//   ├── VoiceEngine (WebRTC connection to SFU)
//   ├── VoiceControls (mute/deafen/PTT UI state)
//   └── RoomState (current room participants, messages)

/// Top-level application state.
type rec t = {
  auth: AuthState.t,
  voiceEngine: VoiceEngine.t,
  voiceControls: VoiceControls.t,
  audioPipeline: AudioPipeline.pipelineState,
  mutable currentRoute: Routes.route,
  mutable currentRoom: option<RoomState.t>,
  mutable serverList: array<serverInfo>,
  /// The setup wizard instance (shown on first visit).
  mutable setupWizard: option<SetupWizard.t>,
  /// The self-test panel instance (opened from settings).
  mutable selfTestPanel: option<SelfTestPanel.t>,
  /// Whether the self-test panel is currently visible.
  mutable selfTestVisible: bool,
}

/// Server info for the server list sidebar.
and serverInfo = {
  id: string,
  name: string,
  iconUrl: option<string>,
  roomCount: int,
  memberCount: int,
}

/// External binding for localStorage access.
@val external localStorage: {..} = "localStorage"

/// External binding for document.body access.
@val external documentBody: {..} = "document.body"

/// Create the application state.
/// On creation, checks localStorage for setup wizard completion.
/// If the wizard hasn't been completed, it is shown as a modal overlay.
let make = (): t => {
  let initialRoute = Routes.parse(
    %raw(`window.location.pathname`)
  )

  let app = {
    auth: AuthState.make(),
    voiceEngine: VoiceEngine.make(),
    voiceControls: VoiceControls.make(),
    audioPipeline: AudioPipeline.make(),
    currentRoute: initialRoute,
    currentRoom: None,
    serverList: [],
    setupWizard: None,
    selfTestPanel: None,
    selfTestVisible: false,
  }

  // ── Setup wizard check ──
  // If the user hasn't completed the setup wizard, show it on app load.
  if !SetupWizard.isSetupComplete() {
    let wizard = SetupWizard.make()
    SetupWizard.onComplete(wizard, () => {
      app.setupWizard = None
    })
    let overlay = SetupWizard.render(wizard)
    let _ = documentBody["appendChild"](overlay)
    app.setupWizard = Some(wizard)
  }

  app
}

/// Navigate to a route. Handles auth guards via cadre-router integration.
let navigate = (app: t, route: Routes.route): unit => {
  // Auth guard: redirect to login if route requires auth and user isn't logged in
  if Routes.requiresAuth(route) && !AuthState.isLoggedIn(app.auth) {
    app.currentRoute = Routes.Login
    let _ = %raw(`window.history.pushState(null, "", "/login")`)
  } else if Routes.requiresAdmin(route) && !AuthState.isAdmin(app.auth) {
    // Admin guard: redirect to server view if not admin
    app.currentRoute = Routes.NotFound
  } else {
    app.currentRoute = route
    let path = Routes.toString(route)
    let pageTitle = Routes.title(route)
    let _ = %raw(`window.history.pushState(null, "", path)`)
    let _ = %raw(`document.title = pageTitle`)
  }
}

/// Join a voice room. Connects voice engine and creates room state.
let joinVoiceRoom = (app: t, ~serverId: string, ~roomId: string, ~roomName: string): unit => {
  // Create room state
  let room = RoomState.make(~roomId, ~roomName, ~serverId)
  app.currentRoom = Some(room)

  // Connect voice engine
  let token = AuthState.token(app.auth)->Option.getOr("")
  let _ = VoiceEngine.connect(app.voiceEngine, ~roomId, ~token)

  // Update voice controls
  app.voiceControls.roomName = roomName

  // Navigate to room view
  navigate(app, Room(serverId, roomId))
}

/// Leave the current voice room.
let leaveVoiceRoom = (app: t): unit => {
  VoiceEngine.disconnect(app.voiceEngine)
  app.currentRoom = None
  app.voiceControls.roomName = ""
  app.voiceControls.participantCount = 0
}

/// Handle URL change (browser back/forward).
let handleUrlChange = (app: t, path: string): unit => {
  let route = Routes.parse(path)
  navigate(app, route)
}

/// Guest join flow — create guest session and join server.
let guestJoin = (app: t, ~displayName: string, ~serverId: string): unit => {
  AuthState.setGuest(app.auth, {guestId: "guest_" ++ serverId, guestName: displayName})
  navigate(app, Server(serverId))
}

/// Toggle mute and sync to server.
let toggleMute = (app: t): unit => {
  let newState = VoiceEngine.toggleMute(app.voiceEngine)
  ignore(newState)
  VoiceControls.syncFromEngine(app.voiceControls, app.voiceEngine)
}

/// Toggle deafen and sync to server.
let toggleDeafen = (app: t): unit => {
  let newState = VoiceEngine.toggleDeafen(app.voiceEngine)
  ignore(newState)
  VoiceControls.syncFromEngine(app.voiceControls, app.voiceEngine)
}

// ---------------------------------------------------------------------------
// Self-test panel — accessible from settings
// ---------------------------------------------------------------------------

/// Show the self-test diagnostics panel. Creates a new panel instance
/// and appends it to the document body as a modal.
let rec showSelfTestPanel = (app: t): unit => {
  // Close existing panel if open.
  switch app.selfTestPanel {
  | Some(panel) => SelfTestPanel.destroy(panel)
  | None => ()
  }

  let panel = SelfTestPanel.make()
  let element = SelfTestPanel.render(panel)

  // Wrap in a modal overlay for consistent presentation.
  let overlay: {..} = %raw(`(() => {
    const el = document.createElement('div');
    el.className = 'burble-selftest-overlay';
    el.style.cssText = 'position: fixed; top: 0; left: 0; width: 100vw; height: 100vh; background: rgba(0,0,0,0.7); display: flex; align-items: center; justify-content: center; z-index: 9000;';
    return el;
  })()`)

  // Close on backdrop click.
  overlay["onclick"] = (event: {..}) => {
    let target: {..} = event["target"]
    let isSelf: bool = (%raw(`(a, b) => a === b`))(target, overlay)
    if isSelf {
      hideSelfTestPanel(app)
    }
  }

  let _ = overlay["appendChild"](element)
  let _ = documentBody["appendChild"](overlay)
  app.selfTestPanel = Some(panel)
  app.selfTestVisible = true
}

/// Hide and destroy the self-test diagnostics panel.
and hideSelfTestPanel = (app: t): unit => {
  switch app.selfTestPanel {
  | Some(panel) => SelfTestPanel.destroy(panel)
  | None => ()
  }
  // Remove the overlay element.
  let _: unit = %raw(`(() => {
    const overlay = document.querySelector('.burble-selftest-overlay');
    if (overlay && overlay.parentNode) overlay.parentNode.removeChild(overlay);
  })()`)
  app.selfTestPanel = None
  app.selfTestVisible = false
}

/// Re-open the setup wizard (accessible from settings even after completion).
let showSetupWizard = (app: t): unit => {
  // Destroy any existing wizard first.
  switch app.setupWizard {
  | Some(wiz) => SetupWizard.destroy(wiz)
  | None => ()
  }

  let wizard = SetupWizard.make()
  SetupWizard.onComplete(wizard, () => {
    app.setupWizard = None
  })
  let overlay = SetupWizard.render(wizard)
  let _ = documentBody["appendChild"](overlay)
  app.setupWizard = Some(wizard)
}
