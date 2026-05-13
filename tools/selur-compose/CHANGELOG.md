# Changelog

All notable changes to selur-compose are documented in this file.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [Semantic Versioning](https://semver.org/).

---

## [0.1.0] — 2026-05-12

### Added

- **TOML compose parser** (`selur-compose-schema`): full serde struct/enum
  coverage for services, networks, volumes, secrets, configs, and `x-*`
  extension tables. Handles both list and map forms of `depends_on`,
  `environment`, `command`/`entrypoint`, port bindings, and mount specs.
  Round-trips all three real consumer files (`burble/containers/selur-compose.toml`,
  `burble/containers/compose.toml`, `boj-server/selur-compose.toml`) without
  data loss.

- **Variable interpolation** (`selur-compose-interp`): `${VAR}`, `${VAR:-default}`,
  `${VAR:?err}`, and `$$` literal-dollar escape. Discovery rule: `.env` file in
  the same directory as the compose file, then `--env-file` overrides. Bare
  `$args`-style shell variables inside TOML strings are passed through untouched.

- **Plan generation** (`selur-compose-plan`): topological wave decomposition via
  Kahn's algorithm over the `depends_on` DAG. `service_healthy` barriers
  (`WaitHealthy`) deduplicated to prevent double-polling. Cycle detection with a
  typed `PlanError::Cycle`. Per-service SHA-256 config hash stamped into the
  `io.podman.compose.config-hash` label.

- **Podman 5.4 driver** (`selur-compose-driver`): shells out to the `podman`
  CLI binary. Implements build, pull, run, stop, rm, logs, ps, and
  healthcheck-poll operations. `MockDriver` for unit tests; `PodmanCli` for
  production. Wave-level concurrency via `tokio::task::JoinSet`. Build
  concurrency bounded by `min(num_cpus, 8)` semaphore slots.

- **CLI subcommands** (`selur-compose` binary): `up`, `down`, `build`, `pull`,
  `ps`, `logs`, `config`, `version`. Global flags: `-f/--file`, `-p/--project-name`,
  `--env-file`, `--profile`, `-v/--verbose`, `-q/--quiet`, `--format <text|json>`,
  `--dry-run`.

- **`--dry-run` flag**: emits the planned operation list without invoking podman.
  Useful for CI plan-stability assertions.

- **musl static binaries**: `x86_64-unknown-linux-musl` and `aarch64-unknown-linux-musl`,
  distributed via GitHub Releases (cargo-dist tarballs) and `cargo binstall`.

- **Container image skeleton** (`Containerfile`): two-stage Chainguard Wolfi
  builder → static runtime. Intended publication target: `ghcr.io/hyperpolymath/selur-compose`.

- **`did_you_mean` on unknown schema fields**: Levenshtein-distance suggestion
  for misspelled service keys (e.g. `imag` → did you mean `image`?).

- **Profile filtering**: services tagged with `profiles = [...]` are excluded
  unless `--profile <name>` is passed.

- **Healthcheck-gated `depends_on`**: `condition = "service_healthy"` blocks
  subsequent service waves until the dependency's podman healthcheck reports
  `healthy`. Timeout = `start_period + interval × (retries + 1) + 5s slack`.

- **`network_mode = "host"`**: passes through to `podman run --network host`.
  Required for the burble `coturn` service.

- **Restart policies**: `no`, `always`, `on-failure`, `unless-stopped` (kebab-case
  matching burble's compose files verbatim).

- **216 tests** across five crates: unit (parser round-trips, proptest fuzzing,
  interpolation grammar, planner snapshots, argv snapshots, CLI smoke) and
  doc-tests.

### Known limitations

- **Linux rootless only.** macOS (`podman machine`) and Windows are deferred to v0.2.
- **No `exec`, `run`, `restart`, `stop`, `start`, `kill` subcommands.** Deferred to v0.2.
- **No `miette` span-underlining errors.** Plain `thiserror` + `anyhow` chain in v0.1; `miette` deferred to v0.3.
- **A static-base service with a shell-string healthcheck will fail at runtime** (no `/bin/sh` in `cgr.dev/chainguard/static`). Detected only at runtime, not at parse time. Document in `docs/compose-dialect.adoc`.
- **No TOML anchor equivalent.** YAML's `<<: *defaults` has no TOML equivalent. A `[templates]` section with `extends` is a v0.2+ feature.
- **`cargo binstall` requires the GitHub Release to be published first.** The binary is present locally for `cargo install` from source.

---

## [Unreleased]

Nothing yet.

---

[0.1.0]: https://github.com/hyperpolymath/selur-compose/releases/tag/v0.1.0
