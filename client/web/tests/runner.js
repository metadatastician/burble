// SPDX-License-Identifier: MPL-2.0
//
// runner.js — one `test` binding for every runner we support.
//
// The estate runs Bun first; Deno is still used by the web-client CI job and by
// anybody who already has it. Both expose the same shape for what these tests
// need — `test(name, async fn)` — so the difference belongs in one place rather
// than in twelve files.
//
// `Deno` is read off globalThis rather than imported, because importing `Deno`
// anywhere is what makes a file unrunnable outside Deno.

const useDeno = typeof globalThis.Deno?.test === "function";

// Deno also accepts `test({ name, fn })`. Bun does not, so the object form is
// unpacked here rather than rewritten in every file that uses it.
const bunTest = useDeno ? null : (await import("bun:test")).test;

/** @type {(name: string | {name: string, fn: Function, ignore?: boolean}, fn?: Function) => void} */
export const test = useDeno
  ? (name, fn) => (typeof name === "object" ? globalThis.Deno.test(name) : globalThis.Deno.test(name, fn))
  : (name, fn) =>
      typeof name === "object" ? bunTest(name.name, name.fn) : bunTest(name, fn);

export default test;
