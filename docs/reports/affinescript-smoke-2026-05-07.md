# AffineScript Smoke Test Report — 2026-05-07

## Verdict
**Compiler-build-blocked: opam not installed**

## Environment
- AffineScript submodule commit: `c15855e8...` (per `git submodule status`)
- Required build toolchain: OCaml 5.1.0 + dune + opam
- Host system: Debian 12, Linux kernel 6.12.86+deb13
- opam version: **NOT INSTALLED** — build blocked at §7.2

## Compiler Build Status
The affinescript submodule was successfully initialized via `git submodule update --init --recursive tools/affinescript`. The directory contains the full source tree, including:
- `affinescript.opam` (package definition)
- `bin/` directory (compiler sources)
- `dune-project` file (Dune build configuration)

However, the OCaml package manager (`opam`) is not available on the test host. Per Phase 0 guidelines (§7.2 and hard rules), we do **not** install opam system-wide. Instead, this is documented as a blocker.

## Smoke Test Attempt
No compilation attempt was made. The verdict is determined at the build-phase gate (§7.2 gate), not the source-file phase (§7.3).

## Command Attempted
```bash
# Build affinescript compiler
cd tools/affinescript
opam install --yes . --deps-only   # BLOCKED: opam not found
opam exec -- dune build bin/main.exe
```

Exit status: Blocked (opam missing).

## Phase 3 Implications
Resumption of the affinescript compiler test in Phase 3 requires one of:
1. **Local opam install** — Install opam on the test machine (one-time setup), then re-run the smoke test.
2. **CI-native test** — Rely on the existing `affinescript-canary.yml` GitHub Actions workflow (which has opam pre-installed in the runner image) to validate compiler health.

If the compiler itself fails to build even with opam present (e.g., dune version mismatch, missing OCaml 5.1.0), that will be the Phase 3 verdict. Currently, we cannot reach that determination.

## Coverage Extension
Planned canary files for Phase 3 (when compiler is buildable):
- `client/web/src/Main.affine` (primary source)
- `client/web/src/Audio.affine`
- `client/web/src/Bindings.affine`
- `client/web/src/Room.affine`
- `client/web/src/Signaling.affine`
- `client/web/src/WebRTC.affine`

## Notes
- The submodule initialization (§7.1) succeeded cleanly.
- The `affinescript-canary.yml` workflow in `.github/workflows/` is configured with `continue-on-error: true` and may provide indirect evidence of compiler health on each CI run.
- Removal of this blocker is **not a Phase 0 task** (per plan scope); it is deferred to Phase 3 if needed.
