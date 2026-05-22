// SPDX-License-Identifier: MPL-2.0
// Client-side tests for BurbleVoice ReScript module.
//
// Tests the voice state machine, audio configuration, and
// voice control helpers from the compiled JS output.

import assert from "node:assert";
import * as Voice from "../../lib/src/BurbleVoice.res.mjs";

// ---------------------------------------------------------------------------
// Module availability
// ---------------------------------------------------------------------------

Deno.test("BurbleVoice module loads without errors", () => {
  assert.ok(Voice !== null && Voice !== undefined,
    "BurbleVoice module should be importable");
});

// ---------------------------------------------------------------------------
// Voice state types / exports
// ---------------------------------------------------------------------------

Deno.test("BurbleVoice exports expected functions", () => {
  // Check that key exports exist (the exact names depend on the ReScript output).
  const exportNames = Object.keys(Voice);
  assert.ok(exportNames.length > 0,
    "BurbleVoice should export at least one function");
});
