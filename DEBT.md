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

Counted from the entries below on 2026-10-21 — the numbers are a claim like any
other, so they are derived rather than carried forward. `HIGH` is split as
`open / resolved`; the two add up to the HIGH-labelled items in that section.

| Domain | Items | HIGH (open / resolved) |
|---|---|---|
| Build | 1 | 0 / 1 |
| Supply chain | 4 | 1 / 2 |
| CI/CD | 7 | 3 / 2 |
| Licence | 4 | 4 / 0 |
| Documentation | 6 | 3 / 0 |
| Code | 9 | 5 / 0 |
| Proof | 4 | 1 / 1 |
| Test | 3 | 1 / 0 |
| **Total** | **38** | **18 / 6** |

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

### S-3 — three `deno.json` manifests, zero `deno.lock` · HIGH · PARTIAL 2026-10-21

```
git ls-tree -r --name-only origin/main | grep -c deno.lock   # -> 0
git ls-tree -r --name-only origin/main | grep deno.json      # -> admin/, client/lib/, client/web/
```

Deno dependencies are unpinned and the JS/TS side is not reproducible.

**Partly resolved 2026-10-21, on the Bun path.** Bun is now the estate default,
and each of the three JS/TS packages has a committed `bun.lock`
(`client/web`, `client/lib`, `scripts`), so the default install is reproducible.
The Deno route is still unpinned for `admin/`, `client/lib/` and `client/web/`
(only `scripts/deno.lock` exists, and `client/lib/deno.lock` is deliberately
gitignored). That is the remaining half, and it now matters only if someone runs
Deno by hand: nothing in CI does, and no documented command does.

**Next move:** `deno cache --lock=deno.lock --lock-write` in each, commit — or
record that Deno installs are unsupported as reproducible and say so in the
compatibility job's comment.

### S-4 — two `build.zig`, zero `build.zig.zon` · MEDIUM

Same class as S-3 for the Zig side. Lower severity only because the Zig tree
currently vendors rather than fetches.

---

## CI/CD

### C-1 — six workflows have NEVER started, and four more have not run since the summer · HIGH

Re-measured 2026-10-21 18:30Z, last twelve runs per workflow, excluding the
20-run mass event at 18:26 (C-8). The previous version of this entry counted
the whole history, which conflated three different failures: a workflow that
never *starts*, one that starts and fails, and one that has not been *triggered*
in months. Only the first is a workflow defect.

```
for w in .github/workflows/*.yml; do
  gh api "repos/metadatastician/burble/actions/workflows/$(basename $w)/runs?per_page=12" \
    --jq '[.workflow_runs[].conclusion // .status] | group_by(.) | map("\(.[0]):\(length)") | join(",")'
done
```

**Never starts (6) — `startup_failure`, zero jobs, no log, no annotation.**
Every one of them calls a reusable workflow in another repository; see C-6.

| Workflow | Last 12 |
|---|---|
| `governance.yml` | startup_failure 11, failure 1 |
| `hypatia-scan.yml` | startup_failure 11, failure 1 |
| `scorecard.yml` | startup_failure 11, failure 1 |
| `secret-scanner.yml` | startup_failure 11, success 1 |
| `spark-theatre-gate.yml` | startup_failure 11, success 1 |
| `conformance.yml` | startup_failure 5 (new; never run) |

**Starts and fails (2).**

| Workflow | Last 12 | Why |
|---|---|---|
| `publish-verisimdb.yml` | failure 9, startup_failure 3 | Weekly build of `nextgen-databases`' image from this tree — nothing here can fix it. Weekly cron removed 2026-10-21; dispatch kept. |
| `instant-sync.yml` | failure 10, startup_failure 2 | `FARM_DISPATCH_TOKEN` present but expired (`Bad credentials`). The guard checks presence, not validity. Dormant since 2026-07-20. |

**Dormant — not red, not green either (3).**

| Workflow | Last run | Why |
|---|---|---|
| `install-tests.yml` | 2026-09-12 success | Path-filtered to installer files; nothing has touched them. Green when it runs. |
| `install-roundtrip.yml` | 2026-09-12 success | Same. |
| `mirror.yml` | never ran a job | 12/12 `skipped`: `mirror-reusable.yml` gates every forge on a repo variable (`GITLAB_MIRROR_ENABLED`, …) and none is set here. Opt-in by design, but it means burble is mirrored nowhere. |
| `release.yml` | 2026-03-22 failure | One run, ever. Untested, not a red streak. |
| `push-email-notify.yml` | 2026-07-20 skipped | Dormant by design (`PUSH_EMAIL_ENABLED` unset). |

**Green (18)** — `boj-build`, `casket-pages`, `codeql`, `dependency-audit`,
`dogfood-gate`, `elixir-ci`, `idris-abi`, `joinery-native`, `lock-sync-gate`,
`no-js-scan`, `oikosbot`, `rhodibot`, `static-analysis-gate`,
`web-client-tests`, `workflow-safety`, `affinescript-canary`, `label-triage`,
`labels` — measured, not assumed. (31 workflows: 18 + 5 dormant + 6 that never
start + 2 that fail; `pages.yml` was deleted on 2026-10-21.)

So the board is not "mostly red". It is **twenty green lanes, six lanes that
cannot start, and two that never could have passed** — and because the six are
the security and conformance lanes, the green majority is the wrong half of
the surface. `secret-scanner` is the one to keep in view: it is a security gate
with a single success in its last twelve runs.

**Next move:** C-6 for the six. For the rest, the actions landed on 2026-10-21:
the weekly VeriSimDB cron is gone, `pages.yml` (a second, never-working
deployer of the same Pages environment) is deleted, and CodeQL no longer
cancels its own `main` scan.

### C-2 — `no-js-scan` cannot fail, and the policy says it must not yet · HIGH · PARTIAL 2026-10-21

`no-js-scan.yml` ends `exit 0`, commented `# Warn-first: never fail the build.`
History: 45 runs, 45 successes — it is green on every input, which is
indistinguishable from a workflow that does nothing.

The obvious "fix" is wrong. `standards/docs/NO-JAVASCRIPT-SOURCE-POLICY.adoc`
is explicit that a repo flips from warn to block **when its own surface reaches
zero** (`gossamer` is the worked example) and records burble at **14 files** on
2026-06-02. Arming `exit 1` here would be red on every run from the day it
landed, on 25 files that the migration plan already knows about.

What *was* missing is any measurement of direction, and that is the actual
defect: burble is at **25 files today**, up 79% since the policy was written,
and 45 consecutive green runs said nothing about it. The workflow now fetches
the base commit, diffs additions, lists them in the step summary and annotates
them — still non-blocking, per policy, but no longer blind.

**Next move (owner decision, upstream):** the policy has two states, "warn
while non-zero" and "block at zero", and no state for "non-zero and growing".
Either accept growth, or add a ratchet state (`standards` issue needed) so that
`a repo at N files may not exceed N`. Until then this entry records the number
and its direction: **25, rising.**

### C-3 — `static-analysis-gate` zeroes its own findings on error · HIGH

`:54-58` and `:159-163` end every `jq` severity extraction with `|| echo 0`;
`:125,132` are `continue-on-error: true`; `:134` clones the scanner with
`|| true`. If the findings file is absent or malformed — or the tool fetch
fails — every severity count silently becomes `0` and the gate passes.
History: 96/100 green, on a repo that does not compile.

**Next move:** fail on missing/malformed findings rather than defaulting to
zero. `|| echo 0` on a *severity count* is the fake-gate pattern in its purest
form.

### C-4 — `web-client-tests` masks ~5 known-broken test files · HIGH · RESOLVED 2026-10-21

`web-client-tests.yml:46` is `continue-on-error: true`. `TEST-NEEDS.md`
separately records that ~5 of the 10 JS test files import
`BurbleSignaling.res.mjs` / `BurbleVoice.res.mjs` from `client/web/lib/src/`,
a path that does not exist (the modules live at `client/lib/src/`). All 22
"success" runs are green regardless.

**Resolved 2026-10-21.** The import paths were the symptom; the cause was that
only the two E2EE files ran under Bun and the other ten ran under Deno in a
`continue-on-error` job. `tests/runner.js` now picks the runner and
`spawnServer()` starts the helpers on either, so *all* twelve files run in one
gating Bun job with no `continue-on-error` anywhere on that path:

```
cd client/web && bun install && bun run res:build && bun test tests/
 97 pass, 0 fail — 12 files
```

There is no Deno job left in that workflow at all — one runner, nothing
advisory, nothing to keep in sync.

### C-5 — Dialyzer advisory lane 74 days past its stated re-arm · MEDIUM

`elixir-ci.yml:170` `continue-on-error: true`, honestly commented
"GATE NARROWED 2026-05-25 … re-arm in a follow-up". The follow-up has not
happened.

### C-6 — every external-reusable caller stopped starting at 17:18, with no file change · HIGH · OPEN

Six workflows report `startup_failure` — zero steps, no log, no annotation —
on every commit since `86e139dd`. The set is exactly the set of workflows that
call a reusable workflow in another repository:

| Workflow | Callee | Conclusion |
|---|---|---|
| `governance.yml` | `hyperpolymath/standards/…/governance-reusable.yml` | startup_failure |
| `secret-scanner.yml` | `…/secret-scanner-reusable.yml` | startup_failure |
| `scorecard.yml` | `…/scorecard-reusable.yml` | startup_failure |
| `spark-theatre-gate.yml` | `…/spark-theatre-gate.yml` | startup_failure |
| `hypatia-scan.yml` | `…/hypatia-scan-reusable.yml` | startup_failure |
| `conformance.yml` (new) | `…/deed-conformance.yml`, `…/k9-conformance.yml` | startup_failure |

`mirror.yml` calls a reusable too, but only on `push: main`, where it has been
`skipped`. Every workflow that does **not** call an external reusable —
`Web Client Tests`, `Lock Sync Gate`, `Dogfood Gate`, `Idris2 ABI`,
`Static Analysis Gate`, `AffineScript Canary`, `Workflow safety`, CodeQL, and
the rest — is green on the same SHAs.

The transition is one commit and no workflow edit:

```
17:17:17  d265df87  governance.yml  failure           # ran; failed in "Set up job" with the
                                                      # erlef/setup-beam annotation fixed by 88b84ed
17:18:55  86e139dd  governance.yml  startup_failure   # 86e139dd changed
                                                      # client/web/tests/signaling_relay_test.js only
```

So neither the YAML, the pin, nor the callee is the variable *within* this
repository's history. What was ruled out, in order:

- **the callee is missing at the pin** — all eight callee files exist at
  `0d47b892`, and every `with:` input we pass is declared by the callee's
  `on.workflow_call.inputs` (checked mechanically for all eight);
- **a poisoned callee lock** — `scripts/check-upstream-pins.sh` reports
  *9 pins clean* at `0d47b892`; the 13-self-SHA defect was `0f2d9b54`/`9f68971b`
  and is what `88b84ed` fixed;
- **the callee repo moved** — `hyperpolymath/standards` is public,
  not archived, not disabled, and answered normally throughout;
- **the estate is down** — `cicd-squabbler` and `panic-attack` ran
  standards-calling scheduled lanes green at 04:02 and 04:00 today, so external
  reusable calls work elsewhere in the estate.

There is also a discriminator inside this repository. `dogfood-gate.yml` is
green and calls two **actions** in another repository
(`hyperpolymath/deed-ecosystem/validate-action`, `hyperpolymath/k9-ecosystem/
validate-action`); the six red workflows call **reusable workflows** in another
repository. Cross-repo actions resolve; cross-repo reusable workflows do not.
This difference is consistent with a selected-actions policy permitting those
action references while excluding the reusable-workflow references; it does
not establish the cause.

A remaining hypothesis is the effective Actions policy for **this** repository.
"Allow select actions and reusable workflows" uses a single selected-actions
policy covering both actions and reusable workflows. Allowed owners, patterns
and references can permit one set while excluding another. Repository and
organisation policies must be inspected before attributing `startup_failure`
to a policy restriction.

It cannot be confirmed from here. The token this repository's automation runs
with is read-only for Actions administration:

```
gh api repos/metadatastician/burble/actions/permissions                 # 403
gh api repos/metadatastician/burble/actions/permissions/selected-actions # 403
gh workflow run governance.yml --ref <branch>                           # 403 on dispatch
```

**Next move (needs repository/organisation admin):** inspect the effective
repository and organisation Actions policies, including the selected-actions
rules and inherited restrictions. In Settings → Actions → General, check
whether `hyperpolymath/standards/.github/workflows/*` is permitted and adjust
the selected references if needed. Consider "Allow all actions and reusable
workflows" only after that inspection and if the organisation policy permits
it. If the effective policy already permits these references, investigate
fork-secret and outside-collaborator approval settings and other startup
diagnostics. **`startup_failure` with no steps or annotation on the external
reusable callers is evidence to investigate policy, not proof of the cause.**
The earlier YAML investigation is recorded in C-1 and `88b84ed`.

### C-8 — every workflow on the branch failed to start at 18:26, for one commit only · MEDIUM · OPEN

At 18:26Z on 2026-10-21, all twenty workflows triggered by `9731bd0` reported
`startup_failure` — including `lock-sync-gate.yml`, which has no `uses:`, no
secrets, no matrix and no container, and `web-client-tests.yml`, which had been
green nine minutes earlier on the parent commit. Four minutes before, at 18:20,
the same twenty ran normally on `ce5aa20` (all green except the six in C-6).

So this is a second, distinct event: C-6 is six lanes that never start, C-8 is
everything failing to start at once, once.

What is known:

- `9731bd0` is authored by `coderabbitai[bot]`, and the pull request was
  `MERGEABLE` throughout; `git diff --name-status ce5aa20 9731bd0 -- .github/`
  is **empty** — not one workflow file differs;
- all 31 workflow YAML files parse, and `actions.lock` matches all 65 `uses:`
  refs in both directions (checked locally, same algorithm as
  `scripts/check-lock-sync.sh`);
- the same owner's other repositories ran external-reusable lanes normally
  inside that half hour (`marid` at 18:06, `gossamer` at 19:16), so it was not
  the callee and not the organisation's reusable-workflow access.

That leaves a repository-level Actions condition that existed for the length of
that run: disabled Actions, a spending limit, or a policy change reverted
afterwards. None of them is readable with the token available here (403 on
`/actions/permissions`), and none of them leaves a log — `startup_failure` runs
have zero jobs, so `GET /actions/runs/<id>/logs` is a 404.

**Next move:** the falsifiable check is the next push to this branch. If it
starts normally, the event was transient and this entry closes with the
observation only; if it repeats, check Settings → Actions → General
(*Allow all actions* vs allowance list) and the billing/spending-limit banner on
the same page, in that order. Both are one screen.

---

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

### CODE-1b — key registration proves possession, not identity · OPEN 2026-10-21

`Burble.Media.E2EE.register_peer_key/5` accepts an Ed25519 signature over
`room|peer|base64(public_key)`. That proves the sender holds the private key for
the key it is registering, which stops a copied ephemeral key being registered
by someone else.

It does **not** prove who that is: nothing binds the Ed25519 identity key to the
account, so an attacker can register a key of its own and sign it perfectly. The
partial control is the one that was cheap; the real one needs an account-bound
identity key and a decision about where it lives (server-held public key, device
pairing, or a key-transparency log).

Until then `:e2ee_require_key_proof` defaults to `false`: registrations without a
proof are accepted and recorded as `proven: false`, so turning the switch on
cannot silently break an older client — it fails loudly. No shipped client signs
yet.

### CODE-1c — the `.affine` tree is ReScript with a different extension · HIGH · OPEN 2026-10-21

Every `.res` file has an `.affine` sibling (34/34), which looks like a migration
in progress. It is not: the `.affine` files are ReScript source with the
extension changed, and ReScript does not parse as AffineScript. Upstream
`docs/ON-RAMP.adoc` names this exact anti-pattern —

> `.res` written in ReScript is not a face, and renaming `Foo.res` to
> `Foo.affine` does not make it one — it produces a file that fails to parse.

Measured on `affinescript-canary.yml` for this branch: **35 of 36 `.affine` files
report `affinescript check failed`** (a 37th, deliberately broken probe file, was
added and then removed to prove the canary was actually reporting). The number had never been visible — GitHub
caps annotations at ten per check run, and the job log archive is not always
reachable, so the canary reported a handful of files and hid the rest. It now
emits the whole result as one annotation.

Two things hid it:

1. **The canary is advisory.** `continue-on-error: true` on the compile step, and
   the step `exit 1`s internally, so the job shows green while reporting
   failures. A green canary has never meant "these compile".
2. **`client/web/MIGRATION.md` said the compiler was unavailable** — true when
   written (2026-04-21), false since a pinned CLI landed. The "design stub"
   convention it licensed is what produced the unparseable files.

Corrected in this branch: `MIGRATION.md` states that the compiler exists, that
`.affine` must be valid AffineScript, and that it is not on the app's build path;
`src/app/voice/E2EE.affine` (written here, and wrong in exactly this way) is
rewritten as real AffineScript and **verified by the canary** — it is the only
one of the 36 that compiles; the canary now emits the complete failure list as one
annotation instead of being capped at ten.

The rewrite is also the worked answer for the other 35: the failure was not the
function bodies but `use prelude::{Result, Err};`. A consumer file in this repo
cannot resolve the upstream `prelude` module, so it must use only builtins and
declare host functions with `pub extern fn` (the shape of upstream's CI-gated
consumer example). Copying `stdlib/*.affine` verbatim does not work from here.

**Still open:** the other `.affine` files are unparseable, and the canary is still
advisory. Flipping it to gating turns the build red for files nobody has touched;
that needs the migration done or the files deleted, which is a decision rather
than a fix.

**Blocker for the E2EE module specifically:** the client crypto is promise-based,
AffineScript's `extern fn` is synchronous on the wasm target, and the Bun-ESM
target's async externs are partial (upstream #122/#103). The pure parts — frame
header, replay window, leader election, AAD, epoch bookkeeping — are portable
now; the WebCrypto boundary is not.

### CODE-1d — `admin/deno.json` names entry points that do not exist · LOW · OPEN 2026-10-21

`admin/deno.json` defines `gossamer:dev` / `gossamer:build` / `check` in terms of
`dev-server.ts` and `build.ts`. Neither file is in the tree, and neither has ever
existed in the 389 commits of history visible from this shallow clone:

```
find . -name '*.ts' -not -path '*/node_modules/*'           # -> nothing
git log --all --pretty=format: --name-only --diff-filter=A \
  | sort -u | grep -E '\.ts$'                               # -> signaling/relay-deno-deploy.ts only
```

So those tasks cannot run, and they are the reason the admin app "cannot
currently be run from this repo" is stated twice (missing entry points *and*
missing Gossamer shell). The `res:build` / `res:watch` / `clean` tasks shell
out to `npx rescript` and require legacy npm/Node tooling; they are not ready
for a Bun-only environment.

**Next move:** either delete the three tasks and say so in `admin/README.adoc`
(current: the README points at CODE-1d), or write the entry points. Do not
convert the manifest to Bun until they exist — a `package.json` whose scripts
point at missing files would just move the problem.

### CODE-1e — nothing enforces that only the epoch leader seals the room key · HIGH · OPEN 2026-10-21

The design says one peer per epoch seals the group key: `e2ee.ex:16` — "One
peer per epoch (the "key leader" — lowest peer id, deterministic)" — and
`seal_group_key` / `seal_for_peer` are documented "**Peer-side** (leader only)".
The server does not check it:

```
git show origin/main:server/lib/burble/media/e2ee.ex | sed -n 260,261p
#   The caller must authenticate `from`; this function checks membership but
#   does not enforce leadership or validate the blob's cryptographic contents.
```

`publish_sealed/5` therefore accepts a blob from any member, and the receiving
side is no laxer: `E2EESession.onSealedKey` (`client/web/e2ee-session.js:213`)
accepts a blob from any peer present in the key set and calls `setRoomKey`.
Because only one blob per recipient per epoch is stored (later ones get
`already_published`), a non-leader that publishes first wins the race and the
victim encrypts under a key the attacker chose.

This is **not** a documentation contradiction — the docstring is accurate about
what is enforced. It is a missing control.

**Found by** an automated review on #248, whose proposed patch was wrong in
three ways and is not the fix: it mapped the failed check into the `else` clause
so a non-leader's valid blob reports `:invalid_sealed_blob` instead of
`:not_leader`; it made `room_channel_e2ee_test.exs:155` and `:220`
intermittent, because `Auth.create_guest_session/1` assigns random ids
(`auth.ex:63`) and those tests publish from Alice; and it ignored failover, which
`e2ee.ex:40` records as not implemented mid-epoch.

**A correct fix has to do all of:** compute the leader deterministically from the
current membership and return a distinct `:not_leader` error (not a blob error);
reject non-leader blobs on the client too, so the server is not the only
defence; make the tests name the leader explicitly instead of assuming Alice is
it; and decide what happens when the leader leaves mid-epoch, since a
leader-only rule with no failover can strand a room without a key.

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

### P-1 — no proof gate in CI at all · HIGH · RESOLVED (found stale) 2026-10-21

This entry said "no workflow builds them" and cited `pages.yml` as the only
idris2-touching workflow. Both halves are wrong, and the second one was
actively misleading: `idris-abi.yml` exists, runs in an
`idris2-pack` container, and executes `idris2 --build burble-abi.ipkg` — the
ipkg form this entry asked for — on every pull request that touches
`src/Burble/ABI/**`. It is green (9 of its last 12 runs, the rest the C-8
event).

`pages.yml` never touched the proofs at all; it ran the Ddraig static-site
generator. It has been deleted (see C-1) because `casket-pages.yml` deploys the
same `github-pages` environment on the same trigger and is the one that works.

What remains genuinely unverified is P-2 — that the Idris ABI and the Zig FFI
still agree — which type-checking cannot answer.

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
