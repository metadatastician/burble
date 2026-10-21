// SPDX-License-Identifier: MPL-2.0
//
// runner.js — one `test` binding for every runner we support.
//
// Bun is the runner: it is what CI uses and what the docs tell you to use. Both
// Bun and Deno expose the same shape for what these tests need —
// `test(name, async fn)` — so the difference belongs in one place rather than in
// twelve files. The Deno branch costs four lines and is not exercised by CI.
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
 * Sleeps are not a readiness check. `waitReady()` polls the URL the tests are
 * about to use and, if the child has died, throws with its stderr attached; a
 * CI failure then reports "the server said why" instead of ten wrong status
 * codes from a request that went somewhere else. `stop()` waits for the process
 * to actually exit, so the next test cannot inherit a stale listener on the
 * same port (which presents exactly like "every status code is wrong").
 *
 * @param {string} script   path to the script, relative to `cwd`
 * @param {{cwd: string, env?: Record<string,string>}} options
 */
export async function spawnServer(script, { cwd, env = {} } = {}) {
  const output = { stdout: "", stderr: "", exitCode: null, signal: null };

  const pump = (stream, key) => {
    if (!stream) return;
    (async () => {
      const decoder = new TextDecoder();
      try {
        for await (const chunk of stream) output[key] += decoder.decode(chunk, { stream: true });
      } catch {
        // stream closed with the process; whatever was captured is enough
      }
    })();
  };

  const describe = () => {
    const tail = (text) => text.trim().split("\n").slice(-12).join("\n") || "(no output)";
    return [
      `script: ${script}`,
      `exit: ${output.exitCode === null ? "still running" : output.exitCode}`,
      `stdout:\n${tail(output.stdout)}`,
      `stderr:\n${tail(output.stderr)}`
    ].join("\n");
  };

  let child;
  let exited;

  if (useDeno) {
    const command = new globalThis.Deno.Command(globalThis.Deno.execPath(), {
      // --allow-env: the servers read their port/token from the environment at
      // module load, so the child needs it from the first line.
      args: ["run", "--allow-net", "--allow-env", script],
      cwd,
      env,
      stdout: "piped",
      stderr: "piped"
    });

    child = command.spawn();
    pump(child.stdout, "stdout");
    pump(child.stderr, "stderr");
    exited = child.status.then((status) => {
      output.exitCode = status.code;
      output.signal = status.signal;
    });
  } else {
    const bun = globalThis.Bun;
    child = bun.spawn({
      // `process.execPath` is the Bun binary when running under Bun, so the
      // child uses the same runtime as the parent without hard-coding a path.
      cmd: [globalThis.process.execPath, script],
      cwd,
      env: { ...globalThis.process.env, ...env },
      stdout: "pipe",
      stderr: "pipe"
    });

    pump(child.stdout, "stdout");
    pump(child.stderr, "stderr");
    exited = child.exited.then((code) => {
      output.exitCode = code;
      output.signal = child.signalCode ?? null;
    });
  }

  const handle = {
    /** Kill the child. Idempotent. */
    kill(signal = "SIGTERM") {
      try {
        child.kill(signal);
      } catch {
        // already gone
      }
    },

    /** Kill the child and wait for it to exit, so its port is released. */
    async stop(timeoutMs = 5000) {
      handle.kill("SIGTERM");
      const done = await Promise.race([
        exited.then(() => true),
        new Promise((r) => setTimeout(() => r(false), timeoutMs))
      ]);
      if (!done) {
        handle.kill("SIGKILL");
        await Promise.race([exited, new Promise((r) => setTimeout(r, 1000))]);
      }
    },

    /** Poll `url` until something answers. Throws with the child's output. */
    async waitReady(url, { timeoutMs = 20000, intervalMs = 100 } = {}) {
      const deadline = Date.now() + timeoutMs;
      let lastError = null;

      while (Date.now() < deadline) {
        if (output.exitCode !== null) {
          throw new Error(`server exited before ${url} was ready\n${describe()}`);
        }
        try {
          const res = await fetch(url, { signal: AbortSignal.timeout(2000) });
          await res.body?.cancel().catch(() => {});
          return;
        } catch (error) {
          lastError = error;
        }
        await new Promise((r) => setTimeout(r, intervalMs));
      }

      throw new Error(
        `server not ready at ${url} after ${timeoutMs}ms (${lastError?.message ?? "no response"})\n${describe()}`
      );
    },

    /** Captured output, for assertions and for failure messages. */
    output() {
      return { ...output };
    },

    describe
  };

  return handle;
}
