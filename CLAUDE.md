# CLAUDE.md — Burble P2P Voice + AI Bridge

## What this is

Burble is a P2P voice chat with an AI data channel. When two people connect via `p2p-voice.html`, their Claude Code instances can also exchange messages over the same encrypted WebRTC link.

## Quick start (receiver side)

You've been sent a room code. Do this **in order** — the bridge must start before
the page so the page's auto-retry can pick it up:

```bash
git clone https://github.com/hyperpolymath/burble
cd burble

# 1. Start the AI bridge (leaves it running in the background)
deno run --allow-net --allow-env client/web/burble-ai-bridge.js &

# 2. Open the voice client in your browser
xdg-open client/web/p2p-voice.html
```

In the browser:
1. Click **Allow Microphone**
2. Click **Join Room**
3. Paste the code you were sent
4. Click **Generate Reply**
5. Copy the reply code and send it back

Once connected, the "AI Channel" card shows a green dot next to "bridge online" —
that confirms the page has reached your local Claude. Test the path:

```bash
# Check bridge is connected
curl http://localhost:6474/status
# {"connected":true,"queued":0,"port":6474,...}

# Send a message to the other Claude
curl -X POST http://localhost:6474/send -H "Content-Type: application/json" \
  -d '{"type":"hello","from":"receiver"}'

# Poll for messages from the other side (drains the queue)
curl http://localhost:6474/recv
```

### Troubleshooting the AI channel

- **`/send` returns `{"ok":false,"error":"not connected"}`** — the page isn't
  connected to the bridge. Reload `p2p-voice.html` or check that the bridge
  process is still running (`lsof -i :6474`).
- **`/recv` always empty even though the other side sends** — this was a real
  bug up to 2026-04-16 (a dead `setupAIChannelWithBridge` function was never
  called, so the remote-to-local leg didn't forward). Fix landed in the
  commit that replaced it with inline bridge-forwarding. If the symptom
  recurs, check the browser console for `[Burble AI] Bridge forward failed`.
- **Bridge status dot stays grey on the page** — the page retries the bridge
  every 5-10 s. If the dot never goes green, the bridge isn't listening on
  `ws://127.0.0.1:6475`.
- **Need two bridges on one machine** (testing/dev): set
  `BURBLE_AI_BRIDGE_PORT=7474 deno run …` — both HTTP and WS ports shift
  together (`7474` + `7475`).

## Claude-to-Claude protocol

Messages are JSON over WebRTC DataChannel. No schema enforced — any valid JSON works. Suggested message types:

```json
{"type": "ping"}
{"type": "pong"}
{"type": "task", "action": "review", "file": "src/main.rs", "from": "claude-a"}
{"type": "result", "status": "ok", "findings": [], "from": "claude-b"}
{"type": "chat", "message": "Working on the FFI layer now", "from": "claude-a"}
```

## API reference

All on `localhost:6474`:

| Method | Path | Description |
|--------|------|-------------|
| POST | /send | Send JSON to remote peer |
| GET | /recv | Poll received messages (drains queue) |
| GET | /status | Connection status + queue depth |
| GET | /health | Health check |

## Scope

This CLAUDE.md applies ONLY to the `burble/` directory. Do not modify files outside this directory.

## Build commands

```bash
just p2p-ai        # Start bridge + open P2P voice
just p2p            # Open P2P voice only (no bridge)
just ai-bridge      # Start AI bridge only
just server         # Start Elixir server (for server mode, not needed for P2P)
just test           # Run tests
just build          # Build everything
```

## Architecture

```
Your Claude ←curl→ Deno bridge (:6474) ←WS→ Browser ←WebRTC→ Their Browser ←WS→ Their bridge ←curl→ Their Claude
                                              ↕                      ↕
                                         Voice (DTLS-SRTP, encrypted P2P)
```

## Running the server side (Bolt + voice) under WSL2

The Bolt listener binds udp/7373 (`Burble.Bolt.Listener`, also QUIC via
`Burble.Bolt.Quic` when the `:quicer` NIF is present). Under WSL2's
default NAT mode, inbound LAN UDP never reaches the listener. If you're
on Windows + WSL2 and the server side won't accept Bolt datagrams from
another host, see `docs/developer/wsl-mirrored-networking.adoc` —
`networkingMode=mirrored` in the host `.wslconfig` plus a Defender
firewall rule for udp/7373.

## Do not

- Do not modify files outside `burble/`
- Do not install npm packages (use Deno)
- Do not create a central server for the P2P mode
- Do not send real credentials or secrets over the data channel
