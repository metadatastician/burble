<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
# Contributing

Thank you for your interest in contributing! We follow a "Dual-Track" architecture where human-readable documentation lives in the root and machine-readable policies live in `.machine_readable/`.

## How to Contribute

We welcome contributions in many forms:

- **Code:** Improving the core stack or extensions
- **Documentation:** Enhancing docs or AI manifests
- **Testing:** Adding property-based tests or formal proofs
- **Bug reports:** Filing clear, reproducible issues

## Building from source — system prerequisites

`quicer` (the QUIC transport library used by Burble's server) builds `msquic` from
source. This requires several system packages that are **not** pre-installed on a
vanilla developer machine. Install them before running `just test` or `mix deps.get`.

### Debian 12 / Ubuntu 24.04

```bash
sudo apt-get update
sudo apt-get install -y cmake perl build-essential libssl-dev
```

### Fedora 40

```bash
sudo dnf install -y cmake perl-FindBin make gcc openssl-devel
```

### Wolfi (Chainguard — used in `containers/Containerfile.server`)

```bash
apk add --no-cache cmake perl make gcc musl-dev openssl-dev
```

### Cross-distro prerequisite mapping

| Prerequisite | Debian 12 / Ubuntu 24.04 | Fedora 40 | Wolfi |
|---|---|---|---|
| Perl + FindBin | `perl` (core) | `perl-FindBin` | `perl` |
| CMake ≥ 3.20 | `cmake` | `cmake` | `cmake` |
| C compiler + Make | `build-essential` | `make` + `gcc` | `make` + `gcc` + `musl-dev` |
| OpenSSL headers | `libssl-dev` | `openssl-devel` | `openssl-dev` |
| Erlang/OTP 27 | via `setup-beam` / `kerl` | same | same |

### Validating your environment

Run the guard scripts to confirm all prerequisites are present before spending
time on a full `mix deps.get`:

```bash
just guard-quicer-prereqs   # checks perl, cmake, make/ninja
just guard-msquic            # checks msquic is at the required tag (v2.3.8)
```

If either guard fails, it will print which package is missing.
`just doctor` also reports whether `cmake`, `perl`, and `make` are on PATH.

## Getting Started

1. **Read the AI Manifest:** Start with `0-AI-MANIFEST.a2ml` (if present) to understand the repository structure.
2. **Install system prerequisites:** Follow the "Building from source" section above for your distro.
3. **Environment:** Use `nix develop` or `direnv allow` to set up your tools.
4. **Task Runner:** Use `just` to see available commands (`just --list`).

## Development Workflow

### The liveness invariant (ADR-0007)

Every Elixir module under `server/lib/burble/` must be one of:

1. **Supervised** — started by the supervision tree (`application.ex`), or
2. **Invoked** — a library called by supervised code, or
3. **Experimental** — under `server/lib/burble/experimental/` with an
   `EXPERIMENTAL` moduledoc stating what has and has not been validated.

Code that is none of these is dead weight that misleads readers about what
Burble can do — it gets deleted (git history preserves it; see ADR-0009
for the bridge precedent and revival criteria). The same spirit applies
repo-wide: no empty scaffolding directories, no config files describing
stacks this project doesn't use, no generated artifacts nothing consumes.

### Branch Naming

```
docs/short-description       # Documentation
test/what-added              # Test additions
feat/short-description       # New features
fix/issue-number-description # Bug fixes
refactor/what-changed        # Code improvements
security/what-fixed          # Security fixes
```

### Commit Messages

We follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <description>

[optional body]

[optional footer]
```

Types: `feat`, `fix`, `docs`, `test`, `refactor`, `ci`, `chore`, `security`

## Reporting Bugs

Before reporting:
1. Search existing issues
2. Check if it's already fixed in `main`

When reporting, include:
- Clear, descriptive title
- Environment details (OS, versions, toolchain)
- Steps to reproduce
- Expected vs actual behaviour

## Code of Conduct

All contributors are expected to adhere to our [Code of Conduct](CODE_OF_CONDUCT.md).

## License

By contributing, you agree that your contributions will be licensed under the same license as the project (see [LICENSE](LICENSE)).
