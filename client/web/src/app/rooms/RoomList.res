// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// RoomList — Room list sidebar for the Burble web client.
//
// Displays the list of available voice channels for a server,
// fetched from the REST API at /api/v1/servers/:id/rooms.
//
// Features:
//   - Lists all voice channels with participant count and names
//   - Click to join a room (triggers VoiceEngine.connect)
//   - Highlights the currently active room
//   - "Create Room" button (if user has permission)
//   - Auto-refreshes participant lists via polling
//
// Framework-agnostic: pure DOM manipulation matching the existing
// codebase pattern (no React, no JSX, no TEA).

// ---------------------------------------------------------------------------
// Type definitions
// ---------------------------------------------------------------------------

/// Summary of a participant in a room (for the sidebar display).
type participantSummary = {
  /// User ID for presence correlation.
  userId: string,
  /// Display name shown in the participant list.
  displayName: string,
  /// Voice state string ("active", "muted", "deafened").
  voiceState: string,
}

/// Room descriptor as returned by the server API.
type room = {
  /// Unique room identifier.
  id: string,
  /// Human-readable room name.
  name: string,
  /// Room type ("voice", "stage", "afk").
  roomType: string,
  /// Maximum number of participants (0 = unlimited).
  maxParticipants: int,
  /// Current participants in the room.
  participants: array<participantSummary>,
  /// Whether the room is locked (requires permission to join).
  isLocked: bool,
  /// Bitrate in kbps (for display).
  bitrate: int,
}

type jsObj
external castToJsObj: {..} => jsObj = "%identity"
external castFromJsObj: jsObj => {..} = "%identity"

/// Room list sidebar state.
type t = {
  /// The server ID whose rooms we are displaying.
  mutable serverId: string,
  /// All rooms fetched from the server.
  mutable rooms: array<room>,
  /// The currently active (joined) room ID, if any.
  mutable activeRoomId: option<string>,
  /// Whether a fetch is in progress.
  mutable isLoading: bool,
  /// Error message from the last failed fetch, if any.
  mutable errorMessage: option<string>,
  /// Whether the user has permission to create rooms.
  mutable canCreateRoom: bool,
  /// The root DOM element for the sidebar (created by render).
  mutable rootElement: option<jsObj>,
  /// Interval ID for the auto-refresh polling timer.
  mutable refreshIntervalId: option<Nullable.t<float>>,
  /// Callback invoked when the user clicks a room to join.
  /// Receives (serverId, roomId, roomName).
  mutable onJoinRoom: option<(string, string, string) => unit>,
  /// Callback invoked when the user clicks "Create Room".
  mutable onCreateRoom: option<unit => unit>,
}

// ---------------------------------------------------------------------------
// External bindings
// ---------------------------------------------------------------------------

/// Create a new DOM element.
@val @scope("document")
external createElement: string => {..} = "createElement"

/// Fetch a URL and return a promise of the response.
@val external fetch: string => promise<{..}> = "fetch"

/// Set a recurring timer. Returns an opaque interval ID.
@val external setInterval: (unit => unit, int) => Nullable.t<float> = "setInterval"

/// Cancel a recurring timer by its interval ID.
@val external clearInterval: Nullable.t<float> => unit = "clearInterval"

external castToJsObj: 'a => jsObj = "%identity"

// ---------------------------------------------------------------------------
// Construction
// ---------------------------------------------------------------------------

/// Create a new RoomList state for the given server.
/// Call fetchRooms to populate and render to build the DOM.
let make = (~serverId: string): t => {
  serverId,
  rooms: [],
  activeRoomId: None,
  isLoading: false,
  errorMessage: None,
  canCreateRoom: false,
  rootElement: None,
  refreshIntervalId: None,
  onJoinRoom: None,
  onCreateRoom: None,
}

// ---------------------------------------------------------------------------
// API data fetching
// ---------------------------------------------------------------------------

/// Fetch the list of rooms from the Burble REST API.
/// Endpoint: GET /api/v1/servers/:id/rooms
///
/// The response is expected to be a JSON array of room objects.
/// On success, updates the rooms array and re-renders.
/// On failure, sets the error message for display.
let rec fetchRooms = async (state: t): unit => {
  state.isLoading = true
  state.errorMessage = None

  let url = `/api/v1/servers/${state.serverId}/rooms`

  try {
    let response = await fetch(url)
    let ok: bool = response["ok"]

    if ok {
      let json: JSON.t = await response["json"]()

      // Parse the JSON response into room records.
      // The API returns an array of room objects with participants nested.
      let rawRooms: array<{..}> = %raw(`Array.isArray(json) ? json : (json.rooms || [])`)

      state.rooms = rawRooms->Array.map(raw => {
        let rawParticipants: array<{..}> = %raw(`raw.participants || []`)
        let participants = rawParticipants->Array.map(p => {
          userId: p["user_id"],
          displayName: p["display_name"],
          voiceState: p["voice_state"],
        })

        {
          id: raw["id"],
          name: raw["name"],
          roomType: %raw(`raw.room_type || raw.type || "voice"`),
          maxParticipants: %raw(`raw.max_participants || 0`),
          participants,
          isLocked: %raw(`!!raw.is_locked`),
          bitrate: %raw(`raw.bitrate || 64`),
        }
      })

      state.isLoading = false
      Console.log2("[Burble] Fetched rooms:", Int.toString(Array.length(state.rooms)))

      // Re-render if mounted.
      switch state.rootElement {
      | Some(_) => updateDom(state)
      | None => ()
      }
    } else {
      let status: int = response["status"]
      state.errorMessage = Some(`Failed to fetch rooms (HTTP ${Int.toString(status)})`)
      state.isLoading = false
      Console.error2("[Burble] Room fetch failed:", Int.toString(status))
    }
  } catch {
  | exn =>
    let msg: string = %raw(`(exn => exn.message || "Network error")`)(exn)
    state.errorMessage = Some(msg)
    state.isLoading = false
    Console.error2("[Burble] Room fetch error:", msg)
  }
}

// ---------------------------------------------------------------------------
// DOM rendering helpers
// ---------------------------------------------------------------------------

/// Build the DOM subtree for a single room list item.
/// Shows room name, participant count, participant names, and join affordance.
and renderRoomItem = (state: t, room: room): {..} => {
  let item = createElement("div")
  item["className"] = "burble-room-item"

  // Highlight the active room with a different background.
  let isActive = switch state.activeRoomId {
  | Some(id) => id == room.id
  | None => false
  }

  let bgColor = if isActive { "#2a3a2a" } else { "#1e1e1e" }
  let borderColor = if isActive { "#4a8" } else { "#333" }

  item["style"]["cssText"] = `
    padding: 8px 12px;
    margin: 2px 0;
    background: ${bgColor};
    border-left: 3px solid ${borderColor};
    border-radius: 0 4px 4px 0;
    cursor: pointer;
    transition: background 0.15s;
  `

  // ── Room header: name + participant count ──
  let header = createElement("div")
  header["style"]["cssText"] = `
    display: flex;
    justify-content: space-between;
    align-items: center;
  `

  // Room name with type icon prefix.
  let nameSpan = createElement("span")
  let typeIcon = switch room.roomType {
  | "stage" => "Stage"
  | "afk" => "AFK"
  | _ => "Voice"
  }
  nameSpan["textContent"] = `${typeIcon} | ${room.name}`
  nameSpan["style"]["cssText"] = `
    color: #e0e0e0;
    font-size: 14px;
    font-weight: ${if isActive { "bold" } else { "normal" }};
  `

  // Participant count badge.
  let countBadge = createElement("span")
  let participantCount = Array.length(room.participants)
  let countText = if room.maxParticipants > 0 {
    `${Int.toString(participantCount)}/${Int.toString(room.maxParticipants)}`
  } else {
    Int.toString(participantCount)
  }
  countBadge["textContent"] = countText
  countBadge["style"]["cssText"] = `
    color: #888;
    font-size: 12px;
    background: #2a2a2a;
    padding: 1px 6px;
    border-radius: 10px;
  `

  ignore(header["appendChild"](nameSpan))
  ignore(header["appendChild"](countBadge))
  ignore(item["appendChild"](header))

  // ── Lock indicator ──
  if room.isLocked {
    let lockSpan = createElement("span")
    lockSpan["textContent"] = "Locked"
    lockSpan["style"]["cssText"] = `
      color: #ff8844;
      font-size: 11px;
      margin-left: 8px;
    `
    ignore(header["appendChild"](lockSpan))
  }

  // ── Participant names list ──
  if participantCount > 0 {
    let participantList = createElement("div")
    participantList["style"]["cssText"] = `
      margin-top: 4px;
      padding-left: 12px;
    `

    room.participants->Array.forEach(p => {
      let pSpan = createElement("div")

      // Voice state indicator (dot colour).
      let stateColor = switch p.voiceState {
      | "muted" => "#ffaa44"
      | "deafened" => "#666"
      | _ => "#44ff44"
      }

      pSpan["style"]["cssText"] = `
        color: #aaa;
        font-size: 12px;
        padding: 1px 0;
        display: flex;
        align-items: center;
        gap: 4px;
      `

      // State dot.
      let dot = createElement("span")
      dot["style"]["cssText"] = `
        display: inline-block;
        width: 6px;
        height: 6px;
        border-radius: 50%;
        background: ${stateColor};
      `
      ignore(pSpan["appendChild"](dot))

      // Display name.
      let nameNode = createElement("span")
      nameNode["textContent"] = p.displayName
      ignore(pSpan["appendChild"](nameNode))

      ignore(participantList["appendChild"](pSpan))
    })

    ignore(item["appendChild"](participantList))
  }

  // ── Click handler: join the room ──
  item["onclick"] = (_: {..}) => {
    if !room.isLocked {
      state.activeRoomId = Some(room.id)
      switch state.onJoinRoom {
      | Some(cb) => cb(state.serverId, room.id, room.name)
      | None => ()
      }
      updateDom(state)
    }
  }

  // Hover effect.
  item["onmouseenter"] = (_: {..}) => {
    if !isActive {
      item["style"]["background"] = "#252525"
    }
  }
  item["onmouseleave"] = (_: {..}) => {
    if !isActive {
      item["style"]["background"] = bgColor
    }
  }

  item
}

/// Update the DOM to reflect the current rooms state.
/// Clears and rebuilds the room list container.
and updateDom = (state: t): unit => {
  switch state.rootElement {
  | Some(root) =>
    // Find the room list container within the root.
    let listContainer: {..} = %raw(`root.querySelector('[data-role="room-list"]')`)
    let isNull: bool = (%raw(`v => v === null`))(listContainer)
    if !isNull {
      // Clear existing children.
      listContainer["innerHTML"] = ""

      if state.isLoading {
        // Loading indicator.
        let loadingEl = createElement("div")
        loadingEl["textContent"] = "Loading rooms..."
        loadingEl["style"]["cssText"] = "color: #888; padding: 12px; text-align: center; font-size: 13px;"
        ignore(listContainer["appendChild"](loadingEl))
      } else {
        switch state.errorMessage {
        | Some(errMsg) =>
          // Error message display.
          let errEl = createElement("div")
          errEl["textContent"] = errMsg
          errEl["style"]["cssText"] = "color: #ff4444; padding: 12px; text-align: center; font-size: 13px;"
          ignore(listContainer["appendChild"](errEl) )
        | None =>
          if Array.length(state.rooms) == 0 {
            // Empty state.
            let emptyEl = createElement("div")
            emptyEl["textContent"] = "No voice channels"
            emptyEl["style"]["cssText"] = "color: #666; padding: 12px; text-align: center; font-size: 13px;"
            ignore(listContainer["appendChild"](emptyEl))
          } else {
            // Render each room item.
            state.rooms->Array.forEach(room => {
              let item = renderRoomItem(state, room)
              ignore(listContainer["appendChild"](item))
            })
          }
        }
      }
    }
  | None => ()
  }
}

// ---------------------------------------------------------------------------
// Rendering — build the sidebar DOM
// ---------------------------------------------------------------------------

/// Render the room list sidebar and return the root DOM element.
/// The sidebar includes a header with the section title and
/// an optional "Create Room" button.
///
/// Call this once and append to your layout container.
/// The room list auto-refreshes every 10 seconds.
let render = (state: t): {..} => {
  // ── Root sidebar container ──
  let sidebar = createElement("div")
  sidebar["className"] = "burble-room-list"
  sidebar["style"]["cssText"] = `
    display: flex;
    flex-direction: column;
    width: 240px;
    min-height: 100%;
    background: #1a1a1a;
    border-right: 1px solid #333;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    overflow-y: auto;
  `

  // ── Header ──
  let header = createElement("div")
  header["style"]["cssText"] = `
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 12px;
    border-bottom: 1px solid #333;
  `

  let title = createElement("span")
  title["textContent"] = "Voice Channels"
  title["style"]["cssText"] = `
    color: #ccc;
    font-size: 12px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.5px;
  `
  ignore(header["appendChild"](title))

  // "Create Room" button (visible only if user has permission).
  if state.canCreateRoom {
    let createBtn = createElement("button")
    createBtn["textContent"] = "+"
    createBtn["title"] = "Create a new voice channel"
    createBtn["style"]["cssText"] = `
      background: none;
      border: none;
      color: #888;
      font-size: 18px;
      cursor: pointer;
      padding: 0 4px;
      line-height: 1;
      transition: color 0.15s;
    `
    createBtn["onclick"] = (_: {..}) => {
      switch state.onCreateRoom {
      | Some(cb) => cb()
      | None => ()
      }
    }
    createBtn["onmouseenter"] = (_: {..}) => { createBtn["style"]["color"] = "#e0e0e0" }
    createBtn["onmouseleave"] = (_: {..}) => { createBtn["style"]["color"] = "#888" }
    ignore(header["appendChild"](createBtn))
  }

  ignore(sidebar["appendChild"](header))

  // ── Room list container (populated by updateDom) ──
  let listContainer = createElement("div")
  ignore(listContainer["setAttribute"]("data-role", "room-list"))
  listContainer["style"]["cssText"] = "flex: 1;"
  ignore(sidebar["appendChild"](listContainer))

  state.rootElement = Some(castToJsObj(sidebar))

  // Initial render of the room items.
  updateDom(state)

  // Fetch rooms from the server API.
  let _ = fetchRooms(state)

  // Start auto-refresh polling every 10 seconds.
  let intervalId = setInterval(() => {
    let _ = fetchRooms(state)
  }, 10000)
  state.refreshIntervalId = Some(intervalId)

  sidebar
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Set the active room ID (call when the user joins a room).
let setActiveRoom = (state: t, roomId: string): unit => {
  state.activeRoomId = Some(roomId)
  updateDom(state)
}

/// Clear the active room (call when the user leaves a room).
let clearActiveRoom = (state: t): unit => {
  state.activeRoomId = None
  updateDom(state)
}

/// Register a callback for when the user clicks a room to join.
/// The callback receives (serverId, roomId, roomName).
let onJoinRoom = (state: t, cb: (string, string, string) => unit): unit => {
  state.onJoinRoom = Some(cb)
}

/// Register a callback for when the user clicks "Create Room".
let onCreateRoom = (state: t, cb: unit => unit): unit => {
  state.onCreateRoom = Some(cb)
}

/// Set whether the user has permission to create rooms.
let setCanCreateRoom = (state: t, canCreate: bool): unit => {
  state.canCreateRoom = canCreate
}

/// Force a refresh of the room list from the server.
let refresh = async (state: t): unit => {
  await fetchRooms(state)
}

/// Stop the auto-refresh timer and remove the sidebar from the DOM.
/// Call this when the component is being unmounted.
let destroy = (state: t): unit => {
  // Stop the auto-refresh timer.
  switch state.refreshIntervalId {
  | Some(id) => clearInterval(id)
  | None => ()
  }
  state.refreshIntervalId = None

  // Remove the root element from the DOM.
  switch state.rootElement {
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
  state.rootElement = None
}

/// Get the participant count for a specific room.
let roomParticipantCount = (state: t, roomId: string): int => {
  state.rooms
  ->Array.find(r => r.id == roomId)
  ->Option.map(r => Array.length(r.participants))
  ->Option.getOr(0)
}

/// Get the total number of rooms.
let roomCount = (state: t): int => Array.length(state.rooms)
