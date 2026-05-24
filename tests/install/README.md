# Install-machinery tests

Validates `setup.sh`, `setup.ps1`, `scripts/install-service.sh`,
`scripts/wsl-bolt-udp-forward.ps1`, and `assets/services/*` without
actually mutating the host. Safe to run anywhere.

## Run locally

```bash
tests/install/run.sh
```

Each check reports `PASS` / `FAIL` / `SKIP`. `SKIP` means the validator
isn't installed (shellcheck, pwsh, systemd-analyze, plutil/xmllint) —
not a failure. Install whichever are missing to widen coverage:

| Validator | Linux | macOS | Windows |
|---|---|---|---|
| `bash -n`, `sed` | always | always | git-bash / WSL |
| `shellcheck` | `apt install shellcheck` | `brew install shellcheck` | git-bash + manual |
| `systemd-analyze` | `apt install systemd` | n/a (no systemd) | n/a |
| `xmllint` | `apt install libxml2-utils` | preinstalled | n/a |
| `plutil` | n/a | preinstalled | n/a |
| `pwsh` | snap/apt | `brew install --cask powershell` | preinstalled |
| `PSScriptAnalyzer` | `pwsh -c 'Install-Module PSScriptAnalyzer'` | same | same |

## CI

`.github/workflows/install-tests.yml` runs three jobs:

- `lint-linux` — `tests/install/run.sh` with all Linux validators
- `lint-macos` — `tests/install/run.sh` on `macos-14` (real `plutil`)
- `lint-windows` — PowerShell AST parse + PSScriptAnalyzer + actually
  compiles the embedded C# service host with the in-box `csc.exe`
  (proves the runtime install path will work)

Triggered on any change to the install machinery.

## What's NOT tested

Real install/start/stop round-trip on a clean host:

- **Linux systemd round-trip** — needs `loginctl enable-linger` + a real
  user session bus in CI for `systemctl --user`, or root for system
  units. Tractable but not wired up yet.
- **Windows `New-Service`** — needs a throwaway local user with `Log on
  as a service` for the `-Credential` argument. Tractable but not wired
  up yet.
- **macOS `launchctl bootstrap`** — would work in CI but requires the
  Mix/Deno toolchains to be present for the spawned process to do
  anything meaningful.

Until those land, the lint suite catches everything we've actually hit
in practice (unsubstituted tokens, `AmbientCapabilities=` in user mode,
malformed PowerShell, missing csc.exe path).
