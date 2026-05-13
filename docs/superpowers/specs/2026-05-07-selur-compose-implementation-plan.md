# selur-compose v0.1.0 — Implementation Plan

**Plan version:** 1, 2026-05-07
**Companion to:** `docs/superpowers/specs/2026-05-07-selur-compose-design.md`

Tasks are tagged `[C]` (Computational, Opus/main), `[A]` (Algorithmic, Sonnet), `[I]` (Implementational, Haiku). Effort: S = <2h, M = 2-8h, L = 8-24h, XL = >24h.

---

## 1. Plan overview

We are building a single-binary TOML-native compose CLI in Rust that drives Podman 5.4.x rootless on Linux. The five-crate workspace (`schema`, `interp`, `plan`, `driver`, binary `selur-compose`) is built bottom-up: the schema crate is exercised first against the three real consumer files (`burble/containers/selur-compose.toml`, `burble/containers/compose.toml`, `boj-server/selur-compose.toml`); interpolation lands next; planning/topology builds on both; the podman driver shells out via `tokio::process`; the binary stitches everything together with clap. The success test for v0.1.0 is: a freshly-installed `selur-compose` binary brings up `boj-server/selur-compose.toml` end-to-end (one healthy container, one network), and produces a snapshot-stable `selur-compose config` and `--dry-run` plan for both burble compose files. Order of operations: prerequisites/scaffold → Phase 1 schema → Phase 2 interpolation → Phase 3 plan → Phase 4 driver → Phase 5 CLI subcommands → Phase 6 release engineering. Phases 3 and 4 can partially overlap once their interfaces are nailed.

---

## 2. Prerequisites & one-time setup

These tasks happen before Phase 1. They establish the GitHub repo, the workspace skeleton, CI, and the conventions that match the rest of hyperpolymath (verisimdb, lithoglyph, affinescript). The standalone repo is `github.com/hyperpolymath/selur-compose`; it gets mounted into burble as a submodule under `tools/selur-compose/` only after v0.1.0 ships (per design §10).

| ID | Task | Marr | Effort | Deps | Files / DoD |
|----|------|------|--------|------|-------------|
| P-1 | Decide initial workspace member versioning policy: lockstep `0.1.0` for all five crates via `[workspace.package].version`. Confirm crate-name reservations on crates.io. | [C] | S | — | Decision recorded in plan/CHANGELOG; `cargo search selur-compose-schema` returns nothing. |
| P-2 | Create `github.com/hyperpolymath/selur-compose` from `rsr-template-repo`. Apply the org-standard files (`0-AI-MANIFEST.a2ml`, `LICENSE` PMPL-1.0-or-later, `CODE_OF_CONDUCT.md`, `CONTRIBUTING.md`, `SECURITY.md`, `EXPLAINME.adoc`, `MAINTAINERS.adoc`). | [I] | S | P-1 | Repo exists, default branch `main`, branch protection on. |
| P-3 | Author workspace `Cargo.toml` declaring members `crates/selur-compose-schema`, `crates/selur-compose-interp`, `crates/selur-compose-plan`, `crates/selur-compose-driver`, `crates/selur-compose`. Set `[workspace.package]` with `version = "0.1.0"`, `edition = "2021"`, `rust-version = "1.78"`, `license = "PMPL-1.0-or-later"`, `repository`, `homepage`. Add `[workspace.dependencies]` block pinning `serde`, `serde_json`, `toml = "0.8"`, `thiserror`, `anyhow`, `tokio`, `clap`, `tracing`, `tracing-subscriber`, `humantime`, `humantime-serde`, `sha2`, `async-trait`, `futures`, `insta`, `proptest`, `rstest`, `assert_cmd`, `predicates`. | [A] | S | P-2 | `cargo metadata` succeeds; resolver `2`. |
| P-4 | Author per-crate `Cargo.toml` stubs (lib crates with empty `lib.rs`, binary crate with empty `main.rs`). Each lib uses `selur_compose_<name>` snake-case lib path; binary `name = "selur-compose"`. | [I] | S | P-3 | `cargo build` on workspace succeeds with empty crates. |
| P-5 | Author `flake.nix` mirroring the verisimdb pattern: rust-overlay pinned toolchain, `podman` + `cargo-nextest` + `cargo-dist` + `just` in dev shell, plus `gnumake`, `pkg-config`, `openssl`. | [A] | S | P-2 | `nix develop` enters a shell with `cargo --version` and `podman --version`. |
| P-6 | Author root `Justfile` with recipes: `build`, `test` (alias `nextest run --workspace`), `test-it` (with `--features podman-it`), `lint` (`cargo clippy --workspace --all-targets -- -D warnings`), `fmt`, `fmt-check`, `snapshot-review` (`cargo insta review`), `audit` (`cargo audit`), `release-dry` (`cargo dist plan`). | [A] | S | P-3 | `just lint` and `just fmt-check` succeed on empty crates. |
| P-7 | Author `rust-toolchain.toml` pinning to a specific stable channel (e.g. `1.78.0`), components `rustfmt`, `clippy`. | [I] | S | — | File present at repo root. |
| P-8 | Author `.github/workflows/ci.yml`: matrix on `ubuntu-24.04` × `{stable, msrv-1.78}`. Steps: checkout, install rust toolchain, install podman 5.4, cache cargo, `just fmt-check`, `just lint`, `cargo nextest run --workspace`, `cargo nextest run --workspace --features podman-it` (gated to push-to-main and PRs touching `crates/selur-compose-driver/**`). Also a separate job: `cargo deny check`, `cargo audit`. | [A] | M | P-6 | Push of empty workspace shows a green CI run. |
| P-9 | Author `.github/workflows/release.yml`: triggers on tag `v*`. Runs `cargo dist build` to produce musl tarballs for `x86_64-unknown-linux-musl` + `aarch64-unknown-linux-musl`, uploads to GitHub Release, and runs `cargo publish` for the five crates in dependency order (schema, interp, plan, driver, binary). | [A] | M | P-3 | `dist-workspace.toml` and `release.yml` present. (Not exercised until P-12.) |
| P-10 | Author `dist-workspace.toml` (cargo-dist v0.x): `installers = ["shell", "powershell"]`, `targets = ["x86_64-unknown-linux-musl", "aarch64-unknown-linux-musl"]`, `pr-run-mode = "plan"`, `cargo-dist-version = "<latest>"`. | [A] | S | P-3 | `cargo dist plan` succeeds. |
| P-11 | Author skeleton `README.adoc` (overview, install via `cargo install selur-compose` and `cargo binstall`, quickstart against `boj-server/selur-compose.toml`) and `CHANGELOG.md` (Keep-a-Changelog, `## [Unreleased]` heading). | [I] | S | P-2 | Files present; CHANGELOG lints under `keepachangelog-cli` if available. |
| P-12 | Configure `crates.io` API token as a GitHub Actions secret `CRATES_IO_TOKEN`. Configure `cosign` placeholder env (used in v0.2+; just a TODO comment for now). | [I] | S | P-9 | Secret visible in repo settings; release.yml references it. |
| P-13 | Decide & document the `.env` discovery order (per design §12.4): "directory containing the compose file, then `--env-file` overrides". Add to `docs/compose-dialect.adoc`. | [C] | S | P-2 | Doc page authored, linked from README. |
| P-14 | Decide & document the `${VAR}` interpolation rule for shell-fragment strings (the coturn `command` quote-soup case): TOML-string-level interpolation runs first; `$args` *inside* a TOML string is interpolated unless escaped with `$$`. Document the escape and add a fixture demonstrating the burble coturn case. | [C] | S | P-2 | Doc + fixture file path reserved. |

**Pre-phase exit criteria for §2:** repo exists, empty workspace builds and lints cleanly in CI, release pipeline is configured but un-fired, conventions are documented.

---

## 3. Phase-by-phase implementation

### Phase 1 — `selur-compose-schema`: parse, round-trip, deny-unknown

**Goal:** parse all three real consumer files lossless and emit precise typed errors on bad input. No I/O outside of `tests/`.

**Entry criteria:** §2 complete; empty workspace builds.

| ID | Task | Marr | Effort | Deps | DoD / Files |
|----|------|------|--------|------|-------------|
| 1.1 | Copy the three real consumer files into `crates/selur-compose-schema/tests/fixtures/valid/{burble-selur.toml, burble-legacy.toml, boj-server.toml}` to use as ground truth. | [I] | S | P-4 | Three fixture files present; bytes match originals. |
| 1.2 | Author `crates/selur-compose-schema/src/lib.rs` with `Compose`, `Project`, top-level deserialize impl, the `extensions` flatten capture for `x-*`. Re-exports for downstream crates. | [A] | M | 1.1 | `Compose` parses all three fixtures; `[x-svalinn]` survives as a `toml::Value` in `extensions`. |
| 1.3 | Author `crates/selur-compose-schema/src/services.rs` with `Service`, `RestartPolicy` (default `No`, kebab-case), `EnvMap` (untagged `List|Map`), `StringOrList`. `#[serde(deny_unknown_fields)]` on `Service`. | [A] | M | 1.2 | All burble services round-trip; intentionally-bad fixture `unknown_service_field.toml` produces `ParseError::UnknownField`. |
| 1.4 | Author `crates/selur-compose-schema/src/build.rs` (`Build` struct: context, dockerfile, args, target, labels, no_cache). Accept both inline-table and full-table forms. | [A] | S | 1.3 | The verisimdb `build = { context = ..., dockerfile = ..., args = { FEATURES = "persistent" } }` line round-trips. |
| 1.5 | Author `crates/selur-compose-schema/src/depends_on.rs` with `DependsOn` (untagged enum: `Empty`, `List(Vec<String>)`, `Map(BTreeMap<String, DependsOnSpec>)`), `DependsOnSpec`, `DependsCondition` (snake_case). | [A] | M | 1.3 | Both forms in burble's compose round-trip; cycle through `serde_json::to_value`-and-back is identity. Snapshot tests `depends_on_list.snap` and `depends_on_map_with_condition.snap`. |
| 1.6 | Author `crates/selur-compose-schema/src/networks.rs` (`Network`, `NetworkMode` lowercase, `bridge|host|none|container:<name>|<custom>`). | [A] | M | 1.3 | `network_mode = "host"` round-trips; `container:foo` parses to `Container("foo")`. |
| 1.7 | Author `crates/selur-compose-schema/src/volumes.rs` (`Volume` definition + `MountSpec` parser handling string short-forms `"name:/path"`, `"./host:/ctr:ro"`, `"/abs:/abs"`, plus full-struct form). | [A] | M | 1.3 | All burble volume entries round-trip; `:ro` is captured as a flag, not a path suffix. |
| 1.8 | Author `crates/selur-compose-schema/src/ports.rs` (`PortBinding` parsing `"4020:80"`, `"4020:80/tcp"`, `"127.0.0.1:4020:80"`, `"4020-4030:80-90"` ranges, plus struct form). | [A] | M | 1.3 | Burble web's `"4020:80"` round-trips. Range form covered in unit test. |
| 1.9 | Author `crates/selur-compose-schema/src/healthcheck.rs` (`Healthcheck`, `HealthcheckTest` untagged shell-string vs exec-list, `DurationStr` newtype using `humantime-serde`). | [A] | M | 1.3 | Burble's `"wget -q --spider … || exit 1"` parses to `Shell(...)`; `["CMD", "wget"]` parses to `Exec(...)`; `interval = "30s"` parses to `Duration(30s)`. |
| 1.10 | Author `crates/selur-compose-schema/src/secrets.rs` and `configs.rs` (`Secret`, `Config`, `SecretRef`, `ConfigRef`). | [A] | S | 1.3 | Top-level `[secrets.foo] file = "..."` round-trips. Service-level `secrets = ["foo"]` and `secrets = [{source="foo", target="/bar"}]` both parse. |
| 1.11 | Author `crates/selur-compose-schema/src/error.rs` with the `ParseError` enum from design §8, plus a `parse_str(s: &str, source_path: Option<&Path>) -> Result<Compose, ParseError>` entry point that wraps `toml::from_str`. | [A] | S | 1.2 | Bad-TOML fixture produces `ParseError::Toml { file, source }`. |
| 1.12 | Add `did_you_mean` suggestion logic on `UnknownField` errors using a Levenshtein crate (`strsim`) over the known field set per type. | [A] | S | 1.11 | `unknown_service_field.toml` with `imag = "..."` suggests `image`. |
| 1.13 | Author the round-trip property test in `crates/selur-compose-schema/tests/round_trip.rs`: parse → serialize-to-toml → parse → serde-json compare equality, over the valid fixture corpus. | [A] | M | 1.2-1.10 | All three real fixtures pass; CI green. |
| 1.14 | Author the `proptest` strategies in `crates/selur-compose-schema/tests/fuzz.rs`: a `Compose`-shaped generator that round-trips through TOML. Run for 256 cases in CI; 10000 in nightly. | [A] | L | 1.13 | `cargo nextest run -p selur-compose-schema fuzz` green for 256 cases. |
| 1.15 | Author insta snapshot tests in `crates/selur-compose-schema/tests/parse_snapshots.rs` for each fixture, snapshotting the pretty-printed `Debug` of the parsed `Compose`. | [I] | S | 1.13 | Snapshots committed under `crates/selur-compose-schema/tests/snapshots/`. |
| 1.16 | Author intentionally-bad fixtures under `tests/fixtures/invalid/` and matching tests asserting specific `ParseError` variants: `missing_image_or_build.toml`, `unknown_field.toml`, `bad_duration.toml`, `cycle_in_depends_on.toml` (parser accepts; cycle is a planner concern), `bad_port.toml`. | [A] | M | 1.11-1.12 | Each test passes. |

**Phase 1 exit criteria:**
- `cargo nextest run -p selur-compose-schema` green.
- All three real consumer files in `tests/fixtures/valid/` parse and round-trip without diff.
- Public API of `selur-compose-schema` is documented with `#![deny(missing_docs)]` on at least pub structs/enums.

---

### Phase 2 — `selur-compose-interp`: env interpolation

**Goal:** resolve `${VAR}`, `${VAR:-default}`, `${VAR:?err}`, `$$` escape, on every string-typed field of a parsed `Compose`. Pure function over `(Compose, EnvMap)`.

**Entry criteria:** Phase 1 exit.

| ID | Task | Marr | Effort | Deps | DoD / Files |
|----|------|------|--------|------|-------------|
| 2.1 | Author the BNF/grammar for the interpolator and document it in `crates/selur-compose-interp/src/grammar.md`. Cover: `${name}`, `${name:-default}`, `${name-default}`, `${name:?err}`, `${name?err}`, `$$` literal, bare `$` outside `${...}` policy. | [C] | S | 1.* | Grammar doc committed; matches docker-compose semantics. |
| 2.2 | Author `crates/selur-compose-interp/src/lexer.rs` and `src/expander.rs` implementing the grammar over `&str` to `String`, returning typed errors (`InterpError::MissingRequired { name, msg, span }`). | [A] | M | 2.1 | Hand-written table-driven tests cover all grammar cases; no panics on malformed input. |
| 2.3 | Author `crates/selur-compose-interp/src/env.rs`: `EnvMap` type (ordered: `--env-file` files in order, then process env, then explicit overrides), `load_env_file(path) -> Result<Vec<(String, String)>, InterpError>` parsing dotenv format (KEY=VAL, # comments, "quoted strings"). | [A] | M | 2.2 | `.env` parser handles burble-style env files. Order semantics documented. |
| 2.4 | Author `crates/selur-compose-interp/src/visit.rs`: a `Compose` visitor that calls the expander on every `String` field reachable through the schema. Uses `serde_json::Value`-mediated round-trip OR a hand-rolled walker — pick the latter for performance and span fidelity. | [A] | L | 2.2, 1.* | Re-parsing burble's selur-compose.toml with `TURN_REALM=example.com` set produces `"turn:example.com:3478"` in the right place; coturn's `command` shell-soup is left intact (no shell expansion attempted). |
| 2.5 | Cross-check the coturn `$args` case: confirm the interpolator does *not* attack `$args` because we treat shell variables as `${args}` only — bare `$args` is left alone. Add fixture `tests/fixtures/coturn_shell_passthrough.toml`. | [C] | S | 2.4 | Test asserts `"$args"` is preserved verbatim through interpolation. |
| 2.6 | Author the public entry point `interpolate(compose: Compose, env: &EnvMap) -> Result<Compose, InterpError>` in `crates/selur-compose-interp/src/lib.rs`. | [A] | S | 2.4 | Integration test: parse + interpolate burble selur-compose with default env yields a `Compose` whose `TURN_REALM=burble.local`. |
| 2.7 | Author insta snapshots `crates/selur-compose-interp/tests/snapshots/`: `(parse + interpolate)` of each consumer file with a controlled env map. | [I] | S | 2.6 | Snapshots committed; reviewer can scan for unintended substitutions. |

**Phase 2 exit criteria:** `cargo nextest run -p selur-compose-interp` green; round-trip with empty env is identity for already-literal fields.

---

### Phase 3 — `selur-compose-plan`: DAG, profiles, hashing

**Goal:** turn an interpolated `Compose` into a partially-ordered DAG of `Op`s with a stable per-service config hash. No podman calls.

**Entry criteria:** Phase 1 exit. (Can start in parallel with Phase 2 once `Compose` is stable; must wait for Phase 2 for real-world testing.)

| ID | Task | Marr | Effort | Deps | DoD / Files |
|----|------|------|--------|------|-------------|
| 3.1 | Define `Op` enum in `crates/selur-compose-plan/src/lib.rs`: `CreateNetwork`, `CreateVolume`, `BuildImage`, `PullImage`, `RunContainer`, `WaitHealthy`, `StopContainer`, `RemoveContainer`. Each carries a typed spec struct (e.g. `RunSpec`). Stable `Debug` for snapshotting. | [A] | M | 1.* | Type compiles; specs include exactly the fields the driver will need. |
| 3.2 | Author `crates/selur-compose-plan/src/dag.rs`: typed graph using `petgraph::graphmap::DiGraphMap<NodeId, EdgeKind>`. `EdgeKind = StartedBefore | HealthyBefore | CompletedBefore`. | [A] | M | 3.1 | Unit tests over hand-built graphs. |
| 3.3 | Author Kahn's-algorithm topological wave generation: returns `Vec<Vec<NodeId>>` (one inner vec per wave). Detects cycles, returns `PlanError::Cycle { path: Vec<String> }`. | [A] | M | 3.2 | Cycle fixture `tests/fixtures/cycle.toml` triggers `Cycle`; "diamond" depends_on with `service_healthy` on both sides produces a single deduplicated `WaitHealthy(X)` barrier (design §12.5). |
| 3.4 | Author `crates/selur-compose-plan/src/profiles.rs`: filters services by enabled profiles. A service with no `profiles` is always included; one with `profiles = ["dev"]` only when `--profile dev` is passed. | [A] | S | 3.1 | Table-driven test covers inclusion/exclusion. |
| 3.5 | Author `crates/selur-compose-plan/src/hash.rs`: deterministic SHA-256 over a canonical serialization of each `Service` (sorted keys, normalized strings). Hash is stamped into `RunSpec.labels["io.podman.compose.config-hash"]`. | [A] | M | 3.1 | Hashing twice yields identical bytes; a one-character change to `image` changes the hash. |
| 3.6 | Author `crates/selur-compose-plan/src/lib.rs::plan(compose: &Compose, opts: PlanOptions) -> Result<Plan, PlanError>` that orchestrates 3.2-3.5. | [A] | M | 3.2-3.5 | Public API stable; `Plan { ops_in_topo_order: Vec<Op>, waves: Vec<Vec<NodeId>>, project_name: String }`. |
| 3.7 | Author insta snapshots in `crates/selur-compose-plan/tests/plan_snapshots.rs`: feed each consumer file (parsed + interpolated with controlled env) into `plan()` and snapshot the resulting `Plan`. Hashes redacted via `insta::with_settings!` filter `[a-f0-9]{64}` → `<HASH>`. | [A] | M | 3.6 | Three committed snapshots, reviewable. |
| 3.8 | Define `PlanError` thiserror enum: `Cycle`, `MissingDependency`, `Schema(#[from] schema::ParseError)`, `Interp(#[from] interp::InterpError)`, `UnknownProfile`, `UnknownService`. | [A] | S | 3.1 | Errors compose. |
| 3.9 | Edge-case coverage: a service that names a network not declared at top level should be a planner error (`UnknownNetwork`). Same for volumes referenced by name. Bind mounts (`./conf:/etc`) are not errors. | [A] | M | 3.6 | Fixture-driven tests in place. |
| 3.10 | Document the planner's contract in `crates/selur-compose-plan/src/lib.rs` rustdoc: input invariants, output invariants, hash stability guarantee. | [I] | S | 3.6 | rustdoc renders cleanly. |

**Phase 3 exit criteria:** `cargo nextest run -p selur-compose-plan` green; the three plan snapshots are committed and stable across reruns.

---

### Phase 4 — `selur-compose-driver`: podman shellout

**Goal:** execute a `Plan` by spawning `podman` subprocesses. Provide a `MockDriver` for unit testing; production `PodmanCli` for integration.

**Entry criteria:** Phase 3 `Op` types stable. (Can start once 3.1 is done; doesn't need 3.7.)

| ID | Task | Marr | Effort | Deps | DoD / Files |
|----|------|------|--------|------|-------------|
| 4.1 | Author `crates/selur-compose-driver/src/lib.rs` with the `Driver` async trait from design §5, the `DriverError` thiserror enum, and the typed spec re-exports (`BuildSpec`, `RunSpec`, etc. — defined in `plan` and re-exported here for consumers). | [A] | M | 3.1 | Trait compiles; trait-object-safe via `async_trait`. |
| 4.2 | Author `crates/selur-compose-driver/src/argv.rs`: pure functions `build_argv(spec: &BuildSpec) -> Vec<String>`, `run_argv(spec: &RunSpec) -> Vec<String>`, etc. No I/O. Easy to snapshot-test. | [A] | L | 4.1 | Snapshot tests in `tests/argv_snapshots.rs` covering: each burble service produces a stable `podman run …` argv. |
| 4.3 | Author `crates/selur-compose-driver/src/exec.rs`: `async fn run_podman(argv: &[String]) -> Result<Output, DriverError>` using `tokio::process::Command`. Captures stdout/stderr; non-zero exit → `DriverError::Podman { argv, code, stderr }`. | [A] | M | 4.1 | Unit-tested with `/bin/echo`-like substitutes. |
| 4.4 | Author `crates/selur-compose-driver/src/podman.rs::PodmanCli`: the production `Driver` impl. Each method composes `argv` then `run_podman`. JSON parsing for `inspect`, `ps`, `network ls`, `volume ls` via small `serde::Deserialize` shims. | [A] | L | 4.2-4.3 | Trait fully implemented; covered by integration tests behind `--features podman-it`. |
| 4.5 | Author `crates/selur-compose-driver/src/healthcheck.rs`: the polling loop from design §5 ("Healthcheck-gated `depends_on`"), with timeout = `start_period + interval × (retries + 1) + 5s slack`. Honors `WaitHealthy(X)` deduplication via a `tokio::sync::OnceCell<HealthState>` keyed by container id. | [A] | M | 4.4 | Integration test with a `cgr.dev/chainguard/static` container running a slow health command. |
| 4.6 | Author `crates/selur-compose-driver/src/mock.rs::MockDriver`: records every call with its argv-equivalent into a `Vec<MockCall>` accessible via a `Mutex`. Configurable canned responses per method. | [A] | M | 4.1 | Used by a `plan-execution`-level unit test in `selur-compose-plan` (no — kept inside the driver crate to avoid back-edges). Tests live in `tests/mock_driver.rs`. |
| 4.7 | Author `crates/selur-compose-driver/src/executor.rs`: `async fn execute(driver: &dyn Driver, plan: &Plan, opts: ExecOpts) -> Result<ExecReport, DriverError>` which walks waves, fires `JoinSet`, applies the build-concurrency `Semaphore` (capacity `min(num_cpus, 8)`), and propagates first-error cancellation. | [A] | L | 4.5, 3.6 | Integration test against `MockDriver` confirms (a) waves run concurrently, (b) wave N+1 doesn't start until wave N finishes, (c) first error cancels in-flight starts. |
| 4.8 | Author `crates/selur-compose-driver/src/logs.rs`: `async fn tail_logs(driver: &dyn Driver, services: &[ServiceName], follow: bool) -> impl Stream<Item = LogLine>`, multiplexing per-service streams through `mpsc` and prefixing with `[<service>] `. | [A] | M | 4.4 | Integration test with two services emitting numbered lines confirms ordered, prefixed merge. |
| 4.9 | Add a `PodmanV5Adapter` shim for output JSON parsing (design §12.2), with a minimal stable `PodmanContainerJson` struct that does *not* re-export podman's full schema. Use `#[serde(default)]` and `#[serde(rename = "...")]` aggressively. | [A] | M | 4.4 | Snapshot a real `podman ps --format json` output and parse it lossless. |
| 4.10 | Detect the EACCES "rootless port < 1024" error pattern in stderr and produce `DriverError::PrivilegedPort { service, port }` with a hint about `sysctl net.ipv4.ip_unprivileged_port_start` (design §12.3). | [A] | S | 4.4 | Targeted unit test using a fake stderr string. |

**Phase 4 exit criteria:**
- `cargo nextest run -p selur-compose-driver` green.
- `cargo nextest run -p selur-compose-driver --features podman-it` green on a runner with podman 5.4 installed.
- A toy one-service plan (`cgr.dev/chainguard/static` with `sleep 3600`) runs and tears down clean.

---

### Phase 5 — `selur-compose` binary: CLI subcommands

**Goal:** wire the four libraries into a clap-derive binary with the eight v0.1.0 subcommands.

**Entry criteria:** Phases 1-4 exit. (Subcommand work parallelizes across `up`, `down`, `build`, `pull`, `ps`, `logs`, `config`, `version`.)

| ID | Task | Marr | Effort | Deps | DoD / Files |
|----|------|------|--------|------|-------------|
| 5.1 | Author `crates/selur-compose/src/main.rs` and `src/cli.rs` defining the clap-derive `Cli`, `Command`, global flags from design §6. `--format <text\|json>` is global. | [A] | M | 4.* | `selur-compose --help` lists all eight subcommands with documented flags. |
| 5.2 | Author `crates/selur-compose/src/load.rs`: shared loader that finds the compose file (default `selur-compose.toml`, fallback `compose.toml`), discovers `.env` (rule from P-13), parses, interpolates, plans, and returns `(Plan, Compose)`. Used by every subcommand. | [A] | M | 5.1, 2.6, 3.6 | Unit-tested with fixture trees. |
| 5.3 | `cmd/up.rs`: builds a plan, executes it via `executor::execute`. Honors `-d/--detach`, `--build`, `--no-build`, `--no-pull`, `--force-recreate`, `--remove-orphans`, `[SERVICE…]` (filter the plan). Emits a final summary table (service, container id, status, ports). | [A] | L | 5.2, 4.7 | E2E test (5.10) brings up boj-server. |
| 5.4 | `cmd/down.rs`: queries `podman ps --filter label=io.podman.compose.project=<P>`, computes reverse topo order, calls `Driver::stop` then `rm`. Honors `--volumes`, `--rmi <local\|all>`, `--remove-orphans`, `--timeout`. | [A] | M | 5.2, 4.4 | E2E test confirms boj-server tears down cleanly. |
| 5.5 | `cmd/build.rs`, `cmd/pull.rs`: wrappers around the relevant `Op` subset. `[SERVICE…]` filtering. `--no-cache`, `--pull` for build. | [A] | M | 5.2, 4.4 | Unit-tested via MockDriver. |
| 5.6 | `cmd/ps.rs`: calls `Driver::ps(project)` and prints either a tablified text view or JSON. | [A] | S | 5.2, 4.4 | Snapshot test of the output formatter against a fixed `Vec<ContainerSummary>`. |
| 5.7 | `cmd/logs.rs`: uses `driver::logs::tail_logs`. Honors `-f/--follow`, `--tail <N>`, `[SERVICE…]`. | [A] | M | 5.2, 4.8 | Manual smoke test against a chatty container. |
| 5.8 | `cmd/config.rs`: parse + interpolate, emit either pretty TOML or JSON. *Critical for trust/debugging.* | [A] | S | 5.2 | `selur-compose config` on burble fixture produces a snapshot-stable TOML output. |
| 5.9 | `cmd/version.rs`: prints `selur-compose <pkg-version>` and `podman <linked-podman-version>` (calls `podman --version` at runtime). | [I] | S | 5.1, 4.3 | Output stable. |
| 5.10 | Author `crates/selur-compose/src/output.rs`: shared text/JSON/table formatters; `--format json` produces a stable schema documented in `docs/cli-json-schema.adoc`. | [A] | M | 5.1 | Snapshot tests. |
| 5.11 | Author the `--dry-run` global flag (design §9): when set, executor uses a `DryRunDriver` that records but doesn't spawn, and emits the would-be operations list. | [A] | M | 4.6, 5.1 | Snapshot test: `selur-compose --dry-run up` on each consumer fixture matches the planner's snapshot. |
| 5.12 | Author `tests/cli_smoke.rs` using `assert_cmd` + `predicates`: per subcommand, assert exit code and stdout patterns against a fixture tree (using MockDriver-injection via a feature flag or env var `SELUR_COMPOSE_DRIVER=mock`). | [A] | L | 5.1-5.11 | All eight subcommands have at least one CLI smoke test. |
| 5.13 | Wire `tracing-subscriber` from `-v/--verbose` and `-q/--quiet`. Default WARN, `-v` INFO, `-vv` DEBUG, `-q` ERROR. | [I] | S | 5.1 | Manual smoke. |

**Phase 5 exit criteria:**
- `cargo nextest run -p selur-compose` green.
- `cargo nextest run -p selur-compose --features e2e` green on a runner with podman 5.4 — brings up `boj-server/selur-compose.toml` and tears it down.
- `selur-compose config` and `--dry-run up` produce snapshot-stable output for all three consumer fixtures.

---

### Phase 6 — Release engineering & cutover

**Goal:** ship `v0.1.0` to crates.io and GitHub Releases, and submodule it into burble.

**Entry criteria:** Phase 5 exit; CI green for ≥3 days on `main`; CHANGELOG accurate.

| ID | Task | Marr | Effort | Deps | DoD / Files |
|----|------|------|--------|------|-------------|
| 6.1 | Validate the cargo-dist pipeline end-to-end: tag a `v0.1.0-rc.1` and confirm musl tarballs build for both targets. Inspect the binary with `file` to confirm static linkage. | [I] | M | 5.* | Two `.tar.gz` artifacts uploaded to a draft GitHub Release. |
| 6.2 | Confirm publish order resolves cleanly: `cargo publish --dry-run -p selur-compose-schema`, then `-interp`, `-plan`, `-driver`, `selur-compose`. | [I] | S | 6.1 | All five dry-runs succeed. |
| 6.3 | Finalize `CHANGELOG.md` v0.1.0 section: features (parser, interp, plan, driver, eight subcommands, healthcheck-gated depends_on, host networking, musl static binary), deferred items, known issues from §12. | [C] | S | 6.1 | CHANGELOG ready for tag. |
| 6.4 | Finalize `README.adoc`: install, quickstart against boj-server, link to compose-dialect doc, link to design doc. | [A] | S | 6.3 | README renders on GitHub. |
| 6.5 | Tag `v0.1.0`. Confirm `release.yml` runs the cargo-dist build and the `cargo publish` chain. | [I] | S | 6.4 | `cargo install selur-compose` from a clean machine succeeds and produces a working binary. |
| 6.6 | In burble, add `tools/selur-compose` as a submodule pointing at `v0.1.0`. Update `burble/.gitmodules` and `burble/Justfile` with a `stack-up` recipe. *Out of scope for selur-compose CI; tracked in burble.* | [I] | S | 6.5 | `git submodule update --init` populates `tools/selur-compose`. |
| 6.7 | Container image: author `Containerfile` based on `cgr.dev/chainguard/static:latest` with the static binary `COPY`'d in. Push to `ghcr.io/hyperpolymath/selur-compose:0.1.0` and `:latest`. | [A] | M | 6.1 | Image pulls and runs `selur-compose --version`. |
| 6.8 | Open the v0.2 milestone with the deferred subcommands and `convert` features as issues. | [I] | S | 6.5 | Milestone visible. |

**Phase 6 exit criteria (= v0.1.0 release):**
- `cargo install selur-compose` works on a clean Linux box.
- `cargo binstall selur-compose` works on a clean Linux box.
- `selur-compose up` brings the boj-server stack up.
- All three consumer files round-trip and plan-snapshot stably.

---

## 4. Testing strategy execution

The design's three-layer pyramid (unit → integration → e2e) maps to concrete files and CI matrix entries.

### Unit (always-on, fast, no podman)

| File | Contents | Created in task |
|------|----------|----------------|
| `crates/selur-compose-schema/tests/round_trip.rs` | Round-trip property test over the valid corpus. | 1.13 |
| `crates/selur-compose-schema/tests/parse_snapshots.rs` | insta snapshots of `Debug(Compose)`. | 1.15 |
| `crates/selur-compose-schema/tests/error_cases.rs` | Invalid-fixture → typed-error assertions. | 1.16 |
| `crates/selur-compose-schema/tests/fuzz.rs` | proptest, 256 cases per CI run. | 1.14 |
| `crates/selur-compose-interp/tests/expand.rs` | Table-driven grammar tests. | 2.2 |
| `crates/selur-compose-interp/tests/dotenv.rs` | `.env` discovery + parsing. | 2.3 |
| `crates/selur-compose-interp/tests/snapshots/` | Interp output for each consumer file. | 2.7 |
| `crates/selur-compose-plan/tests/plan_snapshots.rs` | DAG snapshots with redacted hashes. | 3.7 |
| `crates/selur-compose-plan/tests/cycles.rs` | Cycle detection. | 3.3 |
| `crates/selur-compose-driver/tests/argv_snapshots.rs` | argv composition snapshots. | 4.2 |
| `crates/selur-compose-driver/tests/mock_driver.rs` | Executor against MockDriver. | 4.6, 4.7 |
| `crates/selur-compose/tests/cli_smoke.rs` | Per-subcommand `assert_cmd` smoke. | 5.12 |

### Integration (`--features podman-it`, CI runner with podman)

| File | Contents | Created in task |
|------|----------|----------------|
| `crates/selur-compose-driver/tests/it_lifecycle.rs` | Bring up + tear down a single static container; assert state via `inspect`. | 4.4 |
| `crates/selur-compose-driver/tests/it_network.rs` | Create/inspect/delete a network. | 4.4 |
| `crates/selur-compose-driver/tests/it_volume.rs` | Create/inspect/delete a volume. | 4.4 |
| `crates/selur-compose-driver/tests/it_healthcheck.rs` | Slow health command, assert `WaitHealthy` honors timeout. | 4.5 |
| `crates/selur-compose-driver/tests/it_logs.rs` | Two-service log multiplexing. | 4.8 |

### End-to-end (`--features e2e`, sibling repos checked out)

| File | Contents | Created in task |
|------|----------|----------------|
| `tests/e2e_boj_server.rs` | Bring up boj-server, assert healthy, tear down. PR-blocking. | 5.* |
| `tests/e2e_burble.rs` | Bring up the full burble stack. Nightly only (heavy build). | 5.*, runs in nightly CI |
| `tests/e2e_dry_run.rs` | `--dry-run up` for all three fixtures matches snapshot. | 5.11 |

### Fixtures

`tests/fixtures/` (workspace-level) and `crates/selur-compose-schema/tests/fixtures/` (parser-level) are populated in tasks 1.1, 1.16, 2.5. The three real consumer files are kept as the load-bearing corpus. Add intentionally-bad fixtures (`unknown_field.toml`, `cycle_in_depends_on.toml`, `bad_duration.toml`, `missing_image_or_build.toml`, `bad_port.toml`) under `tests/fixtures/invalid/`.

### CI matrix

Workflow defined in P-8.

- **Per-PR:** stable + MSRV; `fmt`, `clippy -D warnings`, unit tests, `--features podman-it` (when driver crate touched), `--features e2e` for boj-server only.
- **Nightly:** full e2e against burble + 10000-case fuzz + `cargo-mutants`.

---

## 5. Release engineering

### Pre-release checklist (executed during Phase 6)

1. **Version bump:** workspace `Cargo.toml` → `version = "0.1.0"`. All five crates inherit via `version.workspace = true`.
2. **CHANGELOG:** move `Unreleased` → `[0.1.0] — 2026-MM-DD` (task 6.3).
3. **Lockfile:** ensure `Cargo.lock` committed and reproducible (musl builds depend on it).
4. **Docs:** `README.adoc`, `docs/compose-dialect.adoc`, `docs/cli-json-schema.adoc` all reflect v0.1.0 surface.
5. **`cargo dist plan`:** clean output, no warnings.

### Release workflow (executed in Phase 6)

1. Open a `release/v0.1.0` PR bumping versions and finalizing CHANGELOG. Merge after CI green.
2. Tag `v0.1.0` on `main`. `release.yml` runs:
   - `cargo dist build` produces `selur-compose-0.1.0-x86_64-unknown-linux-musl.tar.gz` and `…-aarch64-…`.
   - SHA256SUMS file generated.
   - GitHub Release published with tarballs + SHA256SUMS attached.
   - `cargo publish` runs in dependency order: schema → interp → plan → driver → binary, each with a 30-second sleep between (crates.io index propagation).
3. Container image (task 6.7) built and pushed to `ghcr.io/hyperpolymath/selur-compose:0.1.0`, `:latest`.
4. Burble submodule update (task 6.6) is a separate PR in the burble repo.

### Version bumping policy (per design §10)

- v0.x: minor bumps may break TOML schema with a CHANGELOG migration note + deprecation warnings for one minor before removal.
- Patch bumps: bug fixes only.
- Move to v1.0.0 once burble + verisimdb test-infra stacks have run for 30 consecutive days.

### CHANGELOG content (v0.1.0)

```
## [0.1.0] — 2026-MM-DD
### Added
- TOML compose parser handling services, networks, volumes, secrets, configs, x-* extensions.
- Variable interpolation: ${VAR}, ${VAR:-default}, ${VAR:?err}, $$ escape.
- .env file discovery (file directory; --env-file overrides).
- Plan generation: topological waves with healthcheck-gated barriers.
- Podman 5.4 driver: build, pull, run, stop, rm, logs, ps, healthcheck-poll.
- CLI subcommands: up, down, build, pull, ps, logs, config, version.
- --dry-run global flag.
- musl static binaries for x86_64 and aarch64 Linux.
### Known limitations
- Linux rootless only.
- No exec/run/restart/stop/start/kill subcommands (v0.2).
- No miette span errors (v0.2).
- A static-base service with a shell-string healthcheck will fail at runtime; document only.
```

---

## 6. Parallelizable workstreams

Tasks suitable for simultaneous dispatch:

| ID | Task | Marr | Notes |
|----|------|------|-------|
| 1.1 | Copy real consumer files into fixture tree | [I] | No deps beyond P-4. |
| P-5 | `flake.nix` authoring | [A] | Independent of `Cargo.toml` body. |
| P-6 | `Justfile` authoring | [A] | Independent. |
| P-8 | CI workflow | [A] | Only needs P-3/P-6. |
| P-10 | `dist-workspace.toml` | [A] | Independent. |
| 1.5-1.10 | The six self-contained schema sub-modules (`depends_on.rs`, `networks.rs`, `volumes.rs`, `ports.rs`, `healthcheck.rs`, `secrets.rs`) | [A] | All share `Service` from 1.3 but otherwise independent of each other. |
| 4.6 | `MockDriver` | [A] | Only needs trait from 4.1. |
| 4.10 | EACCES detection | [A] | Tiny; pattern-match-only. |
| 5.5/5.6/5.8/5.9 | `build`, `ps`, `config`, `version` subcommands | [A] | All thin wrappers; can be done in parallel after 5.2. |
| 1.16 | Bad-fixture authoring | [I] | Just hand-written tomls. |

These ten are the input to the next-stage Sonnet/Haiku volley. Tasks 1.5-1.10 are six fan-outable subtasks of one slot.

---

## 7. Risk-driven contingencies

For each open risk in design §12:

### R1 — Healthcheck shell vs exec semantics on shell-less images

- **Detection:** an integration test brings up a `cgr.dev/chainguard/static`-based service with a shell-form healthcheck and watches it report `unhealthy` indefinitely.
- **Response:** add task 4.5+ to surface a runtime warning when `Healthcheck::Shell` is paired with images known to lack a shell. Do *not* attempt to detect this at parse time. Update `docs/compose-dialect.adoc` with a "shell-less base images" callout.

### R2 — Podman 5.x JSON output churn

- **Detection:** integration tests fail after a podman point-release bump; specifically `serde::Deserialize` errors on `inspect` or `ps` JSON.
- **Response:** the existing `PodmanV5Adapter` shim (task 4.9) is the contingency surface. Add a new field with `#[serde(default)]`, regenerate the JSON snapshot fixture, ship a patch release. If the change is breaking, gate behind a `--driver-podman-version=4|5` flag in v0.2.

### R3 — Rootless port < 1024 EACCES

- **Detection:** `podman run` stderr contains "permission denied while trying to bind".
- **Response:** task 4.10 already wraps this. If users hit it, link from the error message to a docs page explaining `sysctl net.ipv4.ip_unprivileged_port_start` and `CAP_NET_BIND_SERVICE`.

### R4 — `.env` discovery surprises

- **Detection:** issue reports / CHANGELOG complaints during the 30-day stabilization window.
- **Response:** add an explicit `--env-file-no-discover` flag in v0.1.x patch if needed; otherwise hold the line. Discovery rule documented in P-13.

### R5 — `depends_on` cycle / diamond

- **Detection:** task 3.3's cycle test plus a hand-built diamond fixture in task 3.7's snapshot suite.
- **Response:** already handled. The dedup invariant is asserted in 3.3.

### R6 — TOML lacks YAML anchors

- **Detection:** consumer files start growing copy-pasted blocks; an issue requests `extends`.
- **Response:** v0.2+ feature, design `[templates]` section as a separate spike. Out of scope for v0.1.0.

### R7 — Coexistence with podman-compose

- **Detection:** a user runs `selur-compose down` after `podman-compose up` and reports unexpected behavior.
- **Response:** intentional per design. Document explicitly in README ("interoperates with podman-compose via shared label `io.podman.compose.project`").

### R8 — Buildah direct calls

- **Detection:** N/A in v0.1.0; we never call buildah directly.
- **Response:** none.

### R9 — Repo bootstrapping

- **Detection:** N/A; covered by Phase 0 prerequisites.
- **Response:** P-1 through P-12.

---

## 8. Completion criteria

v0.1.0 is done iff *all* of the following are demonstrably true on a freshly-provisioned Linux x86_64 machine with podman 5.4 installed:

1. **Install path A:** `cargo install selur-compose` succeeds and produces a `selur-compose` binary in `~/.cargo/bin/`.
2. **Install path B:** `cargo binstall selur-compose` retrieves the musl static binary from the GitHub Release.
3. **Install path C:** `podman run --rm ghcr.io/hyperpolymath/selur-compose:0.1.0 --version` prints `selur-compose 0.1.0`.
4. **Parse fidelity:** `selur-compose -f burble/containers/selur-compose.toml config` prints stable TOML; running it twice and `diff`-ing produces no output.
5. **Plan stability:** `selur-compose -f burble/containers/selur-compose.toml --dry-run up` matches the committed plan snapshot byte-for-byte (with hashes redacted).
6. **End-to-end:** in a clean podman state, `cd boj-server && selur-compose up -d` brings up one container, `selur-compose ps` shows it as `healthy` within 60 seconds, and `selur-compose down` removes it cleanly. All four operations exit 0.
7. **Healthcheck gating:** a constructed two-service fixture (`a` healthy, `b depends_on={a={condition=service_healthy}}`) demonstrates that `b` does not start until `a` reports healthy. Asserted by the integration test suite.
8. **Host networking:** the burble `coturn` service (with `network_mode = "host"`) starts cleanly under `selur-compose up` on a host where ports 3478/5349 are free.
9. **Static binary:** `file selur-compose-0.1.0-x86_64-unknown-linux-musl/selur-compose` reports "statically linked".
10. **CI signal:** main branch CI is green; nightly e2e burble run from the prior 24h is green.
11. **Crates published:** `cargo search selur-compose-schema` returns the v0.1.0 entry; same for the four other crates.
12. **Submodule landed in burble:** `tools/selur-compose` exists at the v0.1.0 tag; `burble/Justfile` `stack-up` recipe wraps the binary.
13. **No regressions in podman-compose interop:** running `podman-compose up` on a stack and then `selur-compose ps` on the same project name shows the same containers (verified once manually; documented in the test plan).

When all 13 criteria are observable, v0.1.0 ships.
