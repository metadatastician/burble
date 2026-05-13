# Burble Phase 0 — CI and Build Integrity: Implementation Plan

**Date:** 2026-05-07
**Phase:** 0 of 4 (per scoping doc)
**Estimated wall-clock:** 1 week (5 working days)
**Driving doc:** `docs/superpowers/specs/2026-05-07-burble-full-implementation-scoping.md`
**Marr levels:** `[C]` Computational (judgment), `[A]` Algorithmic (design+build), `[I]` Implementational (mechanical)

---

## 1. Plan overview

Phase 0 is the foundation phase. It does not add any user-visible feature; it makes the repository *honest* about whether it builds, tests, and deploys. Without Phase 0 being green, Phases 1–4 cannot be measured (a passing test for a real feature is indistinguishable from a passing test that never ran).

Phase 0 succeeds when:
1. `.github/workflows/elixir-ci.yml` produces a green run on a vanilla GitHub-hosted runner against `main`,
2. `just test` exits 0 on a fresh clone of `main` on Debian 12 after only the documented prerequisite installs,
3. `just build-proofs` is a Justfile recipe that compiles every `.idr` file under `src/Burble/ABI/` and `src/interface/abi/` and exits 0,
4. `coturn/coturn:latest` references in compose files are replaced with digest-pinned references,
5. `docs/reports/affinescript-smoke-2026-05-07.md` exists with one of three documented verdicts,
6. `docs/architecture/THREAT-MODEL.adoc` contains zero `{{` substrings.

The order of operations mirrors dependency: prerequisites verification (§2) → workstreams (§3–§8) running in parallel where possible → exit-criteria evaluation (§11). The CI green run (§3) is the integrative test: every other workstream's deliverable must continue to land cleanly through CI.

This plan is dispatch-ready. Each task is tagged with a Marr level. Workstreams are sized so that a Sonnet or Haiku subagent can execute them without further clarification from a planner.

---

## 2. Prerequisites & verification

These tasks confirm the starting state. They are all read-only and must be run before any Phase 0 work begins.

### 2.1 Confirm submodule state `[I]`
The `.gitmodules` file declares two submodules: `tools/affinescript` and `tools/nextgen-databases`. As of 2026-05-07 the working tree contains only the latter as a populated checkout; `tools/affinescript` is an empty directory (commit pin `c15855e8…` per `git submodule status`, but no files extracted on disk).

- Run `git -C /home/joshua/Documents/repos/burble submodule status` and assert exit 0 with two lines.
- If `ls tools/affinescript` is empty, run `git submodule update --init --recursive tools/affinescript`. (This is one of the few "state-changing" actions Phase 0 explicitly permits, because the submodule contents are required for §7.)
- Document submodule pinned commits in the Phase 0 sign-off note.

### 2.2 Confirm host toolchain `[I]`
Run `just doctor` and capture output. Expected `[OK]` for `just`, `git`, `zig`. Phase 0 additionally requires:
- `mix` / `elixir` 1.17 + OTP 27 (per CI workflow),
- `idris2` (current version on PATH),
- `podman` (for §6 — note that `podman-compose` is Python and is **banned** by hyperpolymath language policy; selur-compose is the canonical replacement, but until it ships, compose-file validation uses Rust tooling only),
- `taplo` (Rust TOML toolkit, install via `cargo install taplo-cli`) for compose-file validation.

Document any missing tool. Do *not* attempt heal/install in Phase 0 — surface as a blocker for the §5 docs workstream.

### 2.3 Read the source-of-truth files `[C]`
Before dispatching subagents, the orchestrator must skim:
- `Justfile` (recipes that already exist; do not duplicate),
- `.github/workflows/elixir-ci.yml`, `quality.yml`, `affinescript-canary.yml`,
- `scripts/ensure-msquic-version.sh`, `scripts/ensure-quicer-prereqs.sh`,
- `containers/compose.toml`, `containers/selur-compose.toml`,
- `docs/architecture/THREAT-MODEL.adoc`,
- `EXPLAINME.adoc`, `docs/architecture/ARCHITECTURE.adoc`, and any Trustfile-equivalents.

### 2.4 Establish baseline CI failure mode `[A]`
The most recent ten runs of `Elixir CI` on `main` are all `failure` per `gh run list`. The shortest failed run was ~3m55s, suggesting the failure is in `mix deps.get` or `mix compile`, not in tests. A subagent must:
- Run `gh -R hyperpolymath/burble run view <run-id> --log-failed` and extract the actual failure text,
- Diagnose: is it (a) `quicer`/`msquic` build failure on a vanilla runner without prereqs, (b) a `mix compile --warnings-as-errors` regression, or (c) a missing system package?
- Document the diagnosis as input to §3.

---

## 3. Workstream 0.1 — CI green run

**Goal:** `.github/workflows/elixir-ci.yml` passes consistently on every PR, completing in under 15 minutes.
**Tier:** Sonnet (mostly `[A]`; a few `[I]` patches).
**Definition of done:** Five consecutive PRs land with a green `Elixir CI` workflow run.

### 3.1 Diagnose the current red runs `[A]`
Inputs: §2.4 diagnosis. Output: a written cause-and-effect chain (e.g. "the Compile step fails because `quicer` requires `cmake` and `perl` which the GitHub-hosted ubuntu-latest image does not pre-install for the `setup-beam` action's working directory" — the actual cause may differ; this is illustrative).

### 3.2 Add system-prerequisite installation steps `[I]`
Edit `.github/workflows/elixir-ci.yml`. Between the "Set up Beam" step and "Install dependencies" step, add a step that installs the minimum apt packages identified in §3.1. Likely candidates based on `ensure-quicer-prereqs.sh`:
```
- name: Install system prerequisites for quicer/msquic
  run: |
    sudo apt-get update
    sudo apt-get install -y cmake perl build-essential
```
The exact package list must be derived from the actual diagnosis, not assumed.

### 3.3 Wire the existing guard scripts into CI `[I]`
The Justfile already invokes `./scripts/ensure-msquic-version.sh` and `./scripts/ensure-quicer-prereqs.sh` from `test-server`, but the CI workflow runs `mix test --cover` directly (not `just test-server`). Either:
- (a) Change the workflow to call `just test-server` (requires installing `just` in the workflow first, via `taiki-e/install-action@v2` or equivalent), OR
- (b) Add explicit `run: bash scripts/ensure-quicer-prereqs.sh` and `run: bash scripts/ensure-msquic-version.sh` steps before `mix deps.get`.

Recommend (a) — it keeps the Justfile as the single source of truth for "how to test". The subagent must SHA-pin any new action.

### 3.4 Pin `actions/cache` keys to include the new prerequisites `[I]`
The current cache key is `${{ runner.os }}-mix-${{ hashFiles('server/mix.lock') }}`. If the system-package install becomes a determining factor in build success, append a stable salt (e.g. `-msquic-v2.3.8`) so cache invalidation is correct when prerequisite versions bump.

### 3.5 Verify the Zig FFI is built before Elixir tests `[A]`
The Justfile's `test` target calls `test-server test-ffi` — these are *sequential*, but the Elixir tests under `server/test/burble/coprocessor/` likely require the compiled NIF at `server/priv/libburble_coprocessor.so`. Confirm whether `mix test --no-start` triggers compilation of the FFI; if not, add a `just build-ffi` step to CI before `mix test`.

The CI workflow does NOT currently build the Zig FFI. This is almost certainly a contributor to the red runs. Adding:
```
- name: Set up Zig 0.13
  uses: mlugg/setup-zig@v1
  with:
    version: '0.13'
- name: Build Zig FFI
  working-directory: ${{ github.workspace }}
  run: just build-ffi
```
is likely necessary. Subagent must verify by running `cd server && mix test --no-start` locally without `priv/libburble_coprocessor.so` present and observing whether tests fail.

### 3.6 Reduce CI runtime `[I]`
The last successful-shape run took 1h11m. CI must complete in <15 minutes. Likely culprits:
- Dialyzer with cold PLT (one-time cost; cache should fix),
- `mix test --cover` with no parallelism (Elixir test isolation can be slow when bridges spawn many processes).

Mitigations: add `mix test --max-cases=4` if test parallelism is causing flake; ensure PLT cache is restoring (check the cache hit rate in workflow logs).

### 3.7 Open a CI-fix PR and confirm green `[I]`
Push the workflow changes on a `ci/phase-0-green` branch. Iterate (push → observe → fix) until five consecutive runs are green. Do NOT merge until five greens.

### 3.8 Add a "five greens" gate to the Phase 0 sign-off `[C]`
Document in the Phase 0 exit report that "no merge into `main` between 2026-05-08 and Phase 0 sign-off broke CI." Five consecutive greens is the contract.

---

## 4. Workstream 0.2 — `just build-proofs` recipe

**Goal:** A Justfile recipe that compiles every Idris2 ABI module and fails loudly on type errors.
**Tier:** Haiku (`[I]` mostly; one `[A]` decision about module path conflicts).
**Definition of done:** `just build-proofs` exits 0 on a fresh checkout with `idris2` on PATH and the recipe is invoked from CI.

### 4.1 Resolve the duplicate-module-name conflict `[A]`
Two files declare `module Burble.ABI.Types`:
- `src/Burble/ABI/Types.idr` (line 16),
- `src/interface/abi/Types.idr` (line 15).

This is an Idris2 module-naming collision. The recipe must either:
- (a) Build only one of these directories (the canonical one), OR
- (b) Use two separate `.ipkg` files with disjoint `sourcedir` settings.

Recommendation: option (b). Author two ipkg files — `src/Burble/ABI/burble-abi.ipkg` and `src/interface/abi/burble-interface-abi.ipkg` — each with its own `sourcedir` and `modules` listing. The subagent must inspect both `Types.idr` files to determine which is canonical (likely `src/Burble/ABI/` based on the scoping doc's `MediaPipeline.idr:65` reference), and ensure the unused one is either removed in a later phase or renamed.

For Phase 0, the simplest path: build only `src/Burble/ABI/`, document that `src/interface/abi/` is "alternate-tree, deferred to Phase 1 module-path cleanup."

### 4.2 Author the ipkg file `[I]`
Create `src/Burble/ABI/burble-abi.ipkg` (this is permitted even under "no edits" rule because the plan dispatches the task; the subagent executing it has write access). Contents skeleton (subagent must verify against actual imports):
```
package burble-abi
sourcedir = "."
modules = Burble.ABI.Types
        , Burble.ABI.Foreign
        , Burble.ABI.Avow
        , Burble.ABI.Vext
        , Burble.ABI.Permissions
        , Burble.ABI.MediaPipeline
        , Burble.ABI.WebRTCSignaling
```

Note that `Burble.ABI.Types` imports `Data.Fin`, `Data.Vect`; these are stdlib and need no `depends`. If any module imports `contrib`, add `depends = contrib`.

### 4.3 Add the Justfile recipe `[I]`
Append to `Justfile` after `build-server`:
```
# Build Idris2 ABI proofs (Burble.ABI.*)
build-proofs:
    cd src/Burble/ABI && idris2 --build burble-abi.ipkg
```

### 4.4 Smoke-test the recipe `[I]`
Subagent must run `just build-proofs` locally. Expected: exit 0. If `MediaPipeline.idr` has the `postulate resampleFrame` referenced in the scoping doc, it should still compile (postulates compile cleanly; they only affect proof totality).

### 4.5 Wire the recipe into CI `[I]`
Add a job to `.github/workflows/quality.yml` (NOT to `elixir-ci.yml`, to keep concerns separated):
```
proofs:
  name: Idris2 ABI proofs
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@<sha-pinned>
    - name: Install Idris2
      run: |
        # Use the official idris2 install or apt package, pinned to a version
    - run: just build-proofs
```
Subagent must research the canonical Idris2 install action (there is no widely-trusted one; likely a manual `curl` install of a specific release tarball, SHA-verified).

### 4.6 Document the postulate `[I]`
Append to `BURBLE-PROOF-STATUS.md` (already exists at the repo root) a section "Phase 0 build-proofs status" listing: which modules compile, that `resampleFrame` remains a postulate (deferred to Phase 3), and that `prim__registerCallback` is unsafe pending idris2#3182.

---

## 5. Workstream 0.3 — quicer/msquic prerequisite documentation

**Goal:** A fresh contributor can clone the repo on Debian/Fedora/Wolfi, follow the documented install steps, and run `just test` without mysterious build failures.
**Tier:** Haiku (`[I]` for the package-list discovery; `[A]` for cross-distro mapping).
**Definition of done:** `CONTRIBUTING.md` and `README.adoc` each contain a "Building from source" section with copy-pasteable install commands for at least Debian 12 and Fedora 40. A fresh CI runner (verified via §3) confirms the package list is sufficient.

### 5.1 Audit the current guard scripts `[I]`
Read `scripts/ensure-msquic-version.sh` and `scripts/ensure-quicer-prereqs.sh` in full. Extract the explicit prerequisite list:
- `perl` (with `FindBin.pm` core module),
- `cmake`,
- either `make` or `ninja`.

The msquic build also needs OpenSSL headers (msquic links against OpenSSL by default; confirm by reading `server/deps/quicer/msquic/CMakeLists.txt` once submodule is initialized — but this is a deep dependency and may need an actual build attempt to discover).

### 5.2 Map prerequisites to distro packages `[A]`
Produce the mapping:

| Prerequisite | Debian 12 / Ubuntu 24.04 | Fedora 40 | Wolfi |
|---|---|---|---|
| Perl + FindBin | `perl` (core) | `perl-FindBin` | `perl` |
| CMake | `cmake` | `cmake` | `cmake` |
| Make | `build-essential` | `make` + `gcc` | `build-base` |
| OpenSSL headers | `libssl-dev` | `openssl-devel` | `openssl-dev` |
| Erlang/OTP 27 | via `setup-beam` or `kerl` | same | same |

The Wolfi column is included because the scoping doc references `containers/Containerfile.server` which may use a Chainguard/Wolfi base. Subagent must verify by reading the Containerfile.

### 5.3 Update `CONTRIBUTING.md` `[I]`
Add a section "Building from source — system prerequisites" with:
- Three copy-pasteable code blocks (one per distro),
- A pointer to `scripts/ensure-quicer-prereqs.sh` ("this script will validate your environment; if it fails, you are missing one of the packages above"),
- A note that the Justfile recipes `guard-msquic` and `guard-quicer-prereqs` exist for fast diagnostics.

### 5.4 Update `README.adoc` quickstart pointer `[I]`
Add a single sentence in the "Getting started" / "Installation" section pointing to `CONTRIBUTING.md` for the prerequisite list. Do NOT duplicate the package list in the README — single source of truth.

### 5.5 Verify by simulating a fresh contributor `[A]`
Subagent runs the install commands inside a Debian 12 Podman container (`podman run --rm -it debian:12 bash`) and attempts `git clone … && cd burble && just test-server`. Document the exact failure mode (or success). Iterate the package list until the install commands suffice.

This task is `[A]` not `[I]` because the test of "documentation is sufficient" is a judgment call about completeness.

### 5.6 Cross-link from Justfile `doctor` recipe `[I]`
The `just doctor` recipe currently does not check for `cmake`, `perl`, or `make`. Extend it:
```
check "cmake" cmake "3.20"
check "perl"  perl  "5.30"
check "make"  make  "4.0"
```
This makes `just doctor` a useful diagnostic gate before a contributor wastes time on `mix deps.get`.

---

## 6. Workstream 0.4 — coturn image pinning

**Goal:** Both compose files reference `coturn/coturn` by digest, satisfying the trustfile/Stapeln supply-chain policy.
**Tier:** Haiku (pure `[I]`).
**Definition of done:** Neither `containers/compose.toml` nor `containers/selur-compose.toml` contains the literal string `coturn/coturn:latest`; both contain `coturn/coturn@sha256:<digest>` with the same digest.

### 6.1 Resolve a pinned digest `[I]`
Run:
```
podman pull coturn/coturn:latest
podman inspect coturn/coturn:latest --format '{{.Digest}}'
```
Capture the resulting `sha256:...` string. Record the corresponding human-readable tag (e.g. `4.6.2-r10`) in a comment for future audit.

### 6.2 Choose digest source-of-truth `[A]`
Two options:
- (a) Pin to whatever `:latest` resolves to today.
- (b) Pin to a specific named tag (e.g. `coturn/coturn:4.6.2`) and resolve *that* tag's digest, on the principle that `:latest` is unstable and shouldn't be the source of pin choices.

Recommend (b). Rationale: trustfile policy says "pinned to digest"; if anyone later needs to upgrade, they bump the tag, re-resolve the digest, and the audit trail is human-readable. With (a), the pin is a string of hex with no semver context.

### 6.3 Update both compose files `[I]`
Edit `containers/compose.toml` line 51 from `image = "coturn/coturn:latest"` to `image = "coturn/coturn:<TAG>@sha256:<DIGEST>"` (Podman accepts the `tag@digest` form, which preserves human-readability).

Repeat for `containers/selur-compose.toml` line 92.

### 6.4 Verify TOML parseability `[I]`
Run:
```
taplo check containers/compose.toml
taplo check containers/selur-compose.toml
```
Both must exit 0. (`taplo` is the org's sanctioned TOML toolchain; install with `cargo install taplo-cli` if absent. Per hyperpolymath language policy, do **not** substitute a Python `tomllib` one-liner.)

### 6.5 Verify the digest pulls cleanly `[I]`
Run:
```
podman pull coturn/coturn:<TAG>@sha256:<DIGEST>
```
Expected: succeeds; no "manifest not found" errors. Tear down with `podman rmi coturn/coturn@sha256:<DIGEST>`. (Direct `podman pull` is used here rather than a compose-tool wrapper, since the latter — `podman-compose` — is Python and is **banned** by hyperpolymath language policy. The full compose-stack pull will be exercised once `selur-compose` ships.)

### 6.6 Document the pinning policy `[I]`
Add a comment in both compose files immediately above the `[services.coturn]` block:
```
# coturn pinned to <TAG> @ <DIGEST> on <DATE>.
# To upgrade: bump the tag, re-resolve the digest with
#   podman pull coturn/coturn:<NEW_TAG> && podman inspect ... --format '{{.Digest}}'
# and update both compose.toml and selur-compose.toml in the same commit.
```

---

## 7. Workstream 0.5 — AffineScript compiler smoke test

**Goal:** Produce a written report of whether the `tools/affinescript` submodule's compiler can compile `client/web/src/Main.affine`. **DO NOT FIX** the compiler if it is broken — only report.
**Tier:** Haiku (`[I]` for the build attempt; `[A]` for verdict-writing).
**Definition of done:** `docs/reports/affinescript-smoke-2026-05-07.md` exists and matches one of three verdicts:
1. "Compiles cleanly" — compiler produced JS/output, no warnings.
2. "Compiles with warnings: <list>" — compiler succeeded but emitted diagnostics.
3. "Fails to compile: <error log>" — compiler returned non-zero; full stderr captured.

### 7.1 Initialize the affinescript submodule `[I]`
Per §2.1, `tools/affinescript` is empty. Run:
```
git submodule update --init --recursive tools/affinescript
```
Confirm `ls tools/affinescript` shows files. The pinned commit is `c15855e8…` per `git submodule status`.

### 7.2 Identify the compiler invocation `[A]`
The `affinescript-canary.yml` workflow already documents the compilation command: `affinescript check <file>`. Inspect `tools/affinescript/` for a binary build instruction (`README`, `dune-project`, `dune` files). Likely steps to build:
```
cd tools/affinescript
opam install --yes . --deps-only
opam exec -- dune build bin/main.exe
ls _build/default/bin/main.exe
```

If `opam` is not available locally, the subagent must install it (this is a one-time prerequisite, mirror of what the canary CI does). On Debian 12: `apt-get install opam && opam init -y --disable-sandboxing && opam switch create 5.1.0`.

If the build itself fails, that IS the verdict (verdict 3, "fails to compile" — but at the *compiler* level, not the source level). Document the compiler-build failure in a separate `## Compiler build status` section of the report.

### 7.3 Run the smoke test `[I]`
```
./_build/default/bin/main.exe check ../../client/web/src/Main.affine 2>&1 | tee /tmp/affinescript-smoke.log
```
Capture exit code and full stderr+stdout.

### 7.4 Author the report `[A]`
Create `docs/reports/affinescript-smoke-2026-05-07.md`. Required sections:
- **Verdict:** one of the three explicit strings,
- **Environment:** affinescript submodule SHA, OCaml version, OS,
- **Command run:** exact invocation,
- **Output:** captured log,
- **Phase 3 implications:** if verdict 2 or 3, which fix-types are likely needed (compiler bug vs. source-file issue vs. missing standard library) — based on pattern-matching the error against documented affinescript issues.

The report MUST NOT recommend code changes — it is a status snapshot for Phase 3 to consume.

### 7.5 Optionally smoke-test additional `.affine` files `[I]`
After `Main.affine`, also try `client/web/src/Audio.affine`, `Bindings.affine`, `Room.affine`, `Signaling.affine`, `WebRTC.affine` — five canary files total. Same invocation, same logging. The report's "Verdict" applies to `Main.affine` specifically; additional files go in a "Coverage extension" section.

### 7.6 Wire up CI awareness (optional, if time allows) `[I]`
The `affinescript-canary.yml` workflow already exists and is `continue-on-error: true` (advisory). No changes required for Phase 0; just confirm the workflow runs at least once after submodule initialization.

---

## 8. Workstream 0.6 — THREAT-MODEL.adoc template instantiation

**Goal:** Fill all `{{PLACEHOLDER}}` fields with Burble-specific content.
**Tier:** Haiku (`[I]` for replacements; `[C]` for the "System Overview" prose).
**Definition of done:** `grep -c '{{' docs/architecture/THREAT-MODEL.adoc` returns `0`.

### 8.1 Enumerate placeholders `[I]`
Per §2.3 grep, the placeholders are:
- `{{CURRENT_YEAR}}` (line 3)
- `{{AUTHOR}}` (lines 3, 14)
- `{{AUTHOR_EMAIL}}` (line 3)
- `{{PROJECT_NAME}}` (lines 5, 11, 37)
- `{{DATE}}` (line 13)

Six unique placeholders, eight occurrences total.

### 8.2 Resolve replacements `[I]`
- `{{CURRENT_YEAR}}` → `2026`
- `{{AUTHOR}}` → `Jonathan D.A. Jewell` (per `Justfile` SPDX header and `mix.exs`)
- `{{AUTHOR_EMAIL}}` → `j.d.a.jewell@open.ac.uk` (per `Justfile`)
- `{{PROJECT_NAME}}` → `Burble`
- `{{DATE}}` → `2026-05-07` (the Phase 0 sign-off date)

### 8.3 Fill the "System Overview" prose `[C]`
Line 37 currently reads: `Brief description of {{PROJECT_NAME}} and its architecture.` This requires a real paragraph, not a string substitution. Draw from `EXPLAINME.adoc` lines 1–60 and `docs/architecture/ARCHITECTURE.adoc` to write 4–6 sentences covering:
- What Burble is (voice-first communications platform, self-hostable, E2EE-capable),
- The four-topology model (monarchic / oligarchic / distributed / serverless),
- The supervisor tree (Elixir/Phoenix server + Zig SIMD coprocessor NIFs),
- The trust boundaries that matter for STRIDE (the SFU does NOT decode media; the bridges DO transcode for protocol interop).

This task is tagged `[C]` because it is a judgment about what's worth saying; it informs the rest of the threat model's accuracy.

### 8.4 Audit the rest of the threat model for stale claims `[A]`
Several entries in the existing tables reference tools that don't exist in the Burble tree (svalinn, cerro-torre, vordr per scoping doc R6). Per Phase 0 scope, do NOT rewrite the threat model — just instantiate the placeholders. But add a footnote at the end of "Mitigations in Place" section noting:
> Items marked `(optional)` reference tools (svalinn, cerro-torre, vordr) that are referenced in the Burble Trustfile but are not yet installed in this repository as of 2026-05-07. See `docs/superpowers/specs/2026-05-07-burble-full-implementation-scoping.md` §7 R6.

### 8.5 Verify zero placeholders remain `[I]`
Run `grep -F '{{' docs/architecture/THREAT-MODEL.adoc | wc -l`. Must equal `0`. Run `grep -F '}}' docs/architecture/THREAT-MODEL.adoc | wc -l`. Must equal `0`.

---

## 9. Cross-workstream coordination

Dependencies (must-precede):

- §2 prerequisites must complete before any other workstream starts.
- §3 (CI green run) **depends on** §5 (quicer/msquic docs) for the system-package list. The CI workflow's package-install step must match what §5 documents — they are the same list expressed in two artifacts. Best handled as a single subagent doing both, OR coordinated via shared notes.
- §4 (build-proofs) **depends on nothing in Phase 0** but should land *after* §3 starts producing greens, so the new CI job has an established baseline.
- §6 (coturn pin) is fully independent.
- §7 (affinescript smoke) **depends on** §2.1 submodule init.
- §8 (threat model) is fully independent.

Parallel-safe groupings:

- Stream A (sequential): §2 → (§3 + §5 together) → §4.
- Stream B (parallel with A): §6.
- Stream C (parallel with A): §7 (after §2.1 completes).
- Stream D (parallel with A): §8.

If three subagents are dispatched in parallel after §2: one for Stream A, one for Stream B+D combined (small; both Haiku-tier), one for Stream C.

---

## 10. Parallelizable workstreams

| Workstream | Marr level mix | Suggested tier | Dependencies | Estimated wall-clock |
|---|---|---|---|---|
| 0.1 — CI green run (§3) | 1×[A] · 6×[I] · 1×[C] | Sonnet | §2, §5 | 2 days (iterative push/observe loop) |
| 0.2 — `just build-proofs` (§4) | 1×[A] · 5×[I] | Sonnet (because of §4.1 module-conflict judgment) | §2 | 4 hours |
| 0.3 — quicer/msquic docs (§5) | 1×[A] · 1×[A] · 4×[I] | Haiku (Sonnet for §5.5 verification) | §2 | 1 day |
| 0.4 — coturn pin (§6) | 1×[A] · 5×[I] | Haiku | §2 | 1 hour |
| 0.5 — AffineScript smoke (§7) | 1×[A] · 1×[A] · 4×[I] | Haiku | §2.1 | 4 hours |
| 0.6 — Threat model fill (§8) | 1×[C] · 1×[A] · 3×[I] | Haiku (the [C] is small) | §2 | 2 hours |

Total wall-clock if dispatched in parallel: ≈ 2.5 days (gated by §3's iterative CI cycle). Total subagent-hours: ≈ 4 days (Sonnet + Haiku in parallel).

---

## 11. Phase 0 exit criteria

Phase 0 is done when *all* of the following observable tests pass simultaneously:

1. **CI green-run streak.** Five consecutive workflow runs of `Elixir CI` on `main` are `success`. (`gh run list --workflow=elixir-ci.yml --branch=main --limit=5 --json conclusion -q '.[].conclusion'` returns `success` × 5.)

2. **CI runtime budget.** Median of those five runs completes in ≤ 15 minutes. (Same gh query with `--json elapsed`.)

3. **Fresh-clone test.** On a clean Debian 12 Podman container with `git`, `curl`, `apt-get` available, executing `git clone https://github.com/hyperpolymath/burble && cd burble && git submodule update --init --recursive && (apt-get install commands per CONTRIBUTING.md) && just doctor && just test` exits 0. Documented as a reproducible script under `scripts/phase-0-fresh-clone-smoke.sh` (NEW, written during Phase 0).

4. **`just build-proofs` works.** On the same Debian 12 + idris2 environment, `just build-proofs` exits 0.

5. **No coturn `:latest`.** `grep -r 'coturn/coturn:latest' containers/` returns nothing. `grep -r 'coturn/coturn@sha256:' containers/` returns at least two matches (compose.toml and selur-compose.toml).

6. **AffineScript report exists.** `test -f docs/reports/affinescript-smoke-2026-05-07.md` succeeds and the file's first heading line matches `## Verdict: (Compiles cleanly|Compiles with warnings|Fails to compile)`.

7. **Threat model is instantiated.** `grep -F '{{' docs/architecture/THREAT-MODEL.adoc | wc -l` equals `0`.

8. **Justfile `doctor` recipe is honest.** `just doctor` reports the full list of Phase-0-relevant tools (just, git, zig, idris2, cmake, perl, make, podman) and any missing one is `[FAIL]`.

The Phase 0 sign-off note must be authored at `docs/reports/phase-0-signoff-2026-05-XX.md` (date set at completion) and reference each of these eight criteria with evidence.

---

## 12. Risks and contingencies

**R4 (quicer/msquic CI compilation).**
- Detection: §3.1 diagnosis from existing failed run logs.
- Response: §3.2 + §5 install the prerequisites in CI and document them. If CI runners *still* fail after prereq install (e.g. msquic submodule depth issue, OpenSSL version mismatch), escalate to: pin a specific msquic build commit known to work on `ubuntu-24.04` runners; or, as last resort, vendor a prebuilt msquic library into a CI cache.
- If unfixable in Phase 0, contingency: gate quicer-dependent tests behind a `@tag :requires_msquic` tag and skip them in CI with a clear "covered by Phase 1" note.

**R7 (THREAT-MODEL placeholders).**
- Detection: §8.1 grep enumeration.
- Response: §8.2–§8.5. Trivial; only contingency is the §8.3 prose paragraph if the author lacks confidence in writing a Burble system overview. Mitigation: lift sentences verbatim from EXPLAINME.adoc.

**R-Phase0-A — affinescript compiler is missing required runtime.**
- Detection: §7.2 build attempt fails because `opam` or OCaml 5.1 unavailable.
- Response: install `opam` per Debian 12 packages; if the affinescript build still fails (e.g. due to dune version mismatch), document the failure as the *compiler-level* verdict 3 in §7.4. Phase 0 still ships — the smoke-test report is the deliverable, and a "compiler doesn't even build" verdict is itself information.

**R-Phase0-B — Idris2 module path collision blocks `just build-proofs`.**
- Detection: §4.1 design step.
- Response: build only `src/Burble/ABI/`; document `src/interface/abi/` as deferred. If even `src/Burble/ABI/` fails to compile (e.g. an import that requires `contrib`), document the failure in `BURBLE-PROOF-STATUS.md` and ship the recipe with a `|| true` *only if* it allows CI to be informative-but-non-blocking. Prefer hard-fail.

**R-Phase0-C — coturn digest changes between resolution and CI run.**
- Detection: `podman pull` in CI fails with "manifest not found".
- Response: Docker Hub does not garbage-collect arbitrary digests, so this is unlikely. If it occurs, the resolved digest in §6.1 was fraudulent or the wrong registry was used. Re-run §6.1 against `docker.io/coturn/coturn` explicitly.

**R-Phase0-D — Five-greens criterion takes longer than a week.**
- Detection: by end of day 4 of the Phase 0 sprint, fewer than 3 consecutive greens have been observed.
- Response: declare Phase 0 split into "0a (CI green achievable but flaky)" and "0b (five consecutive greens)" — ship 0a deliverables (workstreams 0.2–0.6), keep 0b open as the long-running CI flakiness investigation. Document in the sign-off note. Phase 1 may begin if and only if the most recent CI run is green AND the failure rate is documented as < 20%.

**R-Phase0-E — Submodule init pulls a broken affinescript HEAD.**
- Detection: §7.2 build of the compiler fails *and* the submodule pinned commit is recent (e.g. last week).
- Response: the submodule pin in `.gitmodules` is `c15855e8…`. If that exact commit doesn't build, this is a Phase-0-relevant project-management problem (the pin should be a known-good commit). Update the submodule pin to the most recent commit on `affinescript@main` that has a passing CI run on the affinescript repo itself, and commit the new pin.

**Open ambiguities (planner could not resolve from reading alone):**
- The exact OCaml/dune version required by affinescript submodule HEAD — discovered at §7.2 execution time.
- Whether the `Containerfile.server` uses Wolfi or Debian — affects §5.2 mapping; subagent must read the Containerfile.
- Whether `mix test --no-start` triggers Zig FFI compilation or expects pre-built `.so` — affects §3.5; subagent must verify by experiment.
- Whether the existing `.github/workflows/elixir-ci.yml` failure is rooted in quicer/msquic, or in an unrelated regression (e.g. `mix compile --warnings-as-errors` failing on a recent commit). The shortest red runs being ~4 minutes suggests pre-test failure; longer runs (1h11m) suggest compilation succeeded and tests timed out. Subagent must read both extremes' logs in §2.4.
