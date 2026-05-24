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

## Round-trip tests (actually mutate the host)

In addition to the lint suite, there are three platform-specific
drivers that do a real install → activate → stop → uninstall cycle
against the platform's service manager. They use stub `mix` / `deno`
binaries (`tests/install/stubs/`) so the spawned units survive long
enough to be Active without needing the full Elixir/Deno toolchain.

| Driver | Platform | What it round-trips |
|---|---|---|
| `roundtrip-linux.sh` | Linux | `systemctl --user enable --now` round-trip (also kills the main PID and asserts `Restart=on-failure` respawns it) |
| `roundtrip-macos.sh` | macOS | `launchctl bootstrap gui/$UID` / `bootout` |
| `roundtrip-windows.ps1` | Windows | creates throwaway local user, installs Windows Service non-interactively via the new `-Credential` parameter on `wsl-bolt-udp-forward.ps1`, asserts SCM state, uninstalls, removes user |

All three are idempotent and clean up after themselves on failure
(`trap EXIT` / `try { … } finally { … }`). They will mutate your host
for the duration of the test — safe locally if you're OK with a brief
service install.

CI workflow `install-roundtrip.yml` runs them on:
- `ubuntu-latest` (with `loginctl enable-linger` to bring up user-systemd)
- `macos-14` (Apple Silicon)
- `windows-latest`

## What's still NOT tested

- The actual UDP forwarding (the Windows round-trip exercises install
  + SCM state, not whether packets actually relay — that requires a
  real WSL distro target).
- The Elixir/Deno app itself starting up correctly under systemd /
  launchd — covered by `elixir-ci.yml`.
