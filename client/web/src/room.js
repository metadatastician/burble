// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)

/**
 * Burble Room Utilities - Client-side room name generation and validation
 * 
 * Provides user-friendly room name generation using the same word list
 * as the server for consistent behavior.
 */

// Word list matching server's RoomNamer wordlist
const WORD_LIST = [
  "apple", "banana", "cat", "dog", "elephant", "fish", "garden", "house",
  "igloo", "jungle", "kite", "lemon", "mountain", "notebook", "orange",
  "pencil", "queen", "river", "sun", "tree", "umbrella", "violin",
  "water", "xylophone", "yellow", "zebra", "book", "chair", "desk",
  "door", "floor", "glass", "hand", "island", "jacket", "kitchen",
  "lamp", "mirror", "nest", "ocean", "paper", "quilt", "radio",
  "shoe", "table", "violin", "window", "yard", "zero"
];

/**
 * Generate a random room name using three words
 * 
 * @returns {string} Room name in format "word-word-word"
 */
export function generateRoomName() {
  return `${pickRandomWord()}-${pickRandomWord()}-${pickRandomWord()}`;
}

/**
 * Pick a random word from the word list
 *
 * Uses the Web Crypto CSPRNG rather than Math.random(): room names gate
 * access to a private voice room, so they must not be predictable. Uniform
 * selection via rejection sampling to avoid modulo bias.
 *
 * @returns {string} Random word
 */
function pickRandomWord() {
  const range = WORD_LIST.length;
  const limit = Math.floor(0x100000000 / range) * range;
  const buf = new Uint32Array(1);
  let n;
  do {
    crypto.getRandomValues(buf);
    n = buf[0];
  } while (n >= limit);
  return WORD_LIST[n % range];
}

/**
 * Validate a room name format
 * 
 * @param {string} name - Room name to validate
 * @returns {boolean} True if valid format
 */
export function isValidRoomName(name) {
  return /^[a-z]+-[a-z]+-[a-z]+$/.test(name);
}

/**
 * Generate a shareable room URL
 * 
 * @param {string} roomName - Room name
 * @param {string} baseUrl - Base URL (default: current origin)
 * @returns {string} Full room URL
 */
export function generateRoomUrl(roomName, baseUrl = window.location.origin) {
  return `${baseUrl}/join?room=${encodeURIComponent(roomName)}`;
}

/**
 * Extract room name from URL parameters
 * 
 * @returns {string|null} Room name or null if not found
 */
export function getRoomNameFromUrl() {
  const urlParams = new URLSearchParams(window.location.search);
  const roomName = urlParams.get('room');
  return roomName && isValidRoomName(roomName) ? roomName : null;
}