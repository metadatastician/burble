// SPDX-License-Identifier: MPL-2.0
//
// E2EE.res — DISABLED placeholder. The real implementation is e2ee.js.
//
// Until 2026-10-21 this module claimed "AES-256-GCM with HKDF-SHA256 key
// derivation" and encrypted frames with a repeating-key XOR against the local
// private key. Three things made it harmless rather than catastrophic, and all
// three are accidents rather than design:
//
//   * nothing imported it (no module references E2EE.initialize or
//     E2EE.applyToConnection), so no call ever used it;
//   * the generated E2EE.res.mjs in a working tree was not valid JavaScript —
//     it referenced `byte`, `keyByte` and `encryptedBytes`, none of which it
//     defined — so it would have thrown had anything called it (the artifact is
//     gitignored; the source is what shipped);
//   * it derived the "shared" key from the local private key alone, so two
//     peers would not even have agreed on a key.
//
// It is kept as a stub rather than deleted because the path is valuable: it is
// the first place someone looks for client-side E2EE.
//
// The real implementation is client/web/e2ee.js: WebCrypto X25519 + HKDF-SHA256
// + AES-256-GCM, sealed room-key distribution, per-sender frame keys, a replay
// window and an epoch tracker, pinned against the server's own output by
// tests/fixtures/e2ee-vectors.json and tests/e2ee_test.js.
//
// Even there, frames are NOT yet encrypted on the call path: the WebRTC Encoded
// Transform wiring is not written (ADR-0016 §Gaps). Do not re-add a "temporary"
// cipher here without deleting this note first.

/// E2EE is not available from this module.
type state = Disabled

let disabledMessage = "[Burble:E2EE] client/web/src/app/voice/E2EE is a disabled placeholder; use client/web/e2ee.js"

/// Always fails. Kept so that any existing call site fails loudly instead of
/// silently transmitting plaintext, and so a future reader is sent to the real
/// module rather than reconstructing this one.
let initialize = (): result<state, string> => raise(Failure(disabledMessage))
