// SPDX-License-Identifier: MPL-2.0
//
// BurbleProfile — Use-case presets for BurbleClient.
//
// Profiles are thin configuration layers (not code) that tune Burble
// for specific scenarios. They set defaults for latency, quality,
// input mode, and feature flags.
//
// Profiles can be composed: start with a base profile, then override
// specific settings for your application.

/// Predefined profile for gaming voice chat (IDApTIK).
///
/// Optimised for:
/// - Low latency (20ms target)
/// - Push-to-talk default (reduce background noise during gameplay)
/// - Spatial audio enabled (3D positional sound)
/// - Noise suppression ON (keyboard/controller noise)
/// - Echo cancellation OFF (gaming headsets handle this)
/// - E2EE OFF by default (latency priority; enable per-room)
let gaming: BurbleClient.profileConfig = {
  inputMode: BurbleClient.PushToTalk("KeyV"),
  noiseSuppression: true,
  echoCancellation: false,
  spatialAudio: true,
  e2ee: false,
  targetLatencyMs: 20,
  bitrateKbps: 32,
}

/// Predefined profile for workspace voice (PanLL).
///
/// Optimised for:
/// - Voice activity detection (hands-free, always-on)
/// - Noise suppression ON (office/home noise)
/// - Echo cancellation ON (speaker+mic setups)
/// - No spatial audio (flat conference style)
/// - E2EE ON (workspace conversations are sensitive)
/// - Higher bitrate for speech clarity
let workspace: BurbleClient.profileConfig = {
  inputMode: BurbleClient.VoiceActivity,
  noiseSuppression: true,
  echoCancellation: true,
  spatialAudio: false,
  e2ee: true,
  targetLatencyMs: 40,
  bitrateKbps: 48,
}

/// Predefined profile for broadcast/stage mode.
///
/// Optimised for:
/// - One speaker, many listeners
/// - Highest audio quality
/// - Higher latency acceptable (buffering for smooth playback)
/// - No E2EE (audience can't all hold keys)
let broadcast: BurbleClient.profileConfig = {
  inputMode: BurbleClient.VoiceActivity,
  noiseSuppression: true,
  echoCancellation: true,
  spatialAudio: false,
  e2ee: false,
  targetLatencyMs: 100,
  bitrateKbps: 96,
}

/// Predefined profile for maximum privacy.
///
/// All security features enabled, at the cost of latency.
/// Suitable for sensitive conversations.
let maxPrivacy: BurbleClient.profileConfig = {
  inputMode: BurbleClient.PushToTalk("Space"),
  noiseSuppression: true,
  echoCancellation: true,
  spatialAudio: false,
  e2ee: true,
  targetLatencyMs: 60,
  bitrateKbps: 32,
}

/// Merge a base profile with overrides.
/// Any field in `overrides` replaces the corresponding field in `base`.
let merge = (base: BurbleClient.profileConfig, overrides: BurbleClient.profileConfig): BurbleClient.profileConfig => {
  // Since profileConfig is a record, this is a full replacement.
  // In practice, consumers would only override specific fields.
  // This function exists for documentation — use record update syntax instead:
  //   {...BurbleProfile.gaming, e2ee: true, bitrateKbps: 48}
  ignore(base)
  overrides
}
