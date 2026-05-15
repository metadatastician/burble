# Burble Phase 1 — Stub Elimination: Implementation Plan

**Date:** 2026-05-13
**Phase:** 1 of 4 (per `/home/joshua/Documents/repos/burble/docs/superpowers/specs/2026-05-07-burble-full-implementation-scoping.md` §5)
**Scope:** Two weeks. Eliminate stubs that silently produce wrong data; convert remaining stubs to loud failures with caller-side propagation tests; fix the VeriSimDB migrator boot regression that gates all persistence work.

---

## 1. Plan overview

Phase 1 takes a deployment that *boots* but contains landmines and turns it into a deployment that either *works correctly* or *fails loudly with a diagnosable error*. The success test is dual: (a) every reachable code path that currently returns plausible-but-wrong output (`opus_to_pcm_stub`, the Discord cipher fallback, `fork_vext_chain` returning `{:ok, :stub}`) either does the real work or raises a typed error that the caller surfaces; (b) `just deploy && just smoke-deploy` boots a server whose `Burble.Store.Migrator` reports `v1` applied successfully against the compose-deployed VeriSimDB, with zero `:nxdomain` log lines. Order of operations: 1.6 (VeriSimDB migrator nxdomain — unblocks everything else), then 1.4 (Discord crypto — security-critical), then 1.1 + 1.2 in parallel (SIP), then 1.3 (Topology — likely defer), then 1.5 (caller-side audit, which depends on 1.1 having converted the silent stub to a loud one).

---

## 2. Stub survey and prioritization

### 2.1 Method

I ran four grep passes over `/home/joshua/Documents/repos/burble/server/lib/`:
1. `:not_implemented`, `:stub`, `_stub\b`, `_placeholder\b`
2. `TODO|FIXME|XXX|placeholder|silently|silent`
3. `xsalsa20|xchacha20|libsodium|crypto_box|secretbox`
4. `Migrator|nxdomain|VERISIMDB_URL`

### 2.2 Complete stub inventory

| Site | Pattern | Class | Severity |
|---|---|---|---|
| `bridges/sip.ex:1397` `opus_to_pcm_stub/1` returning 160 zeroed floats | **silent failure** | listener hears silence on PCMU/PCMA SIP calls instead of an error | **Critical** |
| `bridges/sip.ex:976,981` callers in `send_rtp_audio/2` for `:pcmu` and `:pcma` codecs | **silent failure (propagation)** | the silent output is wrapped into a real RTP packet and sent on the wire | **Critical** |
| `bridges/sip.ex:1305` `resolve_sip_srv/1` returning `{:error, :dns_srv_not_implemented}` | honest demotion | SRV-required SIP providers cannot be reached at all; explicit-host path works | Medium |
| `bridges/discord.ex:942-962` `encrypt_xsalsa20_poly1305/3` `rescue _error -> plaintext` | **silent security failure** | on `:xchacha20_poly1305` unavailability, sends *unencrypted Opus* with the `tag` byte prefix stripped; Discord would reject it but the warning is logged, not raised | **Critical (security)** |
| `bridges/discord.ex:964-989` `decrypt_xsalsa20_poly1305/3` rescue returning `{:error, :not_available}` | honest demotion | Decryption fallback is honest; the encrypt-side is the bug | Low |
| `topology/transition.ex:64` `fork_vext_chain/2` returning `{:ok, :stub}` | **dishonest-success stub** | the calling `transition_room/2` returns `:ok` for distributed/serverless transitions even though the chain was never forked | High |
| `topology/transition.ex:51-58` `merge_rooms/3` returning `:ok` after only logging | **dishonest-success stub** | listed as Phase 2 (per scoping §5) but exhibits same pattern | High |
| `coprocessor/{elixir,zig,smart,snif}_backend.ex` `opus_transcode/4` returning `{:error, :not_implemented}` (×4) | **honest demotion** | callers should propagate; no caller exists in production paths (confirmed: `grep` shows only tests and self-delegation) | Low — but the SIP bridge does *not* use this callback, it uses `opus_to_pcm_stub`. That gap is the root cause of 1.1 |
| `store/migrator.ex` migration runs but produces `{:network_error, :nxdomain}` at boot | **environment regression** | persistence layer marks itself "schemaless OK to continue" but `_migration:burble` octad never lands; subsequent state writes also nxdomain | **Blocker** |
| `coprocessor/pipeline.ex:222` comfort noise comment "silent for enough frames" | benign | working behaviour, not a stub | n/a |
| `bolt/{listener,sender}.ex` "silently" comments | benign (WoL discard, fallback semantics documented) | n/a |
| `transport/quic.ex:148` idle timeout comment | benign | n/a |

### 2.3 Priority (silent failures > runtime errors > documented honest demotions)

1. **Discord encrypt silent-plaintext fallback** (`bridges/discord.ex:942-962`) — silent loss of confidentiality.
2. **SIP `opus_to_pcm_stub`** — silent loss of audio.
3. **`fork_vext_chain` `{:ok, :stub}`** — silent loss of integrity guarantee at the topology layer.
4. **VeriSimDB migrator nxdomain** — environment, not code, but blocks every other persistence test.
5. **SIP DNS SRV** — honest demotion; broaden compatibility.
6. **`opus_transcode` callback audit** — confirm honest, document, add caller-side propagation test.

---

## 3. Workstream 1.1 — SIP Opus decode (`opus_to_pcm_stub`)

### 3.1 Current state

`bridges/sip.ex:1397` returns `List.duplicate(0.0, 160)`. It is invoked at `976` and `981` only when `negotiated_codec` is `:pcmu` or `:pcma` (G.711 µ-law/A-law — the PSTN interop codecs). The `:opus` path at line 970 sends the frame unchanged. There is **no caller of `Burble.Coprocessor.Backend.opus_transcode/4` anywhere in `server/lib/`** outside coprocessor self-delegation and `opus_contract_test.exs`. The behaviour callback exists as a typed deadletter, not a real hook.

### 3.2 Options

**Option A — Wire a real libopus NIF in Zig** `[C+A+I, L, ~12-20h]`
- `[C]` Decide on linking strategy: vendor `libopus` into `ffi/zig/` and statically link, vs. dynamic link against system `libopus0`.
- `[A]` Add `opus_decode_pcm/3` NIF entry to `ffi/zig/src/coprocessor/audio.zig` exporting `(opus_frame: []const u8, sample_rate: u32, channels: u8) -> ![]f32`.
- `[A]` Implement `Burble.Coprocessor.ZigBackend.opus_transcode/4` to dispatch decode vs. encode based on input type (binary vs. list of floats).
- `[I]` Replace `opus_to_pcm_stub/1` body with `Burble.Coprocessor.SmartBackend.opus_transcode(opus_frame, 48_000, 1, 0)` and pattern match `{:ok, pcm}` / propagate error to caller.
- Pros: fixes the whole class; unblocks Mumble bridge full quality; makes the `opus_transcode/4` callback truthful; opens path for SIP encode-side too.
- Cons: largest scope; requires Zig+C build changes in CI; libopus license (BSD-3-Clause) is compatible but adds a vendored dep.

**Option B — Erlang port to `opusfile` / `opusenc` CLI** `[A+I, M, ~4-6h]`
- `[A]` Spawn a `Port` running `opusdec` per call leg; feed Opus frames on stdin, read raw PCM from stdout.
- `[I]` Replace `opus_to_pcm_stub/1` with a port-write/port-read protocol guarded by a per-call `GenServer`.
- Pros: no Zig toolchain change; isolation via OS process; fast to implement.
- Cons: per-call OS process overhead (~5ms cold start); opusdec is from `opus-tools` which is not always installed; brittle in containerised deployment without an apk/apt add.

**Option C — Loud-fail demotion** `[A+I, S, ~2h]` (RECOMMENDED)
- `[A]` Change `negotiated_codec` selection to refuse `:pcmu`/`:pcma` at SDP negotiation time when no Opus transcoder is wired. In the SDP `200 OK` response, advertise only `opus/48000/2`. If peer offers only G.711, return `488 Not Acceptable Here` and tear the call down.
- `[A]` Delete `opus_to_pcm_stub/1` outright. The PCMU/PCMA branches in `send_rtp_audio/2` become `{:error, :no_transcoder}` which the caller logs at error level and drops the frame.
- `[I]` Add `test/burble/bridges/sip_codec_negotiation_test.exs` asserting (1) Opus-offering peer receives `200 OK` with `opus/48000/2`, (2) G.711-only peer receives `488 Not Acceptable Here`.
- Pros: smallest scope; aligns with the scoping doc's `opus_transcode` honest-demotion philosophy; no silent silence injection.
- Cons: SIP bridge cannot interop with PSTN gateways that speak only G.711 — but it currently can't anyway, it just lies about it.

**Recommendation:** **Option C** for Phase 1 (small, correct, ships in two days), with Option A scheduled as Phase 4 work concurrent with bridge integration tests. The scoping doc §5 Phase 1 success criterion is "stubs that must remain are tested to fail loudly with a clear error and documented" — Option C is the canonical realisation of that criterion. Option A's scope creep would consume the whole two-week budget and produce a less audit-friendly delivery.

### 3.3 Marr & effort

`[C]` codec policy decision (mandatory) — S (1h).
`[A]` SDP negotiation refusal path — S (1-2h).
`[I]` Test cases + delete the stub — S (1h).

---

## 4. Workstream 1.2 — SIP DNS SRV lookup

### 4.1 Current state

`bridges/sip.ex:1305-1307` `resolve_sip_srv/1` returns `{:error, :dns_srv_not_implemented}`. The function name in the existing pre-survey ("resolve_via_srv") is slightly off — the actual symbol is `resolve_sip_srv/1`. The function is referenced in dialled-URI handling but is currently the only path that would touch SRV; calls fall through to `:inet.getaddr/2` against the explicit host charlist at line 1315.

### 4.2 Design

Use OTP stdlib `:inet_res.lookup/3` — no new dependency, ships with Erlang.

```
SRV name format: "_sip._udp.<domain>"   (also try _sip._tcp on UDP failure for completeness)
Return:          {:ok, host_charlist, port}  |  {:error, atom}
```

### 4.3 Tasks

- `[A]` Design contract change: `resolve_sip_srv/1` returns `{:ok, {host_charlist, port}}` or `{:error, :nxdomain | :no_srv_record}`. Update callers that currently treat the return as binary host. **S (1h).**
- `[I]` Implement: `[{_pri, _wt, port, target}|_] = :inet_res.lookup(~c"_sip._udp.#{domain}", :in, :srv); {:ok, {target, port}}`. Handle empty list → `{:error, :no_srv_record}`. Handle `:inet_res` raising → `{:error, :nxdomain}`. **S (30m).**
- `[I]` Sort SRV records by `priority` ascending, then random-shuffle within priority (per RFC 2782 — weighted shuffle is over-engineering for Phase 1; pure random within priority is acceptable). **S (30m).**
- `[I]` Test: `test/burble/bridges/sip_dns_test.exs` asserting (1) a real SRV name resolves, (2) a nonexistent name returns `{:error, :nxdomain}`. Use a mock module or pin to a publicly stable SRV (e.g. `_sip._udp.iptel.org` exists publicly but external-DNS tests are flaky in CI — prefer a `:meck` of `:inet_res.lookup/3` returning a fabricated record). **S (1h).**

`[I+A]`, total S (3h).

---

## 5. Workstream 1.3 — Topology transition `fork_vext_chain`

### 5.1 Current state

`topology/transition.ex:62-65`:
```
defp fork_vext_chain(room_id, state) do
  Logger.info("[Vext] Forking chain for room #{room_id} at position #{state[:position] || 0}")
  {:ok, :stub}
end
```

`transition_room/2` does `if new_mode in [:distributed, :serverless] do fork_vext_chain(...) end` and then unconditionally returns `:ok`. The return value of `fork_vext_chain` is **discarded** — even if it were real, `transition_room/2` would not detect a failed fork. The existing test `topology_test.exs:128-132` only asserts non-crash, so it passes regardless of fork correctness.

`Burble.Verification.Vext` exposes `init_chain/1` (returns a new `%{channel_id, position: 0, latest_hash: genesis_hash()}`) but **no `fork_chain/2`** that would take an existing chain's tip and start a new chain anchored to it. The Vext module's hash construction (`hash_chain_link/3`) uses `previous_hash` as a plain string, so a fork is conceptually trivial: snapshot `latest_hash` of the parent chain as `previous_hash` for the new chain's position 0, and tag the new chain with a `parent_chain_id` field.

### 5.2 Three-way choice

**Option A — Real implementation `[C+A, M, 6-10h]`**
- `[C]` Decide on the fork data model: the simplest is an anchor record `%{parent_chain_id, parent_position, parent_hash, child_chain_id, forked_at}` persisted in VeriSimDB as an octad `vext_fork:<child_chain_id>`. This requires Workstream 1.6 (migrator) to be green first.
- `[A]` Add `Burble.Verification.Vext.fork_chain/3(parent_chain_id, parent_state, new_chain_id) :: {:ok, fork_record} | {:error, reason}`.
- `[A]` Update `transition_room/2` to thread the `fork_vext_chain` return through `with`, so failures abort the transition rather than being discarded.
- `[I]` Update `topology_test.exs` to assert that transitions to `:distributed`/`:serverless` *actually create* a fork record retrievable via `Vext.get_fork/1`.

**Option B — Honest demotion `[A+I, S, 2h]`**
- Replace `{:ok, :stub}` with `{:error, :fork_not_implemented}` and propagate it: `transition_room/2` returns `{:error, :fork_not_implemented}` when target mode is distributed/serverless.
- Update the test to assert that transition-to-distributed currently returns an explicit error, not silent success.
- Document in module @moduledoc that Phase 2 lands the implementation.

**Option C — Defer entirely to Phase 2 `[I, S, 30m]`**
- Mark with a `# PHASE-2:` comment, leave the stub return, but add a `Logger.warning` at the call site so a deployment that hits this path is loud in logs.

### 5.3 Recommendation

**Option B.** The scoping doc explicitly schedules "Topology Modes Runtime" to Phase 2 (§5). Phase 1's contract is honest-failure. Option B satisfies that contract in two hours. Option A is genuinely a Phase 2 task because (i) it depends on Workstream 1.6 landing first, (ii) the data model demands a design decision that has not been made, and (iii) the cross-server Avow exchange that should accompany a real fork is itself a Phase 2 deliverable. Option C is rejected because a `Logger.warning` does not satisfy "tested to fail loudly with a clear error" (§5).

Tasks (Option B):
- `[A]` Change return type and update `transition_room/2` to propagate. **S (1h).**
- `[I]` Update `topology_test.exs:128-132` to assert `{:error, :fork_not_implemented}` for distributed/serverless target modes; assert `:ok` for monarchic/oligarchic. **S (30m).**
- `[I]` Module docstring update flagging Phase 2 follow-on. **S (15m).**

---

## 6. Workstream 1.4 — Discord xsalsa20_poly1305 audit (security-critical)

### 6.1 Current state

`bridges/discord.ex:942-962` (encrypt) and `964-989` (decrypt) use Erlang `:crypto.crypto_one_time_aead(:xchacha20_poly1305, ...)`. Two issues:

1. **The cipher name is wrong.** Discord voice uses **NaCl's `xsalsa20_poly1305`** (Salsa20 with extended 24-byte nonce + Poly1305). The code uses **`xchacha20_poly1305`** (ChaCha20 with extended 24-byte nonce + Poly1305). These are *different* ciphers with the *same nonce/key sizes*. Discord servers will reject packets encrypted with the wrong cipher. The code path *appears* to work because OTP 24+ does support `:xchacha20_poly1305` in `:crypto`, so the `rescue` is rarely triggered — but the wire output is wrong even when "successful".
2. **The encrypt `rescue` returns `plaintext`.** On line 961, if `:crypto` raises, the function returns the raw Opus frame as if it were encrypted. The caller at line 868 wraps this into an RTP packet and sends it to Discord's voice UDP. This is a silent confidentiality failure. The decrypt side at line 988 honestly returns `{:error, :not_available}`, but the encrypt side does not.

### 6.2 Required fixes

**[C] Decide on cipher provisioning** — S (1h):
- OTP `:crypto` provides `:chacha20_poly1305` and `:xchacha20_poly1305` but **not** `:xsalsa20_poly1305`. Discord has historically required xsalsa20; as of 2024 it added support for `xchacha20_poly1305` (with the `aead_xchacha20_poly1305_rtpsize` mode) — verify which mode the current Discord voice gateway negotiates by reading the `Ready` payload `modes` field.
- If only `xsalsa20_poly1305` is acceptable to the negotiated session, add the `:enacl` hex dependency (libsodium NIF) and call `:enacl.secretbox/3` and `:enacl.secretbox_open/3`.

**[A] Cipher negotiation logic** — M (2-3h):
- At session establishment (where the gateway sends `mode` in `Ready`), select the cipher: if peer advertises `aead_xchacha20_poly1305_rtpsize`, use `:crypto`; if peer advertises `xsalsa20_poly1305`, require `:enacl`.
- Replace the `mode => "xsalsa20_poly1305"` literal at line 791 with the negotiated mode.

**[I] Loud-fail the silent-plaintext path** — S (30m, MUST land regardless of A/B/C above):
- Change line 961 from `plaintext` to `raise "[DiscordBridge] xsalsa20_poly1305 unavailable — cannot send unencrypted voice frame"`. The supervisor restart is the correct semantic: a bridge that cannot encrypt must not transmit.
- Add a startup probe in `BurbleBridges.Discord.init/1` that calls `:crypto.crypto_one_time_aead/6` with a known key/nonce/plaintext; if it raises, refuse to start the bridge with `{:stop, :cipher_unavailable}`.

**[I] Tests** — S (1h):
- `test/burble/bridges/discord_crypto_test.exs` asserting (1) encrypt round-trips correctly for `xchacha20_poly1305`, (2) on simulated `:crypto.crypto_one_time_aead/6` raise (via meck), the bridge crashes rather than sending plaintext, (3) startup probe runs.

### 6.3 Marr & effort

`[C]` cipher choice — S (1h).
`[A]` negotiation — M (2-3h).
`[I]` loud-fail + probe + tests — S (2h).
Total: **M (5-6h).**

This is the highest-priority workstream after 1.6.

---

## 7. Workstream 1.5 — Opus transcode honest-failure audit

### 7.1 Scope

`opus_transcode/4` is the Backend behaviour callback that returns `{:error, :not_implemented}` on all four backends (`ElixirBackend`, `ZigBackend`, `SmartBackend`, `SNIFBackend`). The contract test `test/burble/coprocessor/opus_contract_test.exs` already asserts this. The audit verifies that **no production caller silently swallows the error**.

### 7.2 Search results

I grepped `server/lib/burble/` for `opus_transcode` calls outside of the coprocessor self-delegation chain:

```
grep -rn "opus_transcode" server/lib/burble/ --include='*.ex' | grep -v coprocessor
# → (no matches)
```

**No production code calls `opus_transcode/4`.** The SIP bridge bypasses it via `opus_to_pcm_stub/1` (the Workstream 1.1 target). The Mumble bridge does not transcode server-side. The Discord bridge forwards Opus frames opaquely. The `opus_transcode/4` callback is therefore an honest-but-disconnected contract: it would be the right place to land Workstream 1.1 Option A.

### 7.3 Tasks

- `[I]` Add a coprocessor-pipeline integration test that calls `SmartBackend.opus_transcode/4` with a real Opus frame fixture (from `test/fixtures/`) and asserts `{:error, :not_implemented}` is returned, plus that no Logger output is emitted (proving no silent-fail log scrubs the error). **S (1h).**
- `[A]` After Workstream 1.1 lands as Option C, wire the SIP bridge's now-unused PCMU/PCMA branches to call `SmartBackend.opus_transcode/4` *if* a future Option A backend lands; the call site is the canonical extension point. **S (1h, can be deferred to Phase 4 alongside Option A).**

`[I+A]`, total S (2h).

---

## 8. Workstream 1.6 — VeriSimDB migrator nxdomain (deployment blocker)

### 8.1 Diagnosis

The deployed log line `[Burble.Store.Migrator] Migration v1 failed: {:network_error, :nxdomain}` originates from `verisim_client.ex:167` (`{:error, {:network_error, reason}}`). The path is:

```
Burble.Store.init/1
  -> VeriSimClient.new(url) succeeds (URL parse only)
  -> Burble.Store.Migrator.run(client)
    -> VeriSimClient.Search.text(client, "_migration:burble", limit: 1)
      -> VeriSimClient.do_get(client, "/api/v1/search/text?...")
        -> Req.get(url) where url = "http://verisimdb:8080" + "/api/v1/search/text?..."
        -> {:error, {:network_error, :nxdomain}}
```

The compose service hostname `verisimdb` is supplied via `VERISIMDB_URL=http://verisimdb:8080`. Three plausible causes:

1. **Container network resolution race.** The server container starts before VeriSimDB's container has joined the `burble-net` bridge network. Compose `depends_on: service_healthy` is configured but only waits for the healthcheck **TCP**, not for *DNS propagation in the server's resolver cache*. First migrator call lands within the brief window where the resolver cache is empty.
2. **Wrong network attachment.** The server container might be on a different network than VeriSimDB. The compose file (`containers/compose.toml`) declares both on `burble-net`, but `coturn` uses `network_mode = "host"` — verify the server is in fact on the bridge.
3. **Stale `.env` overriding `VERISIMDB_URL`** with `localhost:8080`. The compose env block uses `"VERISIMDB_URL=http://verisimdb:8080"` literally (no `${...}`), so this should not happen — but worth ruling out by inspecting the running container's env.

### 8.2 Investigation plan

- `[I]` `podman exec burble-server-1 env | grep VERISIMDB` — confirm what the running container actually has. **S (15m).**
- `[I]` `podman exec burble-server-1 getent hosts verisimdb` — confirm DNS resolves inside the container. **S (15m).**
- `[I]` `podman exec burble-server-1 wget -q -O- http://verisimdb:8080/health` — confirm reachability. **S (15m).**
- `[A]` If DNS resolves at probe time but not at boot, add a startup retry loop in `Burble.Store.init/1`. **S (1h).**

### 8.3 Fix options

**Option A — Boot-time retry with exponential backoff in `Burble.Store.init/1`** `[A+I, S, 2h]` (RECOMMENDED)
- Wrap `VeriSimClient.health(client)` in a 5-attempt × 1s..16s backoff loop *before* invoking the migrator. If all attempts fail, return `{:stop, :verisimdb_unreachable}` (loud failure, not silent continuation).
- Pros: robust to compose ordering races; the canonical fix in OTP applications.
- Cons: lengthens boot time by up to ~30s in the failure case.

**Option B — Tighten compose `depends_on` healthcheck** `[A+I, S, 1h]`
- Change the VeriSimDB healthcheck to require **two** consecutive successes before reporting `healthy` (using `start_period`). This often eliminates the race.
- Pros: pure infrastructure fix.
- Cons: doesn't help in environments where the server is started before VeriSimDB at all (e.g., k8s during initial pod schedule).

**Option C — Combined.** Do both. **(RECOMMENDED.)**

### 8.4 Tasks

- `[I]` Diagnostic probes (above) to confirm root cause. **S (1h).**
- `[A]` Boot-time retry loop in `Burble.Store.init/1`. **S (1.5h).**
- `[I]` Healthcheck tightening in `containers/compose.toml`. **S (30m).**
- `[I]` Smoke test: add `just smoke-deploy` recipe that brings the stack up, waits 30s, and asserts no `:nxdomain` in `burble-server` logs. **S (1h).**

`[A+I]`, total S (4h).

**Critical observation:** the existing `Burble.Store.init/1` at line 240 catches migrator failure and *continues anyway* ("Continue anyway — the migration failure is logged but non-fatal"). This is itself a silent-failure pattern. The retry loop in Option A should be paired with **promoting migration failure to `{:stop, ...}`** so a failed boot is loud.

---

## 9. Cross-workstream coordination

| | 1.1 SIP Opus | 1.2 SIP SRV | 1.3 Fork | 1.4 Discord | 1.5 Audit | 1.6 Migrator |
|---|---|---|---|---|---|---|
| **1.1 SIP Opus** | — | independent | independent | independent | **1.5 depends on 1.1** | independent |
| **1.2 SIP SRV** | independent | — | independent | independent | independent | independent |
| **1.3 Fork** | independent | independent | — | independent | independent | **soft dep** (the loud-fail variant doesn't need 1.6; only the real-impl Option A would) |
| **1.4 Discord** | independent | independent | independent | — | independent | independent |
| **1.5 Audit** | hard dep | independent | independent | independent | — | independent |
| **1.6 Migrator** | — | — | — | — | — | — |

- **1.6 first** because every test that touches `Burble.Store` is currently flaky.
- **1.1 before 1.5** because 1.5 wants to verify the new caller-side propagation pattern.
- **1.2, 1.3, 1.4 fully parallel.**

---

## 10. Parallelizable workstream table

| Workstream | Marr mix | Suggested tier | Dependencies | Estimated wall-clock |
|---|---|---|---|---|
| 1.6 VeriSimDB migrator nxdomain | C+A+I | Sonnet | none — must land first | S, 4h |
| 1.4 Discord cipher correctness | C+A+I | Sonnet (security review by Opus) | independent | M, 5-6h |
| 1.1 SIP Opus (Option C: loud-fail) | C+A+I | Sonnet | independent | S, 3-4h |
| 1.2 SIP DNS SRV | A+I | Haiku | independent | S, 3h |
| 1.3 Topology fork (Option B) | A+I | Haiku | independent | S, 2h |
| 1.5 Opus transcode caller audit | I+A | Haiku | needs 1.1 merged | S, 2h |

Total wall-clock with full parallelisation: **~8-10h after 1.6 lands**, i.e., 1.6 (half-day) → parallel-dispatch the rest (1 day) → 1.5 finalisation (2h). **Two-week budget has ~9 days of slack** for unforeseen issues — most likely consumed by Discord cipher (1.4) if `:enacl` integration is needed, or by SIP regression testing.

---

## 11. Phase 1 exit criteria

Concrete, observable, automatable:

1. **No silent-failure stubs remain.** All three pass:
   - `grep -n "opus_to_pcm_stub" server/lib/burble/bridges/sip.ex` returns empty.
   - `grep -A2 "rescue" server/lib/burble/bridges/discord.ex | grep -E "^\s*plaintext\s*$"` returns empty (the `plaintext`-return-on-rescue is gone).
   - `grep -n "{:ok, :stub}" server/lib/burble/topology/transition.ex` returns empty (Option B replaces with `{:error, :fork_not_implemented}`).

2. **All remaining `{:error, :not_implemented}` returns are tested.**
   - `grep -rE ':not_implemented' server/lib/burble/coprocessor/ --include='*.ex' | wc -l` ≤ **6** (4 backend impls + 1 SmartBackend dispatcher + 1 in the @callback docstring). Exact number to be locked in the final commit.
   - `mix test test/burble/coprocessor/opus_contract_test.exs` passes.
   - Each `:not_implemented`-returning function has a test that exercises it.

3. **Migrator boots clean.**
   - `just deploy && sleep 30 && podman logs burble-server-1 2>&1 | grep -c "nxdomain"` returns `0`.
   - `podman logs burble-server-1 2>&1 | grep "Migration v1 applied successfully"` returns ≥1 line.

4. **SIP codec negotiation is honest.**
   - Asterisk/Kamailio test fixture offering `PCMU/8000` only → SIP bridge returns `488 Not Acceptable Here`.
   - Test fixture offering `opus/48000/2` → SIP bridge returns `200 OK`.
   - No frame on any code path returns silence-PCM as if it were decoded audio.

5. **Discord encrypt path cannot ever send plaintext.**
   - Unit test asserts that on simulated cipher unavailability, the bridge process exits rather than sending an unencrypted frame.
   - Startup probe is exercised by an integration test.

6. **Topology transitions to distributed/serverless return explicit errors until Phase 2.**
   - `Burble.Topology.Transition.transition_room("x", :distributed)` returns `{:error, :fork_not_implemented}`, not `:ok`.

7. **Smoke test green:** `just deploy && just smoke-deploy` exits 0.

8. **CI green:** `.github/workflows/elixir-ci.yml` passes on the merge commit.

---

## 12. Risks and contingencies

**R-1.4a — `:enacl` may not compile on the CI runner** (NIF requires libsodium-dev).
- *Detection:* `mix deps.compile enacl` fails in CI.
- *Response:* fall back to `:crypto.crypto_one_time_aead(:xchacha20_poly1305, ...)` only and add a runtime check in the gateway-mode-negotiation path that refuses `xsalsa20_poly1305` sessions with a clear error. Document the limitation in `bridges/discord.ex` @moduledoc.

**R-1.6a — Root cause is not the boot race but a config typo.**
- *Detection:* `podman exec ... env | grep VERISIMDB` shows wrong value.
- *Response:* fix `containers/compose.toml` or `.env` template; document; the retry-loop landing remains valuable defence-in-depth.

**R-1.1a — Option C breaks a downstream Mumble bridge test that relied on G.711 transcoding.**
- *Detection:* `mix test` shows previously-passing bridge tests failing.
- *Response:* the Mumble bridge does not use `opus_to_pcm_stub` (greps confirm); but if a hidden caller surfaces, treat it as a separate stub instance and apply the same loud-fail pattern.

**R-1.3a — Test `topology_test.exs:128-132` already asserts "either `:ok` or `{:error, _}`"** — Option B does not require a test update for *passing*, but the assertion is too loose. The actual update tightens it to `assert {:error, :fork_not_implemented} = Transition.transition_room(...)`. If a different caller of `transition_room/2` exists in the supervision tree and relies on `:ok`, that caller will break.
- *Detection:* `grep -rn "Topology.Transition.transition_room\|Transition.transition_room" server/lib/` — currently empty outside tests.
- *Response:* if a caller surfaces, add a small `case` to translate the new error tuple at that call site.

**R-1.2a — `:inet_res.lookup/3` is unreliable inside containers without `/etc/resolv.conf` configured for DNS over the bridge.**
- *Detection:* unit test against meck-stubbed resolver passes; container integration test fails.
- *Response:* document the requirement that the container have `/etc/resolv.conf` pointing at the compose-network DNS (the default Podman bridge already does this); add a `Logger.warning` at startup if `:inet_res.dns_servers/0` returns empty.

**R-1.5a — Audit reveals a hidden silent swallow** (`case opus_transcode(...) do _ -> ... end` without an explicit `{:error, _}` clause).
- *Detection:* `grep -B2 -A5 "opus_transcode" server/lib/` reviewed by hand.
- *Response:* add the missing `{:error, reason} -> Logger.error(...); {:error, reason}` clause and a test for it. Already-known: no production caller exists, so this risk is low.

**R-X — Unknown unknowns from running tests.** Phase 1 is forbidden from running tests per planning constraint, so an unknown failure can only be discovered during execution.
- *Response:* execution session should run `mix test` after each workstream's merge, not at the end. The TDD skill is appropriate for individual workstreams.
