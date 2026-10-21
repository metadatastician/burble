# Burble — maintenance review (corrective / adaptive / perfective)

**Date:** 2026-10-21
**Baseline:** `main` @ `1c5f9e1` (`chore(deps): bump the actions group with 5 updates (#246)`)
**Branch:** `arena/952ba7e4-burble`
**Scope:** whole repository — Elixir/Phoenix server (`server/`), browser clients
(`client/web/`), signalling relays (`signaling/`), browser extension
(`client/extension/`), CI, governance metadata and published claims.
**Method:** read-through, targeted static analysis, and *execution* where the
sandbox allowed it (see [Limits](#limits-and-what-was-actually-executed)).

This report follows the repository's own policy
(`.machine_readable/policies/MAINTENANCE-AXES.a2ml`): scope as
**must > intend > like**, *then* execute as **corrective > adaptive >
perfective**, and audit **systems > compliance > effects**. It is an index of
findings, not a replacement for [`DEBT.md`](../../../DEBT.md),
[`PROOF-NEEDS.md`](../../../PROOF-NEEDS.md),
[`TEST-NEEDS.md`](../../../TEST-NEEDS.md) or
[`READINESS.adoc`](../../../READINESS.adoc).

---

## Executive summary

| Axis | Findings | Fixed on this branch | Still open (recommended) |
|---|---|---|---|
| Corrective (broken) | 15 | 12 | 3 |
| Adaptive (out of date / misaligned) | 11 | 5 | 6 |
| Perfective (improvement) | 9 | 1 | 8 |

The single most important thing this review found is not a crash: **the three
worst defects were all in code paths with no test coverage at all.** The
authentication pipeline, the setup wizard, and the browser join flow are
exactly where the repository's tests are thinnest (`server/test/burble_web/`
contains channel and plug tests only — there is not one controller test, and
`client/web/tests/` never exercises `p2p-voice.html`). Every one of the
high-severity bugs below would have been caught by one request-level test.

Second most important: several *published* claims were contradicted by the
code (E2EE "server ignorance", setup-wizard locking, Groove socket path). The
repository already has an explicit honesty discipline (ADR-0007,
`DEBT.md`); this sweep found five places where the discipline had slipped.

### The five findings that matter most

1. **`MNT-01`** — every authenticated REST route lost the caller's identity
   (`conn.assigns[:user_id]` was never set). *Fixed.*
2. **`MNT-02`** — guest tokens were rejected by every authenticated REST route
   (`typ == "access"` filter vs `typ == "guest"` tokens). *Fixed.*
3. **`MNT-03`** — the setup wizard could never persist completion (calls to
   functions that do not exist, plus a match that turned every attempt into a
   500). *Fixed.*
4. **`MNT-04`** — the browser join flow pointed at a socket path that does not
   exist, and the "Join Room" relay flow could not work against the Cloudflare
   worker at all. *Fixed.*
5. **`MNT-05`** — `Burble.Media.E2EE` could be crashed by any peer with a
   malformed public key, and its documentation claimed a security property the
   code does not provide. *Validation fixed; documentation corrected.*

---

## Limits and what was actually executed

The sandbox for this review had `node`, `npm`, `python3`, `git`, `gh`, `rg` —
and **no Elixir/Erlang, Deno, Rust, Zig, `just` or `shellcheck`**. That shaped
the method, and it is the same limitation `DEBT.md` flagged in its own method
caveat. What that means concretely:

| Check | Status |
|---|---|
| `mix compile` / `mix test` / `mix format --check-formatted` / Dialyzer | **Not run** (no BEAM). Elixir edits were reviewed by hand and checked structurally (see below). |
| Deno test suite (`client/web/tests/`) | **Run**, via a Node shim implementing the `Deno.serve` / `Deno.Command` / `Deno.test` subset the suites use. |
| `deno task res:build` (ReScript) | **Run**, via `npm i rescript@12.2.0 @rescript/core@1.6.1` + `npx rescript build`. |
| Git submodules / VCS graph | **Run**. |
| YAML lint | Not run (no PyYAML); workflow edits were kept to comments. |

Structural checks that were run over the Elixir edits:

* balanced `do`/`fn` vs `end` after stripping comments and string/heredoc
  literals, across **all 131 `server/lib/**/*.ex` files** (0 mismatches, so no
  edit broke the block structure of any file);
* a module-reference scan (every `Burble.*` module named in `lib/` resolves to a
  `defmodule`), which is what surfaced `MNT-03`;
* delimiter balance on the heavily edited controller.

**Please run `mix compile --warnings-as-errors`, `mix format --check-formatted`
and `mix test` before merging** — that is the one verification step this
environment could not perform.

---

## Corrective — fixed on this branch

Each entry: what was broken, evidence, what changed, how it was verified.

### MNT-01 · Authenticated controllers received a `nil` caller · **HIGH**

`Burble.Auth.GuardianPipeline` ended with `Guardian.Plug.LoadResource`, which
stores the resource under a pipeline-scoped assign. Nothing ever wrote
`conn.assigns[:user_id]`, yet that is precisely what the controllers read:

```
server/lib/burble_web/controllers/api/moderation_controller.ex:44   actor_id = conn.assigns[:user_id]
server/lib/burble_web/controllers/api/message_controller.ex:103     user_id  = conn.assigns[:user_id]
server/lib/burble_web/controllers/api/llm_controller.ex:173         case conn.assigns[:current_user] do
```

Effect: every kick/ban/mute/move arrived with a `nil` actor, messages were
attributed to `nil`, and the permission check that gates the action was being
made on behalf of nobody.

**Fix:** the pipeline now assigns `:user_id` (from `sub`), `:display_name`
(`dn`), `:is_guest` (`gst`) and loads the resource into `:current_user`
explicitly, with a documented precedence order.

### MNT-02 · Guest tokens rejected on every authenticated route · **HIGH**

`Guardian.create_guest_token/1` issues `token_type: "guest"`; the pipeline
verified with `claims: %{"typ" => "access"}`. Guests could open the websocket
(`UserSocket` does not check `typ`) and could therefore *join a room*, but any
REST call returned 401. `Burble.GrooveVoice.authenticate/1` already accepted
`typ in ["access", "guest"]`, so the pipeline was the outlier.

**Fix:** verify the header, then check the token type in an explicit plug that
accepts `access` and `guest` and *rejects* `refresh` (refresh tokens must not be
usable as bearer credentials — that was also previously true only by accident of
the `typ` filter).

### MNT-03 · Setup wizard could never record completion · **HIGH**

`server/lib/burble_web/controllers/api/setup_controller.ex` stored its state via

```elixir
apply(Burble.Store, :get, [key])      # :get/1 does not exist
apply(Burble.Store, :put, [key, v])   # :put/2 does not exist
```

`Burble.Store` exports typed accessors (`create_user/1`, `save_server_config/2`,
`load_server_config/1`, …). Both calls therefore raised
`UndefinedFunctionError`, were swallowed into `{:error, :store_unavailable}`,
and:

* `setup_complete?/0` was permanently `false`;
* `complete/2` hit `:ok = store_put(...)` → `MatchError` → HTTP 500.

Two further defects in the same file: the audio endpoints did **not** check
completion despite the module doc promising "once setup is complete, these
endpoints return 403" (an unauthenticated caller could run a 3-second
microphone capture and speaker playback on a finished server at will), and the
configured-device checks matched atom keys on data that round-trips through
JSON (string keys), so they always reported "not configured".

**Fix:** use `save_server_config/2` / `load_server_config/1`; wrap writes in
`with` and return 503 (with the reason logged) instead of crashing; gate
`audio_devices`, `test_microphone` and `test_speakers` behind `setup_complete?`;
accept both key shapes.

### MNT-04 · Browser join flow could not connect · **HIGH**

`client/web/quick-join.html` built its socket URL as
`${server}/socket/websocket`, and `Burble.Groove` advertised the same path in
two capabilities and in `endpoints.channel_ws`. The endpoint mounts exactly one
Phoenix socket, at **`/voice`**:

```
server/lib/burble_web/endpoint.ex:17   socket("/voice", BurbleWeb.UserSocket, ...)
```

Every join from that page 404'd at the upgrade. (`server/integration/*` and
`client/rust/` already used `/voice/websocket` — so the two in-repo clients
disagreed.) Separately, `p2p-voice.html` treated *any* non-OK offer fetch as
fatal, but the Cloudflare worker relay answers `404 "not ready"` immediately
(no long-poll), so "Join Room" failed instantly against the very relay the page
ships as its production default.

**Fix:** `/voice/websocket` everywhere (page, Groove capabilities, Groove
endpoints, regenerated `.well-known/groove/manifest.json`); the join path now
retries for a bounded window instead of failing on the first 404.

### MNT-05 · E2EE key manager crashable by a peer; docs claimed "server ignorance" · **HIGH / compliance**

`register_peer_key/4` fed the peer's public key straight into
`:crypto.compute_key/4`. A key that is not 32 bytes raises, and the raise
happens inside the GenServer — so one malformed (or hostile) frame took down
the key state of *every* room in the deployment.

**Fix:** length-validate; wrap `compute_key` so it returns
`{:error, :invalid_public_key}` rather than raising; reject the all-zero shared
secret produced by low-order points (RFC 7748 §6.1).

**Documentation correction (no behaviour change):** the module doc claimed
"the server never possesses the symmetric key" and listed *Server ignorance* as
a security property. It does possess it — `get_frame_key/1` returns it so the
coprocessor can encrypt/decrypt — and `rotate_room_key/1` derives each key from
*fresh local entropy*, so the X25519 exchange with peers is not even an input
to the room key today. The claim is now replaced with an explicit
"What this module is NOT" section, and points at the `:serverless` topology as
the only path where the server genuinely cannot decrypt. **This is the most
important open design question in the repository** — see `MNT-16`.

### MNT-06 · `RoomChannel` crashed on early SDP/ICE frames · **MEDIUM**

`sdp_answer` and `ice_candidate` called `Burble.Media.Peer` through a Registry
`via` tuple with no guard. If the peer process was not up yet (a client that
answers quickly, or one whose peer died), the `:exit/:noproc` took down the
channel — i.e. the whole session, over one early frame.

**Fix:** `safe_peer_call/1` converts `:noproc`, `:timeout` and other exits into
an error reply; the client is told the peer is not ready instead of being
disconnected.

### MNT-07 · AI bridge HTTP API was cross-site requestable · **MEDIUM**

`burble-ai-bridge.js` guarded the *websocket* upgrade with an Origin check but
left the HTTP API open. A page the user visits cannot read the response (no CORS
headers), but it can still issue the request — and `GET /recv` **drains Claude's
inbox** as a side effect, so an unrelated tab could silently steal the agent's
messages.

**Fix:** the same `isLocalOrigin` policy now gates the HTTP API (403 for foreign
`Origin`; `/health` remains open, and requests with no `Origin` — curl, the
extension, tests — still work).

Also in the same file: the 64 KiB cap was applied *after* `req.text()` had
already buffered the whole body, and used `.length` (UTF-16 code units) rather
than bytes; the heartbeat started **two** intervals per connection (one at
upgrade, one in `onopen`) and leaked the first, so the "one ping per period"
contract was actually two.

### MNT-08 · `signaling/relay.js` hardening gaps · **MEDIUM**

* CORS emitted `Access-Control-Allow-Origin: ""` for a disallowed origin. A
  present-but-wrong header is a header browsers reject the response for; the
  header must be *absent*.
* The 64 KiB body cap was checked after `req.text()` had materialised the body.
* The 60 s TTL was refreshed only by `created` (set on the first write), so an
  answer posted at t=55 s expired 5 s later and the creator's poll missed it;
  and expiry was never enforced on read (only by a 30 s sweep), so a room could
  be served up to 30 s past its advertised life.

**Fix:** omit ACAO when not allowed, add `Vary: Origin` and `Cache-Control:
no-store`; check `content-length` before reading and count bytes after; refresh
the deadline on every write; expire on read with 410.

### MNT-09 · `signaling/worker.js` had no body cap at all · **MEDIUM**

The Deno relay caps stored blobs at 64 KiB; the Cloudflare worker (the
production default in the browser page) accepted up to KV's 25 MiB, unauthenticated.
Same CORS problem as `MNT-08`. **Fix:** both the cap and the CORS fix.

### MNT-10 · Browser extension was unloadable and its badge froze · **MEDIUM**

* `manifest.json` declared `icons/burble-16.png`, `48`, `128`; **none of the
  three files existed**, so Chrome refuses to load the unpacked extension.
  (Added; generated in-repo, no binary assets imported from elsewhere.)
* `background.js` polled with `setInterval`. MV3 service workers are evicted
  after ~30 s idle, which stops the interval for good — the badge simply stopped
  updating. Now uses `chrome.alarms` (and declares the `alarms` permission).

### MNT-11 · `p2p-voice.html` UX/robustness defects · **MEDIUM**

* **Room names were not validated.** The relay matches
  `/^\/room\/([a-zA-Z0-9_-]+)\/(offer|answer)$/`, so `Dad and Son`, `dad/son` or
  anything with an emoji/space produced a 404 that the user saw as "Room not
  found". Names are now normalised (trim, lowercase, spaces→`-`) and validated
  with a clear message.
* **The AI-channel card could be hidden moments after appearing.** ICE fires
  `connected` and then usually `completed`; `showConnected()` hides *all* cards,
  so the second call hid the AI panel the data channel had just revealed. Now
  tracked with `aiChannelOpen`.
* **Relay write failures were invisible** (`PUT` responses never checked), so a
  capacity refusal (503) or oversized body (413) became "nobody joined".
* **`window.burble.send` ignored SCTP backpressure**, and `sendAI()` threw a
  `TypeError` if the panel was used before the channel existed.
* **Clipboard copy failed silently outside a secure context** — i.e. exactly
  when the page is opened over plain HTTP on a LAN address to send a code to
  someone else. Now falls back to select-and-copy with guidance.
* Status messages were not announced to assistive technology; the status region
  now has `role="status" aria-live="polite"`.

### MNT-12 · Unfilled template + cross-project links in published metadata · **MEDIUM (compliance)**

`.well-known/security.txt` shipped literal `{{SECURITY_EMAIL}}`,
`{{PGP_KEY_URL}}`, `{{WEBSITE}}`, a `{{CURRENT_YEAR}}` expiry, and
`Canonical`/`Policy` URLs pointing at **`hyperpolymath/grumble`** — a different
repository. RFC 9116 compliance and the security disclosure path both broken.
`humans.txt` had the same placeholders. Both rewritten with real values from
`SECURITY.md` (`MNT-12` is fully fixed; a PGP key URL was deliberately *omitted*
rather than fabricated).

Related, same class, **not** fixed because it needs an owner decision:
**34 tracked files still contain `{{PROJECT_NAME}}` / `{{AUTHOR}}` style
placeholders** (`.devcontainer/*`, `.machine_readable/ai/.cursorrules`,
`.guix-channel`, `.github/copilot-instructions.md`, …). See `MNT-19`.

### MNT-13 · Guest `display_name` unbounded · **LOW**

`UserSocket.connect/3` passed an unauthenticated, attacker-controlled name
straight into presence metadata with no bound. Now trimmed, stripped of control
characters, and capped at 64 characters.

### MNT-14 · Devcontainer referenced a recipe that does not exist · **LOW**

`.devcontainer/devcontainer.json` ran `postCreateCommand: "just deps"`.
`Justfile` has no `deps` recipe (`setup:` is the documented bootstrap), so a
fresh dev container failed on creation. Template name/author placeholders in the
same file are also filled in.

### MNT-15 · Two test suites hid regressions behind environment failure · **LOW**

The new tests below are additions; the *existing* `client/web/tests/` suites
could not be trusted as signal, because under Deno they depend on
`deno task res:build` having run and on the `deno.json` import map. Independently
of that, the workflow comment explaining why the lane is advisory was **stale**
("references modules that no longer exist" — `signaling_test.js` and
`voice_test.js` import the *committed* `client/lib/src/BurbleSignaling.res.mjs`
and `BurbleVoice.res.mjs`, which exist). Corrected, and the count is now right.
**Flipping the lane to gating is recommended but was left alone** — see `MNT-25`.

#### Tests added with these fixes

* `client/web/tests/ai_bridge_security_test.js` — HTTP-API Origin rejection,
  local-Origin and no-Origin acceptance, `/health` still open.
* `client/web/tests/relay_rendezvous_test.js` — CORS header present only for an
  allowed origin, absent (not empty) for a rejected one.

Both pass under the Node shim; the pre-existing WebSocket-upgrade tests in
`ai_bridge_security_test.js` need real Deno and will only run in CI.

---

## Corrective — found, **not** fixed (recommended, ordered by severity)

### MNT-16 · The E2EE design does not deliver E2EE · **HIGH (design)**

See `MNT-05`. Beyond the documentation, the *behaviour* has two issues that need
a decision, not a patch:

1. `rotate_room_key/1` derives from local entropy, so the per-peer X25519
   `shared_secret` (stored per room in `peers`) is never mixed into the key.
   Either derive the room key from the peer exchanges (and distribute it over
   the signalling channel), or drop the exchange and stop describing the path as
   key agreement.
2. `get_frame_key/1` hands the symmetric key to any in-VM caller. If the intent
   is "server is an opaque SFU", the key must stay on the clients (Insertable
   Streams), which is what the moduledoc says was intended.

**Recommended next action:** open an ADR that states, in one sentence, whether a
server-mediated room is encrypted-in-transit-only or end-to-end, then align
`Burble.Media.E2EE`, `README.adoc`, `EXPLAINME.adoc` and `Topology` with it.

**Done, 2026-10-21 (round 2).** ADR-0016 written and the code aligned with it:
`Burble.Media.E2EE` is now a coordinator that holds public keys, epochs and
opaque blobs and has **no key-returning API**; the peer-side protocol
(`pairwise_key/6`, `seal_group_key/6`, `open_group_key/6`, `derive_frame_key/3`)
is implemented and unit-testable; rotation is an epoch bump that drops every
sealed blob. `:e2ee_key` became `:pipeline_key` and is refused in `:e2ee` rooms;
`Privacy.e2ee_config/1` and `setup/check` no longer report encryption that does
not exist; `README.adoc` now states plainly that **no room is end-to-end
encrypted today** and that the browser half is unwritten. See
`docs/decisions/0016-peer-held-group-keys.adoc` §Gaps for what remains.

### MNT-17 · CORS is not runtime-configurable, by design of the current code · **MEDIUM**

`config/runtime.exs` reads `BURBLE_CORS_ORIGINS` into `_cors_origins_env` and
explicitly *does not apply it*, because `endpoint.ex` reads
`Application.compile_env/3` inside a `plug` (evaluated at compile time). The
knock-on effect is `validate_compile_env: false` in `mix.exs` `releases/0`,
which disables a real safety check for the whole release.

**Recommended fix:** resolve CORS at request time — either a small plug that
reads `Application.get_env(:burble, :cors_origins, "*")` per request (cheap,
and it is the pattern `Burble.Groove` already uses for runtime switches), or pass
a function to Corsica if the pinned version supports it. Then set
`cors_origins` from the env in `runtime.exs` and delete the
`validate_compile_env: false` escape hatch.

### MNT-18 · The `room_creation` rate-limit tier is dead code · **LOW/MEDIUM**

```
server/lib/burble_web/plugs/rate_limiter.ex:65   room_creation: {5, 5 / 60.0}
server/lib/burble_web/plugs/rate_limiter.ex:81   {"/api/v1/rooms", "POST", :room_creation}
server/lib/burble_web/router.ex                 post "/servers/:server_id/rooms", RoomController, :create
```

Rooms are created at `/api/v1/servers/:server_id/rooms`, so the prefix never
matches: the anti-spam tier for room creation has never fired. (The existing
test asserts the opposite direction — that `GET /api/v1/rooms/some-room` passes —
so the suite does not catch it.) Add the real path to `@path_tiers` and test the
matching POST.

Two related weaknesses in the same plug, both pre-existing: `x-real-ip` /
`x-forwarded-for` are trusted unconditionally (only safe if the reverse proxy
overwrites them — worth making the trust configurable), and the read-modify-write
on ETS is racy under concurrency (acknowledged in a comment; `:ets.update_counter`
or a serialising GenServer would fix it if the limit matters).

---

## Adaptive — brought up to date on this branch

### MNT-19 · Template placeholders in 34 tracked files · **MEDIUM**

`rg --hidden -l '\{\{(PROJECT_NAME|AUTHOR|AUTHOR_EMAIL|CURRENT_YEAR|CURRENT_DATE)\}\}'`
→ 34 files. Two categories:

* **should be filled** — `.devcontainer/*`, `.github/copilot-instructions.md`,
  `.github/.mailmap`, `.github/MAINTAINERS`, `.guix-channel`,
  `.machine_readable/ai/.{cursorrules,windsurfrules,clinerules}`,
  `docs/attribution/CITATION.cff`. These are user-facing and mention a
  `{{PROJECT_NAME}}` that nobody can resolve.
* **should not carry placeholders at all** — the `self-validating/template-*.k9.ncl`
  files, `docs/decisions/0000-template.adoc`: placeholders are correct there.

Fixed in this sweep only where the file was already being touched
(`.devcontainer/devcontainer.json`, `.well-known/*`). The rest is mechanical work
with a real payoff: `DEBT.md`-style "cannot be trusted" evidence disappears.

### MNT-20 · `.tool-versions` pins an EOL runtime that CI does not use · **MEDIUM**

```
server/.tool-versions      elixir 1.17.3-otp-25
.github/workflows/*.yml    otp-version: '27', elixir-version: '1.17'
```

OTP 25 is out of support, and the local pin cannot reproduce CI. `mix.exs`
already carries a comment that `jose` is held at `~> 1.11.9` "once this host
moves to OTP 26+" — the host has, in CI, but not in the file that documents it.
Update `.tool-versions` to `1.17.3-otp-27` (or whatever CI resolves) and drop
the `jose` override comment's premise.

### MNT-21 · Policy discovery entrypoints that do not exist · **MEDIUM (compliance)**

`.machine_readable/policies/MAINTENANCE-AXES.a2ml` listed four entrypoints that
404: `docs/maintenance/MAINTENANCE-CHECKLIST.md`,
`docs/practice/SOFTWARE-DEVELOPMENT-APPROACH.adoc`,
`.machine_readable/META.a2ml`, `.machine_readable/bot_directives/README.scm`.
**Fixed** — all ten paths now resolve, and each resolves to a file that exists
(the real documents live under `docs/governance/`). The policy's own
`machine-human-sync-required` and `docs-parity-required` rules apply to itself
first.

### MNT-22 · DEBT.md is dated and partly resolved · **MEDIUM**

`DEBT.md` was measured 2026-08-07. Since then:

* `S-1` (`ex_webrtc 0.16.0`, retired with a DTLS advisory) — **resolved**:
  `mix.lock` now pins `0.17.0`.
* `S-2` (`verisim_client` git dep with no `ref:`) — **still open**: `mix.exs`
  still declares `{:verisim_client, git: ...}` with no `ref`/`tag`. The lockfile
  pins a SHA, which is the saving grace, but an unlocked resolve takes HEAD.
* `S-3` — **still open**: 4 `deno.json` manifests, 0 `deno.lock`.
* `S-4` — **still open**: 2 `build.zig`, 0 `build.zig.zon`.
* `B-1` remains correctly marked resolved.

The register is still the best document in the repository; it just needs a
"re-measured on" sweep. `S-2` is a one-line fix and closes a supply-chain hole.

### MNT-23 · Version numbers disagree across the tree · **LOW**

| Artefact | Version |
|---|---|
| `server/mix.exs` | `1.0.0` |
| `client/lib/deno.json` | `1.0.0-alpha.2` |
| `client/rust/Cargo.toml` | `2.0.0` |
| `admin/deno.json`, `client/extension/manifest.json` | `0.1.0` |
| `CHANGELOG.md` | `Unreleased` after `1.0.0-alpha.1` |

`README.adoc` says "pre-production". Whatever the intent, this cannot be
mechanically released or attested as-is. Add a `VERSION` policy (or generate the
per-artefact versions from one source) and state the release train.

### MNT-24 · Generated artefacts tracked in VCS · **LOW**

* `_site/index.html`, `_site/assets/style.css` — site build output.
* `src/build/ttc/2025081600/**/*.ttc|.ttm`, `src/build/exec/abi_proofs.c` —
  Idris compiler output (the repo already had a `B-1`-style lesson about
  generated files being bad merge conflicts, in `DEBT.md`).

Both are ignored-by-convention candidates. Removing them shrinks the conflict
surface of exactly the files nobody hand-edits.

### MNT-25 · Web-client test lane is advisory with a stale justification · **LOW**

Comment corrected in this branch (`MNT-15`). Recommendation: run the lane twice
on a scratch PR, confirm green, then remove `continue-on-error: true` and add it
to the required checks. An advisory lane on a suite that exercises the DOM
entrypoints is how `MNT-04` survived.

---

## Perfective — opportunities (not done)

### MNT-26 · There are no controller tests, and the three worst bugs lived there

`server/test/burble_web/` = `channels/` (5 files) + `plugs/` (2 files). Zero
`controllers/`. `Phoenix.ConnTest` is available (Phoenix is a dependency) and
`server/test/test_helper.exs` already builds a partial supervision tree. The
highest-value additions, in order:

1. `GuardianPipeline` — a request with no token (401), a guest token (200,
   `assigns[:user_id]` set), a refresh token (401). Would have caught `MNT-01`
   and `MNT-02`.
2. `RoomController.create/2` — valid name, invalid name, and the rate-limit
   tier firing (would catch `MNT-18`).
3. `SetupController` — `check` before/after completion, and the 403 gate
   (`MNT-03`).

### MNT-27 · The browser flow has no test that loads the HTML

`client/web/tests/` tests compiled ReScript modules; `p2p-voice.html` and
`quick-join.html` are 1 000+ lines of hand-written JS with no harness at all.
Extracting the pure helpers (`normalizeRoomName`, `isValidRoomName`,
track/session handling) into `client/web/src/*.res` or a small ES module would
make them testable in Deno without a DOM. That single refactor would have caught
`MNT-04` and most of `MNT-11`.

### MNT-28 · `RoomChannel` broadcasts `"signal"` to the whole room

`signal` (legacy P2P SDP) uses `broadcast!` on the room topic, so every
participant receives every other participant's SDP — which for a two-person room
also means the sender receives its own. Room-wide fan-out leaks SDP (including
ICE candidates/addresses) to peers who are not the addressee. `SignalingChannel`
already implements the correct pattern (peer-directed routing via
`route_to_peer/3`); the legacy path should either delegate to it or be removed.

### MNT-29 · Session cookie is not `secure`

`endpoint.ex` sets `same_site: "Lax"` but not `secure: true`, and `http_only` only
by default. In a TLS deployment behind Caddy/nginx this is a one-line hardening
(conditionally enabled per env). Low risk today because the app is
token-in-header rather than cookie-auth, but the cookie is there.

### MNT-30 · `Burble.Auth.verify_llm_token/1` accepts any non-empty string in dev

```
server/lib/burble/auth/auth.ex:141  if Mix.env() == :prod -> {:error, :jwt_required}
                                    else -> any non-empty token is valid
```

Deliberate and documented, but it means a `MIX_ENV` typo silently disables LLM
auth. Consider requiring an explicit `BURBLE_DEV_LLM_AUTH=true` rather than
inferring from `Mix.env()`.

### MNT-31 · `config/config.exs` generates a random Guardian secret at compile time

```
secret_key: System.get_env("GUARDIAN_SECRET", Base.encode64(:crypto.strong_rand_bytes(48)))
```

Prod overrides it from `SECRET_KEY_BASE` in `runtime.exs`, so production is fine.
But dev/test sessions are silently invalidated on every recompile — a papercut
that shows up as "logged out again" and can push someone toward a fixed secret.
Generate a deterministic dev secret *and* refuse to boot in prod without an env
value.

### MNT-32 · `docs/AI-CHANNEL-PROTOCOL.json` is not JSON

It is JSONC (leading `//` comments) in a `.json` file. Humans read it, so nothing
breaks — but any tool (or agent) that does `JSON.parse` on a file named `.json`
fails. Rename to `.jsonc` or move the comments into a `"$comment"` field.

### MNT-33 · Submodule layout has drifted from `.gitmodules`

`.gitmodules` declares `tools/affinescript` (path does not exist in the tree);
`tools/selur-compose` exists as a *vendored subtree*, not a submodule, while
`Justfile` still says "Run: git submodule update --init tools/selur-compose", and
`Containerfile` does `COPY tools/affinescript ...` — a build that must fail.
Decide one story (submodule vs subtree vs fetch) and make `.gitmodules`,
`Justfile`, `setup.sh`, `Containerfile` and `README.adoc:185` agree.

### MNT-34 · CI supply chain: actions pinned by tag

34 uses of `actions/checkout@v7.0.1` (tag), 5 of `erlef/setup-beam@v1.24.1`, etc.
Three actions *are* SHA-pinned, so the mechanism is understood here. For a repo
that already has a `gitleaks` baseline and a scorecard workflow, pinning the rest
by digest (as dependabot will do if configured for it) closes the "tag moved
under you" class.

### MNT-35 · Root-directory size

51 tracked files/dirs at the repository root. The policy's own
`[generic-cleanup-finish-off] root-cleanup-required = true` is not satisfied:
`AFFIRMATION.adoc`, `BURBLE-PROOF-STATUS.md`, `DEBT.md`, `PROOF-NEEDS.md`,
`READINESS.adoc`, `TEST-NEEDS.md`, `TOPOLOGY.md`, `EXPLAINME.adoc` and three
`QUICKSTART-*.adoc` all sit at root. Several are one-line index files. Moving
them under `docs/` (with redirect stubs) is the kind of "stale-work cull" the
policy asks for.

---

## Claims vs reality (audit, axis-3)

Checked against `README.adoc`, `EXPLAINME.adoc`, `TOPOLOGY.md`,
`READINESS.adoc` and `BURBLE-PROOF-STATUS.md`:

| Claim | State after this branch |
|---|---|
| "E2EE optional / server cannot decrypt" | **Contradicted by code.** Corrected in the E2EE moduledoc; `README.adoc` still needs the same treatment (`MNT-16`). |
| "Browser join (WebRTC): Yes" | Was broken for the server path (`MNT-04`). Now correct. |
| "Setup wizard locks itself when complete" | Was documented but not implemented (`MNT-03`). Now correct. |
| Groove discovery advertises working endpoints | Was advertising a non-existent socket path (`MNT-04`). Now correct. |
| "Known debt is enumerated … in `DEBT.md`" | Still true, but stale in 3 of 4 supply-chain items (`MNT-22`). |
| "Test gate armed" | Unchanged; the gate exists (`just test-server` → `mix test --no-start`). Note `--no-start` means the application supervision tree is not booted — worth a comment in `Justfile` so the next person does not assume Ecto-style `mix test`. |
| "Sub-microsecond PTP", "<10ms latency" | Not re-measured; `README.adoc` already flags them as hardware-gated/unbenchmarked. Fine as flagged. |

---

## Suggested sequencing

1. **Merge this branch** after CI confirms `mix compile`, `mix format
   --check-formatted`, `mix test`.
2. Add the three controller tests in `MNT-26` (small, high return, protects the
   fixes above from regressing silently).
3. `MNT-22` `S-2` — add `ref:` to the `verisim_client` git dep (one line).
4. `MNT-20` — align `.tool-versions` with CI's OTP 27 and drop the `jose` pin
   rationale once it resolves.
5. `MNT-16` — write the E2EE ADR. Do not add features to that module until the
   one-sentence claim is settled.
6. `MNT-17` — runtime CORS, then remove `validate_compile_env: false`.
7. `MNT-18` — fix the rate-limit path list and add the matching test.
8. `MNT-28` — route legacy `signal` peer-to-peer (or delete it).
9. `MNT-19` / `MNT-24` / `MNT-35` — mechanical cleanup sweep (placeholders,
   generated artefacts, root tidy).
10. `MNT-25` — promote the web-client lane to gating once green.

---

## Residual risk statement

Everything marked "fixed" in the corrective section was changed with a matching
test where a test was possible in this environment (relay, bridge, and the new
client-side behaviour). The Elixir changes could **not** be compiled or run
here; they were reviewed line by line and checked for structural integrity, and
the risk of a syntax or type error remains non-zero. The two highest-value
verifications, before merge, are:

```bash
cd server && mix compile --warnings-as-errors && mix format --check-formatted && mix test
cd client/web && deno task res:build && deno task test
```

---

## Follow-up (round 2, 2026-10-21)

`MNT-16` was implemented rather than re-documented; the design is in
`docs/decisions/0016-peer-held-group-keys.adoc` and the status is stated in
`README.adoc` under *Encryption: what is true today*.

A survey of the hyperpolymath type-theory / reversibility repositories
(`*-types`, `absolute-zero`, `januskey`), with concrete enhancement proposals
for Burble, is in
`docs/reports/design-enhancements-2026-10-21.md`.
