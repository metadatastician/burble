# selur-compose — v0.1 design

**Status:** design draft, 2026-05-07
**Repo target:** `github.com/hyperpolymath/selur-compose` (new, standalone)
**Submodule mount in burble:** `tools/selur-compose/`

---

## 1. Goals & non-goals

### Goals (v0.1)

- Parse `*.toml` compose files written in the dialect already in use across hyperpolymath (`burble/containers/selur-compose.toml`, `burble/containers/compose.toml`, `boj-server/selur-compose.toml`, the verisimdb test-infra stack referenced in its CLAUDE.md).
- Drive Podman 5.4.2 rootless on Linux to bring up, tear down, build, pull, and observe a stack of containers with their networks and volumes.
- Compose v2 feature parity for the surface that real consumer files use: services, networks, volumes, build (with args), depends_on (list and map-with-condition forms), healthcheck, ports, environment, env_file, secrets, profiles, configs, restart, network_mode (including `host`), entrypoint, command, named volumes, bind mounts with `:ro` flags, and `${VAR:-default}` shell-style env interpolation.
- Single static `selur-compose` binary, suitable for `cargo install`, `cargo binstall`, and shipping inside a `cgr.dev/chainguard/static:latest` image.
- Drop-in CLI ergonomics close enough to `podman-compose` that the comments in existing `.toml` files (`# podman-compose -f selur-compose.toml up -d`) remain conceptually accurate.

### Non-goals (v0.1)

- `[x-svalinn]` policy enforcement, signed-image gating, SBOM verification — all deferred to whenever Stapeln integration lands.
- `[x-stapeln]` signed-bundle execution and `cerro-torre` `.ctp` bundle verification — separate sub-projects.
- Docker Compose v1 quirks, `extends:`, the legacy `links:` system, Swarm-only keys (`deploy:`).
- A `libpod` REST daemon dependency. We talk to podman as a CLI subprocess in v0.1.
- Kubernetes pod manifests, `podman kube generate` integration. Maybe v0.3.
- Windows or macOS first-class support. Linux rootless only in v0.1.
- A daemon mode, file watcher, or "hot reload".

---

## 2. High-level architecture

Five components, in dependency order:

1. **`schema`** — pure data: serde-deriving structs/enums for the TOML compose dialect. No I/O.
2. **`interp`** — variable interpolation: `${VAR}`, `${VAR:-default}`, `${VAR:?err}` resolution against process env + `.env` files, performed *after* TOML parsing on string-typed fields. Pure function over schema + env map.
3. **`plan`** — turns a parsed, interpolated `Compose` into a `Plan`: a partially-ordered DAG of operations (`CreateNetwork`, `CreateVolume`, `BuildImage`, `PullImage`, `RunContainer`, `WaitHealthy`, `StopContainer`, `RemoveContainer`, …). Owns the topological sort over `depends_on`, profile filtering, and label allocation (`io.podman.compose.project=<name>`, `io.podman.compose.service=<name>`, `io.podman.compose.config-hash=<sha256>`).
4. **`driver`** — executes a `Plan` by spawning podman processes. Trait-bounded so a `MockDriver` can stand in for tests, but the real production driver shells out to `/usr/bin/podman`.
5. **`cli`** — clap parser, subcommands, output formatting. Thin shell over the four libraries.

Data flow:

```
*.toml file ─┐
.env files  ─┼─► schema::Compose ─► interp ─► plan::Plan ─► driver::execute ─► podman procs
process env ─┘                                       │
                                                     └► cli output (table/json)
```

Boundary discipline: nothing above the `driver` boundary may know about podman. Nothing below the `schema` boundary may touch I/O. This keeps the parser fuzzable and the planner snapshot-testable without containers running.

---

## 3. Repository layout

Standalone repo `selur-compose`, single Cargo workspace. Workspace because the four libraries above benefit from being separately testable and because `selur-compose-schema` is the kind of crate other hyperpolymath tools (e.g. a future `svalinn-policy-lint`) will want to consume without pulling in a podman driver.

```
selur-compose/
├── Cargo.toml                       # workspace root
├── README.adoc
├── LICENSE                          # MPL-2.0
├── 0-AI-MANIFEST.a2ml
├── flake.nix
├── Justfile
├── crates/
│   ├── selur-compose-schema/        # serde types, no I/O
│   │   ├── Cargo.toml
│   │   └── src/{lib.rs, services.rs, networks.rs, volumes.rs, build.rs,
│   │              healthcheck.rs, depends_on.rs, ports.rs, secrets.rs}
│   ├── selur-compose-interp/        # ${VAR:-default} expansion + .env loading
│   │   └── src/lib.rs
│   ├── selur-compose-plan/          # planner: DAG, topo sort, hashing
│   │   └── src/{lib.rs, dag.rs, hash.rs, profiles.rs}
│   ├── selur-compose-driver/        # podman CLI driver + Driver trait
│   │   └── src/{lib.rs, podman.rs, healthcheck.rs, exec.rs, mock.rs}
│   └── selur-compose/               # the binary crate (clap, main.rs)
│       └── src/{main.rs, cmd/up.rs, cmd/down.rs, cmd/build.rs, cmd/ps.rs,
│                cmd/logs.rs, cmd/config.rs, cmd/pull.rs, output.rs}
├── tests/                           # workspace-level integration & e2e
│   ├── fixtures/                    # known-good and known-bad .toml files
│   ├── snapshots/                   # insta snapshots for plans
│   ├── parse.rs
│   ├── plan.rs
│   └── e2e_burble.rs                # gated behind --features e2e + PODMAN
└── docs/
    └── compose-dialect.adoc
```

Five crates, but the public binary is one. `selur-compose-schema` and `selur-compose-plan` are publishable on crates.io independently; the others are internal in spirit but published for reproducibility.

---

## 4. TOML schema → Rust types

Top-level root, with `#[serde(deny_unknown_fields)]` *off* at the root so `[x-svalinn]` and friends are tolerated as unknowns, but on inside service/network/volume bodies so typos fail loudly.

```rust
// crates/selur-compose-schema/src/lib.rs

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct Compose {
    pub project:  Option<Project>,
    #[serde(default)]
    pub services: BTreeMap<String, Service>,
    #[serde(default)]
    pub networks: BTreeMap<String, Network>,
    #[serde(default)]
    pub volumes:  BTreeMap<String, Volume>,
    #[serde(default)]
    pub secrets:  BTreeMap<String, Secret>,
    #[serde(default)]
    pub configs:  BTreeMap<String, Config>,
    #[serde(flatten)]
    pub extensions: BTreeMap<String, toml::Value>,   // captures x-* tables
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Project {
    pub name: String,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Service {
    pub image:        Option<String>,
    pub build:        Option<Build>,
    pub command:      Option<StringOrList>,
    pub entrypoint:   Option<StringOrList>,
    #[serde(default)]
    pub environment:  EnvMap,                // see below
    #[serde(default)]
    pub env_file:     Vec<PathBuf>,
    #[serde(default)]
    pub ports:        Vec<PortBinding>,
    #[serde(default)]
    pub volumes:      Vec<MountSpec>,
    #[serde(default)]
    pub networks:     Vec<String>,
    pub network_mode: Option<NetworkMode>,
    #[serde(default)]
    pub depends_on:   DependsOn,
    pub healthcheck:  Option<Healthcheck>,
    #[serde(default)]
    pub restart:      RestartPolicy,
    #[serde(default)]
    pub profiles:     Vec<String>,
    #[serde(default)]
    pub secrets:      Vec<SecretRef>,
    #[serde(default)]
    pub configs:      Vec<ConfigRef>,
    pub user:         Option<String>,
    pub working_dir:  Option<String>,
    pub hostname:     Option<String>,
    #[serde(default)]
    pub cap_add:      Vec<String>,
    #[serde(default)]
    pub cap_drop:     Vec<String>,
    pub init:         Option<bool>,
    pub stop_signal:  Option<String>,
    pub stop_grace_period: Option<DurationStr>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Build {
    pub context:    PathBuf,
    pub dockerfile: Option<PathBuf>,
    #[serde(default)]
    pub args:       BTreeMap<String, String>,
    #[serde(default)]
    pub target:     Option<String>,
    #[serde(default)]
    pub labels:     BTreeMap<String, String>,
    #[serde(default)]
    pub no_cache:   bool,
}

#[derive(Debug, Clone, Deserialize, Serialize, Default)]
#[serde(rename_all = "kebab-case", deny_unknown_fields)]
pub enum RestartPolicy {
    #[default]
    No,
    Always,
    OnFailure { #[serde(default)] max_retries: Option<u32> },
    UnlessStopped,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum NetworkMode {
    Bridge,
    Host,
    None,
    #[serde(untagged)] Container(String),     // container:<name|id>
    #[serde(untagged)] Custom(String),        // any other named mode
}

#[derive(Debug, Clone, Deserialize, Serialize, Default)]
#[serde(untagged)]
pub enum DependsOn {
    #[default]
    Empty,
    List(Vec<String>),                                          // ["server"]
    Map(BTreeMap<String, DependsOnSpec>),                        // {verisimdb={condition="service_healthy"}}
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DependsOnSpec {
    pub condition: DependsCondition,
    #[serde(default)]
    pub restart:   bool,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DependsCondition {
    ServiceStarted,
    ServiceHealthy,
    ServiceCompletedSuccessfully,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Healthcheck {
    pub test:         HealthcheckTest,
    pub interval:     Option<DurationStr>,
    pub timeout:      Option<DurationStr>,
    pub retries:      Option<u32>,
    pub start_period: Option<DurationStr>,
    #[serde(default)]
    pub disable:      bool,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(untagged)]
pub enum HealthcheckTest {
    Shell(String),                  // "wget -q --spider … || exit 1"
    Exec(Vec<String>),              // ["CMD", "wget", …] or ["CMD-SHELL", "…"]
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(untagged)]
pub enum EnvMap { List(Vec<String>), Map(BTreeMap<String, Option<String>>) }

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(untagged)]
pub enum StringOrList { String(String), List(Vec<String>) }

// PortBinding parses "4020:80", "4020:80/tcp", "127.0.0.1:4020:80" or struct form.
// MountSpec parses "named-vol:/data", "./conf:/etc/conf:ro", "/abs:/abs" or struct form.
// DurationStr parses "30s", "5m", "1h30m" via humantime.
```

`DependsOn`'s `untagged` enum is the load-bearing type — both forms appear in burble's two compose files within the same project. `RestartPolicy`'s `unless-stopped` mapping (kebab-case) is what burble uses verbatim. `NetworkMode::Host` is required for the `coturn` service.

---

## 5. Podman driver design

### Approach: shell out to the `podman` CLI binary.

I considered libpod REST (`unix:///run/user/1000/podman/podman.sock`) and rejected it for v0.1:

- The REST socket is opt-in (`systemctl --user enable --now podman.socket`); shipping a tool whose first error is "enable podman.socket" is a worse onboarding story than calling a binary that's already in `$PATH` and already works rootless.
- The CLI is the documented public contract. The REST API is documented but moves faster and varies between podman 4.x and 5.x.
- We get colored progress output, podman's own auth-file handling, BuildKit-style build progress, and rootless plumbing for free.
- Performance: `podman run` startup is ~100ms; we run a bounded number of them; subprocess overhead is in the noise compared to image pull/build.

The trade-off: parsing structured output. We mitigate this with `podman <cmd> --format json` everywhere it's available (`ps`, `inspect`, `healthcheck run`, `network ls`, `volume ls`).

### `Driver` trait

```rust
#[async_trait::async_trait]
pub trait Driver: Send + Sync {
    async fn build(&self,  spec: &BuildSpec)   -> Result<ImageId>;
    async fn pull(&self,   image: &str)        -> Result<ImageId>;
    async fn create_network(&self, n: &NetworkSpec) -> Result<()>;
    async fn create_volume(&self,  v: &VolumeSpec)  -> Result<()>;
    async fn run(&self,    spec: &RunSpec)     -> Result<ContainerId>;
    async fn inspect(&self, id: &ContainerId)  -> Result<ContainerState>;
    async fn healthcheck_run(&self, id: &ContainerId) -> Result<HealthState>;
    async fn stop(&self,    id: &ContainerId, grace: Duration) -> Result<()>;
    async fn rm(&self,      id: &ContainerId, force: bool)     -> Result<()>;
    async fn logs(&self,    id: &ContainerId, follow: bool)    -> Result<LogStream>;
    async fn ps(&self,      project: &str)     -> Result<Vec<ContainerSummary>>;
}
```

Production impl `PodmanCli` constructs argv vectors and runs them via `tokio::process::Command`, capturing stdout/stderr. Non-zero exits become `DriverError::Podman { argv, exit_code, stderr }`.

### `up` command sequence (annotated)

```
1. parse + interpolate selur-compose.toml
2. build Plan
3. for each network not present (podman network ls --format json):
     podman network create --label io.podman.compose.project=<P> <name>
4. for each volume not present (podman volume ls --format json):
     podman volume create --label io.podman.compose.project=<P> <name>
5. concurrently, for services with build {} and not --no-build:
     podman build --tag <P>_<svc>:latest \
                  --file <dockerfile> \
                  --build-arg KEY=VAL ... \
                  <context>
6. concurrently, for services with image but no build:
     podman pull <image>           (skipped if --no-pull)
7. topological waves over services (Kahn's algo over depends_on edges):
     for each wave, concurrently for each service in wave:
       podman run --detach \
                  --name <P>_<svc> \
                  --label io.podman.compose.project=<P> \
                  --label io.podman.compose.service=<svc> \
                  --label io.podman.compose.config-hash=<sha256> \
                  --network <P>_<net> | --network host \
                  --restart unless-stopped \
                  --health-cmd "..." --health-interval 30s --health-retries 3 \
                  --env KEY=VAL ... \
                  --env-file path/.env ... \
                  --volume name:/data --volume ./conf:/etc/conf:ro \
                  --publish 4020:80 \
                  --secret <name>,target=... \
                  <image-or-built-tag>
       if any downstream depends_on this service with condition=service_healthy:
         block on healthcheck-gate (see below)
8. emit summary table (service, container id, status, ports)
```

### Healthcheck-gated `depends_on`

When service B depends on A with `condition = "service_healthy"`, the planner records a `WaitHealthy(A)` barrier between A's `RunContainer` and B's `RunContainer`. The driver implements `WaitHealthy` by polling:

```
loop {
    podman inspect --format json <container>
    let st: ContainerState = parse;
    match st.health.status {
        "healthy"   => break Ok,
        "unhealthy" => break Err(Unhealthy),
        "starting" | "none" => sleep(min(2s, healthcheck.interval)),
    }
    if elapsed > start_period + interval * (retries + 1) + slack:
        break Err(Timeout);
}
```

We call `podman healthcheck run <container>` only when the service has a healthcheck *we configured but podman didn't auto-schedule yet* (relevant for the corner case where `--health-start-period` hasn't elapsed and the user has set `condition=service_healthy` aggressively). Default path is to trust podman's own scheduler.

### `down`

`podman ps --filter label=io.podman.compose.project=<P> --format json` → reverse topological order → `podman stop` (respecting `stop_grace_period`) → `podman rm`. Networks and volumes are *not* removed by default; `down --volumes` removes named volumes, `down --rmi local` removes built images.

### `build` and `pull`

Same as steps 5 and 6 of `up`, but standalone and without `--detach`/`run`.

---

## 6. CLI surface

clap-derive, single `selur-compose` binary. Flag parity with `podman-compose` where it costs us nothing.

### Global flags

- `-f, --file <PATH>` — compose file (default: `selur-compose.toml`, fallback `compose.toml`)
- `-p, --project-name <NAME>` — overrides `[project].name`
- `--env-file <PATH>` — additional env files (repeatable)
- `--profile <NAME>` — enable profile (repeatable)
- `-v, --verbose` / `-q, --quiet`
- `--format <text|json>` — output format

### v0.1.0 subcommands

| Subcommand | Purpose | Key flags |
| ---------- | ------- | --------- |
| `up`       | bring stack up | `-d/--detach`, `--build`, `--no-build`, `--no-pull`, `--force-recreate`, `--remove-orphans`, `[SERVICE…]` |
| `down`     | tear stack down | `--volumes`, `--rmi <local\|all>`, `--remove-orphans`, `--timeout` |
| `build`    | build images | `--no-cache`, `--pull`, `[SERVICE…]` |
| `pull`     | pull images | `[SERVICE…]` |
| `ps`       | list containers | `--all`, `--quiet` |
| `logs`     | tail logs | `-f/--follow`, `--tail <N>`, `[SERVICE…]` |
| `config`   | print parsed+interpolated compose to stdout | `--format <toml\|json>` |
| `version`  | print version + linked podman version | — |

### Deferred (v0.2+)

`exec`, `run` (one-shot), `restart`, `stop`, `start`, `kill`, `port`, `top`, `events`, `cp`, `pause`, `unpause`. None of these are required for the burble use-cases and most are trivially layered on top of the existing `Driver` trait once we ship.

`config` is in v0.1 because it's the test-and-debugging escape hatch — being able to type `selur-compose config` and see the fully interpolated TOML is what buys us trust.

---

## 7. Concurrency model

**Tokio, multi-threaded runtime.**

Compose has natural parallelism at three layers:

1. **Network/volume creation** — fully independent, fan-out.
2. **Image build/pull** — independent across services.
3. **Service start within a topological wave** — services in the same wave have no `depends_on` edges between them, so their `podman run` invocations run concurrently.

A `tokio::process::Command`-based driver gives us this concurrency naturally with `JoinSet` per wave. Trying to do this with `std::thread` plus blocking `Command::output` works but forces us to hand-roll the bounded-concurrency limiter, the cancellation-on-error semantics, and the log-multiplexing for `logs -f`. Tokio gets us those for free.

Bounded concurrency: a single `Semaphore` with capacity `min(num_cpus, 8)` gates simultaneous `podman build` invocations, because builds are CPU- and disk-heavy and oversubscription on a four-core dev box is painful. `podman run` and `podman pull` are not gated — the bottleneck there is the registry / kernel networking stack, and podman handles its own concurrency internally.

`logs -f` across multiple services uses one `tokio::spawn` per service and merges stderr/stdout lines through an `mpsc::channel<LogLine>` into a single ordered printer task, prefixed with `[<service>] `. This is the one place where async pays off most directly; the std::thread version is meaningfully worse.

Async features used: `tokio::process`, `tokio::sync::{Semaphore, mpsc, Notify}`, `tokio::time::timeout`, `tokio::task::JoinSet`. We do **not** pull in axum/hyper/reqwest — there's no networking stack; we shell out.

---

## 8. Error handling

Hybrid, with a clear rule:

- **Library crates** (`schema`, `interp`, `plan`, `driver`) use **`thiserror`**. Each defines its own `#[derive(Error)] enum FooError`. Variants are typed and carry actionable context (filename, span, container id, exit code). These errors compose: `plan::PlanError::Schema(#[from] schema::ParseError)`.
- **Binary crate** (`selur-compose`) uses **`anyhow`** at the `main()` boundary, with `.context("while bringing up service `verisimdb`")`-style enrichment. Each subcommand returns `anyhow::Result<()>`, formatting the chain with `{:#}` for human output, and rendering as JSON when `--format json` is set.

Concretely:

```rust
// schema
#[derive(thiserror::Error, Debug)]
pub enum ParseError {
    #[error("invalid TOML in {file}: {source}")]
    Toml { file: PathBuf, #[source] source: toml::de::Error },
    #[error("unknown field `{field}` in [services.{service}] (did you mean `{suggestion}`?)")]
    UnknownField { service: String, field: String, suggestion: String },
    #[error("[services.{service}] requires either `image` or `build`")]
    MissingImageOrBuild { service: String },
}

// driver
#[derive(thiserror::Error, Debug)]
pub enum DriverError {
    #[error("podman exited {code}: {stderr}\n  argv: {argv:?}")]
    Podman { argv: Vec<String>, code: i32, stderr: String },
    #[error("service `{service}` did not become healthy within {timeout:?}")]
    HealthcheckTimeout { service: String, timeout: Duration },
    #[error("io error talking to podman: {0}")]
    Io(#[from] std::io::Error),
}
```

`miette` is **not** adopted in v0.1; pretty span-pointing reports for TOML errors are nice but `toml`'s built-in `Span`-bearing errors plus `anyhow`'s chain printing are sufficient at this stage. Revisit in v0.3.

---

## 9. Testing strategy

Three layers, all running in CI:

### Unit (fast, no podman)

- **Parser tests** in `crates/selur-compose-schema/tests/`: round-trip a corpus of `.toml` files (valid + invalid) and assert error variants. Two-way: parse → serialize → parse and assert equality. `serde_json::to_value` round-trip catches accidental untagged-enum collisions.
- **Interpolation tests**: table-driven, covering `${VAR}`, `${VAR:-default}`, `${VAR:?required}`, escaping (`$$VAR`), and the "literal `$` in coturn entrypoint" case from burble's compose file (which embeds `$args` inside a shell string — interpolation must stop at TOML-string boundaries, not interpret the shell).
- **Planner tests** with **`insta`** snapshots: feed the three real consumer files (`burble/containers/compose.toml`, `burble/containers/selur-compose.toml`, `boj-server/selur-compose.toml`) into the planner and snapshot the resulting `Plan` (DAG ops, in topological order, with config hashes redacted to `<HASH>`). Snapshot review becomes the human gate on "did we change semantics".

### Integration (driver against real podman, opt-in)

- Gated behind `--features podman-it` and a CI-detected podman binary.
- A `MockDriver` records calls; an integration suite in `tests/driver_podman.rs` brings up a tiny one-service `cgr.dev/chainguard/static:latest` container, asserts state, tears it down. Network and volume lifecycle tested in isolation. Healthcheck-gating tested with an intentional `sleep + true` healthcheck.

### End-to-end (the burble files, opt-in)

- `tests/e2e_burble.rs`, gated behind `--features e2e`, expects burble + boj-server to be checked out at sibling paths. Brings up `boj-server/selur-compose.toml` (smallest stack) and asserts `selur-compose ps` shows one running healthy container. The burble three-service stack is run in CI nightlies, not per-PR — its build is too heavy.
- A `--dry-run` flag (also useful in production) lets the e2e suite assert the *plan* matches a snapshot without actually invoking podman, giving us a fast PR signal that complements the slow nightly e2e.

`cargo nextest` for runner. `cargo-mutants` is wired in but not blocking. `proptest` over the schema for fuzzing the parser; the corpus is seeded from the consumer `.toml` files.

---

## 10. Distribution & versioning

- **crates.io**: publish all five crates on every tag. Workspace `[workspace.package].version` keeps them in lockstep.
- **`cargo install selur-compose`** — works on any machine with a Rust toolchain.
- **`cargo binstall selur-compose`** — primary user path; we ship prebuilt static binaries via `cargo-dist` for `x86_64-unknown-linux-musl` and `aarch64-unknown-linux-musl`. musl static linking gives us the "single static binary" property; no glibc runtime dep means the binary works on any container base, not just Wolfi.
- **GitHub Releases tarballs**, generated by `cargo-dist`, named `selur-compose-<version>-<target>.tar.gz`. SHA256SUMS file alongside, signed with cosign once Stapeln's key infrastructure exists; until then, just the SHA256SUMS.
- **Container image**: published as `cgr.dev/chainguard/static:latest` plus the static binary `COPY`'d in. Tag scheme `ghcr.io/hyperpolymath/selur-compose:<version>` and `:latest`. The image is for "use selur-compose inside CI" cases; for daily use, the binary is preferred because it needs to invoke podman on the host.
- **In burble**: added under `tools/selur-compose` as a git submodule once v0.1.0 ships, mirroring the `tools/affinescript` and `tools/nextgen-databases` precedent. burble's Justfile gets a `stack-up` recipe wrapping `tools/selur-compose/target/release/selur-compose -f containers/selur-compose.toml up -d`.

**SemVer policy** — strict.

- v0.x: we may break TOML schema between minor versions, but only with a migration note in CHANGELOG and a parser that emits a deprecation warning for at least one minor before removal.
- v1.0.0 ships when (a) the burble stack and the verisimdb test-infra stack have run for 30 consecutive days on selur-compose without falling back to podman-compose, and (b) Stapeln integration is no longer blocking real users.
- After v1.0.0: TOML schema changes are major; new optional fields are minor; bug fixes are patch.

---

## 11. Phasing

### v0.1.0 — "drives the burble stack"

Everything in §4–§9 above. Specifically required to land:
- Parse and round-trip the three consumer files with no fidelity loss.
- `up`, `down`, `build`, `pull`, `ps`, `logs`, `config`, `version` subcommands.
- `depends_on` with `service_healthy` gating.
- `network_mode = "host"`.
- `${VAR:-default}` interpolation.
- Restart policies including `unless-stopped`.
- musl static binary on Linux x86_64 + aarch64.

### v0.2.0 — "comfortable daily driver"

- `exec`, `run`, `restart`, `stop`, `start`, `kill` subcommands.
- `--watch` mode that re-applies on TOML edits (uses `notify`).
- `selur-compose convert --to docker-compose` (best-effort YAML emitter, for sharing with non-podman colleagues).
- `selur-compose convert --from docker-compose` (best-effort YAML→TOML, with explicit unsupported-key reporting). Useful for migrating outside repos in.
- Better error messages: `miette` adoption with span underlining.
- macOS support (rootless via `podman machine`).

### v0.3.0 — "Kubernetes-adjacent"

- `selur-compose kube generate` — emit `podman kube` YAML pod manifests from the parsed compose.
- libpod REST driver as an alternative to the CLI driver, behind `--driver=rest`. Selected automatically if `$XDG_RUNTIME_DIR/podman/podman.sock` exists and is healthier than spawning processes.
- BuildKit cache export/import.

### v0.4.0+ — Stapeln-aware

- Read `[x-svalinn]` tables and enforce policy hooks.
- Read `[x-stapeln]` and verify signed bundles before run.
- Consume `cerro-torre` `.ctp` bundles as the unit of deployment (a `.ctp` *contains* a compose file plus signed images).

### Out of scope, possibly forever

- Docker Swarm `deploy:` keys.
- Compose v1 (`version: "2"`) compatibility.
- Windows.

---

## 12. Open risks / unknowns

1. **Healthcheck-shell vs healthcheck-exec semantics.** Burble's `healthcheck.test = "wget … || exit 1"` is a string, which docker-compose interprets as a shell command (equivalent to `["CMD-SHELL", "..."]`). Our `HealthcheckTest::Shell(String)` mirrors this, but we need to confirm `podman run --health-cmd "<string>"` actually runs it under `/bin/sh -c` on every base image we care about. The `cgr.dev/chainguard/static` image has no shell, so a chainguard service with a healthcheck must use the `Exec(Vec<String>)` form. We should fail the parser cleanly when a service uses `static` + a `Shell` healthcheck, but detecting "this image has no shell" is impossible at parse time. Pragma: we just document it.

2. **Podman 5.x output stability.** `podman ps --format json` schema has changed across podman versions. We pin against 5.4 and add a single shim layer (`PodmanV5Adapter`) so v0.2 can grow a `PodmanV4Adapter` if needed. CI runs against the latest podman in the Wolfi repo, which tracks upstream closely.

3. **Rootless port binding below 1024.** Burble's `coturn` service uses `network_mode = "host"`, which sidesteps the port mapping issue, but a future service binding `:80` will need `sysctl net.ipv4.ip_unprivileged_port_start=80` or CAP_NET_BIND_SERVICE. This is a podman/system issue, not a selur-compose issue, but we should detect EACCES from podman and surface a hint.

4. **`.env` discovery rules.** `docker-compose` searches the directory containing the compose file; some users expect CWD search; some expect both. We pick "directory containing the compose file, then `--env-file` overrides", document it, and don't try to be clever. Watch for complaints.

5. **`depends_on` cycles.** We reject cycles at plan time with a clear error pointing at the cycle. Easy. But "diamond" depends_on with `service_healthy` on both sides has an implementation gotcha: we must not double-wait by spawning two pollers against the same container; the planner deduplicates `WaitHealthy(X)` barriers.

6. **TOML's lack of YAML anchors.** Compose files often share blocks via YAML anchors (`<<: *defaults`). TOML has no native equivalent. The `boj-server` and `burble` files don't currently need this, but as the stacks grow, users may want it. v0.2+ may grow a `[templates]` section that services can `extends = "templates.base"` against. Not in v0.1.

7. **Interaction with `podman-compose` users.** During the transition, both tools will run against the same compose files. `podman-compose` labels containers with `io.podman.compose.project`. We use the same label key, so `podman ps` from either tool sees the other's containers. `selur-compose down` will stop containers `podman-compose` started. This is intentional; it makes migration safe.

8. **Buildah vs `podman build`.** `podman build` already delegates to buildah internally. We never call buildah directly. If a future Stapeln integration needs it, it goes in v0.4.

9. **Repo bootstrapping.** This document is the design only — it does not create the repo. Next physical step is for the user (or a subsequent non-read-only session) to create `github.com/hyperpolymath/selur-compose` from `rsr-template-repo` (the convention used elsewhere in the org per the verisimdb CLAUDE.md), drop in the workspace `Cargo.toml`, and start with the `selur-compose-schema` crate against the `boj-server/selur-compose.toml` fixture as the first parser test target.

---

### Critical files for implementation

The five files below are the load-bearing artifacts; the design above is fully grounded in them.

- `/home/joshua/Documents/repos/burble/containers/selur-compose.toml`
- `/home/joshua/Documents/repos/burble/containers/compose.toml`
- `/home/joshua/Documents/repos/boj-server/selur-compose.toml`
- `/home/joshua/Documents/repos/burble/tools/nextgen-databases/verisimdb/Cargo.toml`
- `/home/joshua/Documents/repos/burble/.gitmodules`
