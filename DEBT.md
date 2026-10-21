<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# Burble — debt register

**Measured 2026-08-07** against `origin/main` @ `2c3e61d`. Every item below
carries the command that produced its evidence. Nothing here is inferred from
another document's claim — where a published claim did *not* reproduce, that
mismatch is itself an item.

**Re-measured 2026-10-21** (maintenance sweep, see
[`docs/reports/maintenance/maintenance-2026-10-21.md`](docs/reports/maintenance/maintenance-2026-10-21.md))
— `S-1` is now resolved, `S-2`–`S-4` still reproduce.

This file is an **index**, not a replacement. The pre-existing registers remain
authoritative in their own domains and are linked, not duplicated:
[`PROOF-NEEDS.md`](PROOF-NEEDS.md) · [`BURBLE-PROOF-STATUS.md`](BURBLE-PROOF-STATUS.md) ·
[`TEST-NEEDS.md`](TEST-NEEDS.md) · [`READINESS.adoc`](READINESS.adoc) ·
[`docs/tech-debt-2026-05-26.md`](docs/tech-debt-2026-05-26.md).

Severity is about **consequence if left alone**, not effort.

> **Method caveat.** No build was run for this sweep (it would write `_build`);
> test figures are *source-macro counts*, not pass counts. At the time of
> measurement `main` did not compile, so there were no pass counts to be had —
> see B-1.

---

## Summary

| Domain | Items | HIGH |
|---|---|---|
| Build | 1 | 0 (resolved) |
| Supply chain | 4 | 3 |
| CI/CD | 5 | 3 |
| Licence | 4 | 3 |
| Documentation | 6 | 3 |
| Code | 4 | 3 |
| Proof | 4 | 2 |
| Test | 3 | 1 |
| **Total** | **31** | **18 open + 1 resolved** |

---

## Build

### B-1 — `main` did not compile for three days · HIGH · RESOLVED 2026-08-07 (#189)

`server/lib/burble/protocol/voice_signal.ex` calls `leave_reason/1` at line 208;
the function is not defined in the module. The whole Elixir suite dies at
`mix compile`.

```
git show origin/main:server/lib/burble/protocol/voice_signal.ex | grep -n leave_reason
# -> 208:    reason = leave_reason(reason_raw)   (no `def leave_reason` anywhere)
```

Cause: merge `d865529` (2026-08-04 22:22:00) resolved a conflict in this
**generated** file by mixing both sides — deleting the `leave_reason/1` block
and reverting `encode_leave/1` to the string form while keeping the new
byte-reading `decode_leave/1`. #179 merged twelve seconds later, before CI
could report. The module is the *default* signalling plane since #180, so the
default wire path pointed at code that would not load.

**Resolved.** #189 merged 2026-08-07; the schema and generator were untouched,
so regeneration reproduced the lost file byte-identically (sha `4d4f5ca7`).
Verified on `main`: Elixir CI green at `89dde83`, and the armed Check B
drift gate passes — so the committed codecs are once again exactly what
`mix bebop.generate` produces.

**Lesson worth keeping:** generated files are the worst possible merge
conflicts — the resolution *looks* plausible and no human reads 400 lines of
emitted code. Prefer regenerating over resolving.

---

## Supply chain

### S-1 — `ex_webrtc 0.16.0` is retired with a DTLS auth advisory · HIGH · RESOLVED 2026-10-21

Resolved: `mix.lock` now pins `ex_webrtc 0.17.0`, past the retired release.
The analysis below is kept as the record of the finding.


The only retired package in the lock, and it is the media plane:

```
grep -oE ':hex, :[a-z_0-9]+, "[0-9][^"]*"' server/mix.lock \
  | ... | curl -s https://hex.pm/api/packages/$p/releases/$v | grep retirement
# ex_webrtc 0.16.0 -> "Missing DTLS fingerprint check in client-role
#   handshake; weakens auth. Upgrade to 0.15.1/0.16.1."
```

`mix.exs` already declares `{:ex_webrtc, "~> 0.16"}`, which permits 0.16.1 —
**only `mix.lock` holds it back.**

**Next move:** `mix deps.update ex_webrtc`, run the media tests, commit the
lock. One line, closes a live auth weakness.

### S-2 — `verisim_client` is a git dep with no ref, tag or commit · HIGH

```
grep -A2 verisim_client server/mix.exs
# {:verisim_client, git: "https://github.com/hyperpolymath/verisimdb.git", sparse: ...}
```

No `tag:`, no `ref:`. `mix.lock` pins a SHA today, but nothing prevents an
unlocked resolve from taking whatever HEAD happens to be. This is the
persistent-store client.

**Next move:** add `tag:` or `ref:` pinning an audited commit.

### S-3 — three `deno.json` manifests, zero `deno.lock` · HIGH

```
git ls-tree -r --name-only origin/main | grep -c deno.lock   # -> 0
git ls-tree -r --name-only origin/main | grep deno.json      # -> admin/, client/lib/, client/web/
```

Deno dependencies are unpinned and the JS/TS side is not reproducible.

**Next move:** `deno cache --lock=deno.lock --lock-write` in each, commit.

### S-4 — two `build.zig`, zero `build.zig.zon` · MEDIUM

Same class as S-3 for the Zig side. Lower severity only because the Zig tree
currently vendors rather than fetches.

---

## CI/CD

### C-1 — eight workflows have NEVER produced a single success · HIGH

```
gh run list --repo metadatastician/burble --workflow <w>.yml --limit 100 \
  --json conclusion | jq 'group_by(.conclusion)|map({(.[0].conclusion):length})|add'
```

| Workflow | Conclusions (last ≤100) |
|---|---|
| `governance.yml` | failure 99, startup_failure 1 |
| `instant-sync.yml` | failure 98, startup_failure 2 — logs `Bad credentials` (expired PAT) |
| `secret-scanner.yml` | failure 95, startup_failure 5 |
| `install-roundtrip.yml` | failure 47, startup_failure 3, cancelled 9 |
| `pages.yml` | startup_failure 1 (one run, ever) |
| `publish-verisimdb.yml` | failure 12, startup_failure 1 |
| `release.yml` | failure 1 |
| `push-email-notify.yml` | skipped 93, startup_failure 7 — never ran a real job |

Five more sit above 80% red. **`secret-scanner` is a security gate that has
never once run clean.** Red is the normal state here, which means nobody can
be reading the board — the signal is gone.

**Next move:** triage as a batch, not individually. Six of these are
reusable-callers whose lockfile entries were missing until #190; re-measure
after it merges and only then chase what remains.

### C-2 — `no-js-scan` is structurally incapable of failing · HIGH

`no-js-scan.yml:99` ends `exit 0`, commented `# Warn-first: never fail the
build.` History: **24 runs, 24 successes** — because it cannot be anything
else.

**Next move:** either arm it or delete it. A gate that cannot fail is worse
than no gate: it converts an unknown into a false assurance.

### C-3 — `static-analysis-gate` zeroes its own findings on error · HIGH

`:54-58` and `:159-163` end every `jq` severity extraction with `|| echo 0`;
`:125,132` are `continue-on-error: true`; `:134` clones the scanner with
`|| true`. If the findings file is absent or malformed — or the tool fetch
fails — every severity count silently becomes `0` and the gate passes.
History: 96/100 green, on a repo that does not compile.

**Next move:** fail on missing/malformed findings rather than defaulting to
zero. `|| echo 0` on a *severity count* is the fake-gate pattern in its purest
form.

### C-4 — `web-client-tests` masks ~5 known-broken test files · HIGH

`web-client-tests.yml:46` is `continue-on-error: true`. `TEST-NEEDS.md`
separately records that ~5 of the 10 JS test files import
`BurbleSignaling.res.mjs` / `BurbleVoice.res.mjs` from `client/web/lib/src/`,
a path that does not exist (the modules live at `client/lib/src/`). All 22
"success" runs are green regardless.

**Next move:** fix the import paths, then arm the job.

### C-5 — Dialyzer advisory lane 74 days past its stated re-arm · MEDIUM

`elixir-ci.yml:170` `continue-on-error: true`, honestly commented
"GATE NARROWED 2026-05-25 … re-arm in a follow-up". The follow-up has not
happened.

---

## Licence

### LIC-1 — nine AGPL files in an MPL-2.0 repo, with no AGPL licence text · HIGH

```
for f in $(git ls-tree -r --name-only origin/main); do
  git show origin/main:"$f" | grep -ho "SPDX-License-Identifier: [A-Za-z0-9.+-]*"
done | sort | uniq -c
# 570 MPL-2.0 | 103 CC-BY-SA-4.0 | 9 AGPL-3.0-or-later
ls LICENSES/     # -> CC-BY-SA-4.0.txt, MPL-2.0.txt  (no AGPL text)
```

The nine are `.github/DISCUSSION_TEMPLATE/*`, `.github/ISSUE_TEMPLATE/*` and
`.github/settings.yml` — template drift from another estate repo. `reuse lint`
would fail on the missing licence text.

**Next move:** decide per file whether AGPL was intended (it almost certainly
was not, for issue templates) and correct the identifier — **do not** blanket
add an AGPL licence file to make the lint pass. Estate precedent warns that
imposing an identifier rather than moving/correcting it mis-licenses files.

### LIC-2 — `dep5` was an unrendered template naming the wrong project · HIGH → fixed here

```
git show origin/main:.machine_readable/compliance/reuse/dep5 | head
# Upstream-Name: {{PROJECT_NAME}}
# Source: https://github.com/hyperpolymath/grumble     <-- wrong repo
# Copyright: {{CURRENT_YEAR}} {{AUTHOR}}
```

Every field was a placeholder and `Source:` pointed at a different project.
Rendered in this change with burble's real values. The licence *mappings* it
declares were already correct and are unchanged — only the identity fields were
substituted, so this does not re-license anything.

### LIC-3 — no `reuse lint` anywhere · HIGH

```
grep -rni 'reuse' --include='*.yml' --include='Justfile' .
# only the English word "reuse" in a comment
```

No REUSE job, no `.reuse/` directory, no Justfile recipe. LIC-1 and LIC-2 have
therefore never been detectable. **This is the item that makes the other three
recur.**

### LIC-4 — three unbacked compliance badges (REMOVED 2026-08-07) · HIGH → resolved

`README.adoc` displayed hardcoded "SOC 3 Compliant", "ISO 27001 Compliant" and
"CIAQ Compliant" badges linking to
`https://github.com/organizations/metadatastician/settings/compliance` — an org
**admin** page that 404s for every reader who is not an owner. No report,
auditor, certificate number, scope or attestation date exists in the repo. A
SOC 3 report is by definition public; there was none.

A fourth, "OpenSSF Best Practices", was a hardcoded green image pointing at the
project-**creation** form under the wrong org (`hyperpolymath/`, not
`metadatastician/`) — the project was never registered.

Removed in this change, with the reasoning kept as a comment in `README.adoc`
so they are not silently reinstated. Re-add any of them the moment a real
artefact exists to link to.

---

## Documentation

### DOC-1 — CHANGELOG is 28 days and ≥11 merged PRs stale · HIGH

```
git show origin/main:CHANGELOG.md | grep -nE '#17[89]|#18[0-9]|[Bb]ebop'   # -> nothing
git log origin/main -1 --date=short -- CHANGELOG.md                        # -> 2026-07-10
```

Unrecorded: #178/#179/#180 (two wire-format changes and the default flip),
#181/#182/#185 (a whole new game-session lane), #186/#187.

Addressed in this change for the Bebop and game-session work; the remainder
needs an owner pass.

### DOC-2 — README did not mention Bebop · HIGH → fixed here

The signalling plane went default-on on 2026-08-04 (#180); the README's last
edit was 2026-07-26 and contained zero occurrences of "bebop". A reader had no
way to learn the wire format had changed. Fixed in this change.

### DOC-3 — the CRG grade is stated as three different values · HIGH

| Source | Grade |
|---|---|
| `README.adoc` ×2 | **C** (targeting B) |
| `.machine_readable/descriptiles/STATE.a2ml` | **C** (regraded 2026-07-11) |
| `READINESS.adoc:7` | **D** (provisional, targeting C) |
| `TEST-NEEDS.md:3` | **D** (targeting C — blocked on #100) |

The document whose *entire purpose* is to state the grade — `READINESS.adoc`,
`:revdate: 2026-04-21` — is the one that is wrong. README and STATE.a2ml agree
on C and carry the later regrade.

**Next move:** make `READINESS.adoc` the single source and have the others cite
it, rather than four independent copies.

### DOC-4 — three root docs cite a CLOSED issue as the live blocker · MEDIUM

`TEST-NEEDS.md`, `ROADMAP.adoc` and `READINESS.adoc` all say the CI test gate
is disarmed, blocked on issue #100. Issue #100 is **closed**, and
`elixir-ci.yml`'s "Run server tests" step has no `continue-on-error` — the gate
was re-armed on 2026-07-07 and `README.adoc` already says so.

```
gh issue list --repo metadatastician/burble --limit 50 | grep '#100'   # absent
git show origin/main:.github/workflows/elixir-ci.yml | sed -n '94,103p'
```

### DOC-5 — `QUICKSTART-DEV.adoc` 132 days untouched · MEDIUM

`git log origin/main -1 --date=short -- QUICKSTART-DEV.adoc` → 2026-03-28.
The onboarding path most likely to be followed first is the least maintained.

### DOC-6 — `container/` is an uninitialised template subtree · LOW

`TOPOLOGY.md:83` honestly self-reports `` `container/` — uninitialized
{{PLACEHOLDER}} template tree``. Credit for declaring it; it still needs doing.

---

## Code

### CODE-1 — `SNIFBackend` implements 10 of 32 mandatory callbacks · HIGH

```
git show origin/main:server/lib/burble/coprocessor/backend.ex \
  | grep -cE '@callback'          # -> 32, and no @optional_callbacks
git show origin/main:server/lib/burble/coprocessor/snif_backend.ex \
  | grep -cE '^\s*def '           # -> 10
```

Missing 22, including `neural_init_model/1`, `crypto_encrypt_frame/…`,
`crypto_decrypt_frame/…`, `crypto_derive_frame_key/…` and every compression
callback. The other three backends (`elixir_backend`, `zig_backend`,
`smart_backend`) each implement all 32 — SNIF is the sole offender.

This is **not** a graceful degrade. `available?/0` gates on *wasmex being
absent*; when SNIF **is** present, a dispatch to any of the 22 is an
`UndefinedFunctionError` at runtime, in the media path.

**Next move:** either implement them, or delegate the unimplemented set to
`ZigBackend`, or mark them `@optional_callbacks` and make `SmartBackend`
route around them. Any of the three is fine; the current state is not.

### CODE-1a — the client's E2EE module was not encryption · RESOLVED 2026-10-21

`client/web/src/app/voice/E2EE.res` opened with *"Algorithm: AES-256-GCM / Key
Derivation: HKDF-SHA256"* and encrypted each frame by XORing it with the local
private key, repeated. It also derived that key from **one peer's** private key,
so two participants could never have agreed on one.

It was harmless by accident, not by design: nothing imported it, and the
generated `.res.mjs` in a working tree referenced three variables it never
defined (so it would have thrown). Evidence:

```
grep -rn 'E2EE\.\(initialize\|applyToConnection\)' --include=*.res --include=*.affine client/ | wc -l   # -> 0
grep -n 'ACTUAL ENCRYPTION' client/web/src/app/voice/E2EE.res          # -> "Placeholder XOR for structural proof"
```

**Resolved:** the module is now a failing stub that names `client/web/e2ee.js`,
the real WebCrypto implementation, which is pinned against the server's output
by `client/web/tests/fixtures/e2ee-vectors.json`. **Still open:** wiring that
module into the call path, and the WebRTC Encoded Transform (ADR-0016 §Gaps).

### CODE-2 — load-bearing modules with no matching test file · HIGH

50 of 126 `server/lib/burble/**.ex` modules have no name-matching test.
The ones that matter: `auth/auth.ex`, `auth/guardian.ex`,
`auth/guardian_pipeline.ex`, `security/mtls.ex`, `security/key_rotation.ex`,
`verification/avow.ex`, `protocol/voice_signal.ex` (the file that broke `main`).

**2026-10-21:** `media/e2ee.ex` now has `server/test/burble/media/e2ee_test.exs`
(peer-side protocol, coordinator state machine, and an assertion that no
key-returning function is exported). `security/key_rotation.ex` still has none —
its remaining work is inseparable from `E2EE`, which is now tested.

**Caveat, stated because it changes what you should do with this:** this is a
*filename heuristic*. Some are genuinely exercised inside other suites — treat
it as a candidate list to verify, not a verdict to act on.

### CODE-3 — `verification/avow.ex` has neither test nor runtime enforcement · HIGH

No matching test, and `BURBLE-PROOF-STATUS.md` states Avow "is
data-type-only. No dependent-type verification at runtime." So the module
carrying a formal non-circularity proof has no runtime teeth and no test.

### CODE-4 — a file named `p2p-voice-pake.html` that is not PAKE · MEDIUM

```
git grep -n 'PROD-TODO' -- client
# client/web/p2p-voice-pake.html:14 // PROD-TODO: this is HKDF over the
#   passphrase. It is NOT PAKE.
```

The disclaimer is in the source, which is honest — but the *filename* is the
claim most people will read.

**Next move:** rename to `p2p-voice-hkdf-prototype.html` until it is PAKE.

`server/lib` carries **zero** TODO/FIXME/XXX/HACK, which is genuinely good and
worth preserving.

---

## Proof

### P-1 — no proof gate in CI at all · HIGH

11 `.idr` modules and `burble-abi.ipkg` exist. No workflow builds them.

```
grep -rniE 'idris|coq|lean|proof' .github/workflows/
# only pages.yml (an idris2-pack container running the Ddraig SSG — not the
# ABI proofs) and rhodibot.yml (a grep count)
```

The single idris2-touching workflow, `pages.yml`, has **one run in its entire
history and it was a startup_failure.**

**Next move:** an ipkg-based `idris2 --typecheck burble-abi.ipkg` job. Note the
estate rule: per-file `idris2 --check` exits 0 on module-not-found *and* on
unsolved holes, so it is a fake gate — the ipkg form is the honest one.

### P-2 — `PROOF-NEEDS.md` marks Idris↔Zig mirroring "(DONE)" with nothing checking it · HIGH

The same file also admits "`just build-proofs` has a path-escaping bug and
idris2 is not yet in CI", which contradicts the `(DONE)`. Nothing verifies the
correspondence between `src/Burble/ABI/*.idr` and `ffi/zig/src/abi.zig`.

### P-3 — `BURBLE-PROOF-STATUS.md` contradicts itself on postulates · MEDIUM

Says "Dangerous-pattern debt: **0 postulate**" and, later in the same file,
"`MediaPipeline` … **1 postulate**". Disk agrees with the second:
`grep -cE '\b(postulate|believe_me|assert_total)\b' src/Burble/ABI/*.idr` →
`MediaPipeline.idr: 1`, all others 0.

### P-4 — two proof modules are undocumented · MEDIUM

`BleSpa.idr` and `NearbyPresence.idr` exist on disk but appear nowhere in
`BURBLE-PROOF-STATUS.md`, so their compile status is unstated and unverified.
The doc is also 79 days stale ("verified 2026-05-20", never re-verified).

---

## Test

### T-1 — published test counts do not reproduce · HIGH

| Claim | Source | Verdict |
|---|---|---|
| "~707 tests, 134–165 failures, CI gate disarmed" | `TEST-NEEDS.md`, `ROADMAP.adoc` | **does not reproduce** — 767 test macros; gate is armed |
| "652 tests / 0 failures locally (1 skipped)" | `READINESS.adoc` | skip count reproduces exactly (1); the 652/0 is unverifiable and was falsified in spirit by B-1 |

Measured on `origin/main`: **767 ExUnit macros** (753 `test "` + 14
`property "`) across 67 files, **51 Deno/JS cases** across 10 files, **41 Zig
test blocks** across 9 files. Exactly one `@tag :skip`
(`server/test/burble/network/chaos_test.exs:100`).

These are **source-macro counts, not pass counts.** Logged rather than silently
corrected, per estate practice.

### T-2 — the fuzz suite is a placeholder file · MEDIUM

`tests/fuzz/placeholder.txt` is the entire fuzz corpus.

### T-3 — no `.formatter.exs` in `server/` · MEDIUM · tracked as #183

`mix format --check-formatted` cannot run at all, so formatting is ungated.

---

## What to do first

1. **Merge #189** (B-1) — nothing else can be verified while `main` does not build.
2. **`mix deps.update ex_webrtc`** (S-1) — one line, closes a live DTLS advisory.
3. **Wire `reuse lint`** (LIC-3) — it is the check that would have caught LIC-1
   and LIC-2, and will catch the next one.
4. **Arm or delete `no-js-scan` and fix `static-analysis-gate`'s `|| echo 0`**
   (C-2, C-3) — false assurance is worse than a known gap.
5. **Resolve `SNIFBackend`** (CODE-1) — it is a runtime crash in the media path,
   not a code-tidiness issue.
