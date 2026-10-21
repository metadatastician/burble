// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// runtime.js — the runtime-specific calls behind relay.js and burble-ai-bridge.js.
//
// Bun is the runtime here: it is what CI runs, what the docs tell you to run,
// and what the tests spawn. These two long-lived processes (the signalling
// relay and the AI bridge) were written against Deno's API and could not start
// under Bun at all, which is what made "bun test" unable to cover them: there
// was no process to spawn.
//
// The Deno branch below is kept because these files were written for it and the
// adaptation is a dozen lines, but it is not exercised by CI. Treat Bun as the
// supported runtime and Deno as untested.
//
// The surface difference is small and worth hiding in one place:
//
//   env          Deno.env.get(name)        process.env[name]
//   serve        Deno.serve(opts, handler) Bun.serve({ ...opts, fetch })
//   websocket    Deno.upgradeWebSocket(req) → {socket, response}
//                Bun's server.upgrade(req, {data}) + a `websocket` handler object
//
// The WebSocket case is the awkward one: Deno hands you a WHATWG-style socket
// you attach callbacks to, Bun dispatches events to handlers registered at serve
// time. `serve()` below gives the handler a socket that looks like Deno's and
// forwards Bun's events into it, so the application code is identical on both.
//
// Deliberately not a general compatibility layer: it covers exactly what these
// two files use. If a third needs something else, add it here rather than
// forking the shim.

export const isBun = typeof globalThis.Bun !== "undefined" && typeof globalThis.Bun.serve === "function";
export const isDeno = !isBun && typeof globalThis.Deno !== "undefined" && typeof globalThis.Deno.serve === "function";

if (!isBun && !isDeno) {
  throw new Error("burble: no supported runtime — expected Bun or Deno");
}

/**
 * Read an environment variable, returning fallback when it is unset or empty.
 * Errors reading the environment propagate rather than returning the fallback.
 */
export function env(name, fallback = undefined) {
  const value = isBun ? globalThis.process?.env?.[name] : globalThis.Deno.env.get(name);
  return value === "" ? fallback : value ?? fallback;
}

// WHATWG readyState values, so callers can keep using the same comparisons.
const CONNECTING = 0;
const OPEN = 1;
const CLOSED = 3;

/**
 * Create a socket facade for Bun and store it on holder.socket.
 * The holder supplies the native socket in ws and numeric state in state; callers assign
 * onopen, onmessage, onclose, and onerror callbacks to the returned facade.
 */
function socketFacade(holder) {
  const socket = {
    get readyState() {
      return holder.state;
    },
    /** Send only while open; otherwise discard the data. Send errors propagate. */
    send(data) {
      if (holder.state !== OPEN) return;
      holder.ws?.send(data);
    },
    /** Mark closed immediately and request closure, suppressing native close errors. */
    close(code = 1000, reason = "") {
      holder.state = CLOSED;
      try {
        holder.ws?.close(code, reason);
      } catch {
        // Bun throws if the peer is already gone; the state is already CLOSED.
      }
    },
    onopen: null,
    onmessage: null,
    onclose: null,
    onerror: null
  };

  holder.socket = socket;
  return socket;
}

/**
 * Start an HTTP server and return the native Bun or Deno server handle.
 *
 * The handler can call ctx.upgrade(request) and return its response: a Response
 * on Deno, or undefined on Bun. Bun ignores the handler's return value after a
 * successful upgrade. Startup errors propagate; handler errors reach the
 * runtime's request error handling.
 *
 * @param {{port: number, hostname?: string}} options
 * @param {(req: Request, ctx: {upgrade: (req: Request) => {socket: object, response: Response | undefined}}) => Response | undefined | Promise<Response | undefined>} handler
 */
export function serve(options, handler) {
  if (isDeno) {
    return globalThis.Deno.serve(options, (req) =>
      handler(req, {
        upgrade: (request) => globalThis.Deno.upgradeWebSocket(request)
      })
    );
  }

  return globalThis.Bun.serve({
    port: options.port,
    hostname: options.hostname,

    /** Resolve the handler's response, returning undefined after a successful upgrade. */
    async fetch(req, server) {
      let pending = null;

      const ctx = {
        /**
         * Upgrade this request to a WebSocket.
         *
         * Returns the same `{ socket, response }` shape as Deno so the caller
         * can `return response` unconditionally — on Bun that is `undefined`,
         * which is what Bun expects after a successful upgrade.
         * Throws if Bun refuses the upgrade; native upgrade errors propagate.
         */
        upgrade(request) {
          const holder = { ws: null, state: CONNECTING, socket: null };
          const socket = socketFacade(holder);

          const upgraded = server.upgrade(request, { data: holder });
          if (!upgraded) throw new Error("burble: websocket upgrade refused by Bun");

          pending = holder;
          return { socket, response: undefined };
        }
      };

      const response = await handler(req, ctx);

      // Bun has already taken over the connection; returning a Response here
      // would be an error, so a handler that returned `undefined` (Deno's
      // post-upgrade response) is normalised to "no response".
      if (pending) {
        pending = null;
        return undefined;
      }

      return response;
    },

    websocket: {
      open(ws) {
        const holder = ws.data;
        holder.ws = ws;
        holder.state = OPEN;
        holder.socket?.onopen?.();
      },
      /** Deliver text as { data }, decoding binary messages as UTF-8. */
      message(ws, message) {
        const holder = ws.data;
        const data = typeof message === "string" ? message : new TextDecoder().decode(message);
        holder.socket?.onmessage?.({ data });
      },
      close(ws, code, reason) {
        const holder = ws.data;
        holder.state = CLOSED;
        holder.socket?.onclose?.({ code, reason });
      },
      error(ws, error) {
        ws.data?.socket?.onerror?.(error);
      }
    }
  });
}
