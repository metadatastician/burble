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

/**
 * Start a server script under whichever runtime is running the tests.
 *
 * The four spawned-server suites were pinned to `new Deno.Command("deno", …)`,
 * which is why `bun test tests/` could not run 26 of them: there was no process
 * to talk to, not a failing assertion. The scripts themselves are now
 * runtime-neutral (see signalling/runtime.js), so the only difference left is
 * how a child process is created and how permissions are spelled — Bun has
 * none, Deno needs them on the command line.
 *
 * @param {string} script   path to the script, relative to `cwd`
 * @param {{cwd: string, env?: Record<string,string>}} options
 * @returns {Promise<{kill: (signal?: string) => void}>}
 */
export async function spawnServer(script, { cwd, env = {} } = {}) {
  if (useDeno) {
    const command = new globalThis.Deno.Command(globalThis.Deno.execPath(), {
      // --allow-env: the servers read their port/token from the environment at
      // module load, so the child needs it from the first line.
      args: ["run", "--allow-net", "--allow-env", script],
      cwd,
      env,
      stdout: "null",
      stderr: "null"
    });

    const child = command.spawn();
    return {
      kill(signal = "SIGTERM") {
        try {
          child.kill(signal);
        } catch {
          // already gone
        }
      }
    };
  }

  const bun = globalThis.Bun;
  const child = bun.spawn({
    // `process.execPath` is the Bun binary when running under Bun, so the child
    // uses the same runtime as the parent without hard-coding a path.
    cmd: [globalThis.process.execPath, script],
    cwd,
    env: { ...globalThis.process.env, ...env },
    stdout: "ignore",
    stderr: "ignore"
  });

  return {
    kill(signal = "SIGTERM") {
      try {
        child.kill(signal);
      } catch {
        // already gone
      }
    }
  };
}
