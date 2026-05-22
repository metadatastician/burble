// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)

/// BurbleCmd — Backend command dispatch for the Burble Admin panel.
///
/// Each function wraps a Gossamer IPC call to the Burble Elixir server.
/// All network commands require a valid network capability token obtained
/// from the Gossamer runtime via `Capabilities.requestNetworkAccess()`.
///
/// The commands map to the Burble server's REST API:
///   - Health:     GET  /health
///   - Rooms:      GET  /api/rooms, POST /api/rooms
///   - Kick:       POST /api/rooms/{id}/kick
///   - Config:     GET  /api/config, POST /api/config
///   - Stats:      GET  /api/stats
///   - Recording:  POST /api/rooms/{id}/recording
///
/// Gossamer acts as the network proxy — the webview never makes direct
/// HTTP calls. Instead, each command goes through IPC to the Gossamer
/// Zig runtime, which holds the network capability and forwards the
/// request to the Elixir backend.

/// The base URL for the Burble Elixir server.
/// In production this comes from the server config; here we default to
/// the standard local development port.
let _baseUrl = "http://localhost:4000"

// ---------------------------------------------------------------------------
// Health
// ---------------------------------------------------------------------------

/// Check the Burble server health endpoint.
///
/// Maps to: GET /health
/// Returns the server's health status as a JSON string.
/// This is the first command to run after granting network capability.
let checkHealth = (token: float): promise<string> => {
  RuntimeBridge.invokeWithToken(
    "burble_check_health",
    {"url": `${_baseUrl}/health`},
    token,
  )
}

// ---------------------------------------------------------------------------
// Room management
// ---------------------------------------------------------------------------

/// List all voice rooms on the server.
///
/// Maps to: GET /api/rooms
/// Returns a JSON array of room objects with id, name, users, recording.
let listRooms = (token: float): promise<string> => {
  RuntimeBridge.invokeWithToken(
    "burble_list_rooms",
    {"url": `${_baseUrl}/api/rooms`},
    token,
  )
}

/// Create a new voice room.
///
/// Maps to: POST /api/rooms
/// @param name - The room name to create
/// Returns the created room as a JSON string.
let createRoom = (name: string, token: float): promise<string> => {
  RuntimeBridge.invokeWithToken(
    "burble_create_room",
    {"url": `${_baseUrl}/api/rooms`, "name": name},
    token,
  )
}

/// Kick a user from a room.
///
/// Maps to: POST /api/rooms/{roomId}/kick
/// @param roomId - The room to kick from
/// @param userId - The user to kick
/// Returns a confirmation JSON string.
let kickUser = (roomId: string, userId: string, token: float): promise<string> => {
  RuntimeBridge.invokeWithToken(
    "burble_kick_user",
    {
      "url": `${_baseUrl}/api/rooms/${roomId}/kick`,
      "user_id": userId,
    },
    token,
  )
}

// ---------------------------------------------------------------------------
// Server configuration
// ---------------------------------------------------------------------------

/// Get the current server configuration.
///
/// Maps to: GET /api/config
/// Returns the server config as a JSON string.
let getServerConfig = (token: float): promise<string> => {
  RuntimeBridge.invokeWithToken(
    "burble_get_config",
    {"url": `${_baseUrl}/api/config`},
    token,
  )
}

/// Update the server configuration.
///
/// Maps to: POST /api/config
/// @param configJson - The new configuration as a JSON string
/// Returns the updated config as a JSON string.
let updateServerConfig = (configJson: string, token: float): promise<string> => {
  RuntimeBridge.invokeWithToken(
    "burble_update_config",
    {"url": `${_baseUrl}/api/config`, "config": configJson},
    token,
  )
}

// ---------------------------------------------------------------------------
// Voice / WebRTC statistics
// ---------------------------------------------------------------------------

/// Get WebRTC voice statistics from the server.
///
/// Maps to: GET /api/stats
/// Returns metrics including active streams, bandwidth usage, codec info,
/// jitter, packet loss, and latency measurements.
let getVoiceStats = (token: float): promise<string> => {
  RuntimeBridge.invokeWithToken(
    "burble_get_voice_stats",
    {"url": `${_baseUrl}/api/stats`},
    token,
  )
}

// ---------------------------------------------------------------------------
// Recording
// ---------------------------------------------------------------------------

/// Toggle recording for a room.
///
/// Maps to: POST /api/rooms/{roomId}/recording
/// If recording is active, this stops it. If inactive, this starts it.
/// @param roomId - The room to toggle recording for
/// Returns the updated room state as a JSON string.
let toggleRecording = (roomId: string, token: float): promise<string> => {
  RuntimeBridge.invokeWithToken(
    "burble_toggle_recording",
    {"url": `${_baseUrl}/api/rooms/${roomId}/recording`},
    token,
  )
}
