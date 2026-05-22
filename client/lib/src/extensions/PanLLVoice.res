// SPDX-License-Identifier: MPL-2.0
//
// PanLLVoice — Burble extension for PanLL workspace voice integration.
//
// Provides the voice layer for PanLL's workspace panels. Designed to
// work with PanLL's TEA architecture and PanelBus event system.
//
// Features:
//   - Always-on voice with VAD (like Slack huddles)
//   - Per-panel audio channels (each panel can have its own voice room)
//   - VoiceTag integration (code annotations from speech-to-text)
//   - PanelBus event emission on voice state changes
//   - Graceful degradation when Burble server is unavailable
//
// Integration path for PanLL:
//   1. PanLL's TauriEvents.res adds a "burble:*" channel subscription
//   2. PanLL's Update.res handles BurbleMsg variants
//   3. BurbleEngine.res (in PanLL) wraps this extension's API
//   4. PanelBus emits TopicUI events on voice state changes
//
// This extension is extracted to Burble's client/lib/ (not PanLL's repo)
// so Burble can ship it as an optional module for any workspace integration.

/// Panel voice context (which panel initiated the voice session).
type panelContext =
  | GlobalHuddle          // Workspace-wide voice (no specific panel)
  | PanelSpecific(string) // Voice tied to a specific panel ID
  | PairProgramming       // Two-person focused voice session
  | Review                // Code review voice session (with recording)

/// VoiceTag event — when speech is recognised and annotated.
type voiceTagEvent = {
  transcript: string,
  panelId: option<string>,
  filePath: option<string>,
  lineRange: option<(int, int)>,
  tagType: string,
  confidence: float,
}

/// PanelBus-compatible event for voice state changes.
/// These events should be emitted through PanLL's PanelBus.
type panelBusEvent =
  | VoiceSessionStarted({panelContext: panelContext, roomId: string})
  | VoiceSessionEnded({panelContext: panelContext})
  | SpeechStarted({userId: string, displayName: string})
  | SpeechEnded({userId: string})
  | VoiceTagCreated(voiceTagEvent)
  | VoiceError(string)

/// Extension state.
type panllState = {
  mutable context: panelContext,
  mutable activeRoomId: option<string>,
  mutable speechToTextEnabled: bool,
  mutable recordingConsent: bool,
  mutable onPanelBusEvent: option<panelBusEvent => unit>,
  mutable onVoiceTag: option<voiceTagEvent => unit>,
}

let state: panllState = {
  context: GlobalHuddle,
  activeRoomId: None,
  speechToTextEnabled: false,
  recordingConsent: false,
  onPanelBusEvent: None,
  onVoiceTag: None,
}

// ---------------------------------------------------------------------------
// Configuration (called by PanLL's BurbleEngine)
// ---------------------------------------------------------------------------

/// Set the panel context for the current voice session.
let setContext = (ctx: panelContext): unit => {
  state.context = ctx
}

/// Enable/disable speech-to-text for VoiceTag integration.
let setSpeechToText = (enabled: bool): unit => {
  state.speechToTextEnabled = enabled
}

/// Set recording consent (required before any recording can start).
let setRecordingConsent = (consent: bool): unit => {
  state.recordingConsent = consent
}

/// Register a callback for PanelBus-compatible events.
/// PanLL's BurbleEngine should register this to bridge events
/// into PanelBus.emit().
let onPanelBusEvent = (handler: panelBusEvent => unit): unit => {
  state.onPanelBusEvent = Some(handler)
}

/// Register a callback for VoiceTag events.
/// PanLL's VoiceTagEngine should register this to receive
/// speech-to-text annotations.
let onVoiceTag = (handler: voiceTagEvent => unit): unit => {
  state.onVoiceTag = Some(handler)
}

// ---------------------------------------------------------------------------
// Event emission helpers
// ---------------------------------------------------------------------------

let emitPanelBus = (event: panelBusEvent): unit => {
  switch state.onPanelBusEvent {
  | Some(handler) => handler(event)
  | None => ()
  }
}

let emitVoiceTag = (event: voiceTagEvent): unit => {
  switch state.onVoiceTag {
  | Some(handler) => handler(event)
  | None => ()
  }
}

// ---------------------------------------------------------------------------
// Extension interface
// ---------------------------------------------------------------------------

/// Create the BurbleClient extension for PanLL.
/// Register with: BurbleClient.make({...config, extensions: [PanLLVoice.makeExtension()]})
let makeExtension = (): BurbleClient.extension => {
  {
    name: "panll-voice",
    onConnect: Some(_client => {
      state.context = GlobalHuddle
      state.activeRoomId = None
    }),
    onRoomJoin: Some((_client, roomId) => {
      state.activeRoomId = Some(roomId)
      emitPanelBus(VoiceSessionStarted({panelContext: state.context, roomId}))
    }),
    onRoomLeave: Some(_client => {
      emitPanelBus(VoiceSessionEnded({panelContext: state.context}))
      state.activeRoomId = None
    }),
    onVoiceFrame: None, // PanLL doesn't process audio frames directly.
    onParticipantChange: Some((_client, participant) => {
      // Emit speaking events for PanelBus subscribers.
      if participant.isSpeaking {
        emitPanelBus(SpeechStarted({
          userId: participant.id,
          displayName: participant.displayName,
        }))
      } else {
        emitPanelBus(SpeechEnded({userId: participant.id}))
      }
    }),
    onDisconnect: Some(_client => {
      state.activeRoomId = None
      emitPanelBus(VoiceSessionEnded({panelContext: state.context}))
    }),
  }
}
