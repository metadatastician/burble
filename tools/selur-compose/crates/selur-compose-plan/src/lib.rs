//! `selur-compose-plan` — DAG planner for selur-compose.
//!
//! # Overview
//!
//! This crate exposes a single pure function, [`plan`], that converts a parsed
//! [`selur_compose_schema::Compose`] value into a [`Plan`]: a total ordering
//! (expressed as topological waves) of [`Op`]erations that the driver layer
//! must execute to bring the stack up.
//!
//! No I/O is performed here.  The crate is deliberately free of async code,
//! podman knowledge, and process-environment access.
//!
//! # Input invariants
//!
//! * The `Compose` value must have been produced by
//!   [`selur_compose_schema::parse_str`] — i.e. it has already passed
//!   structural and semantic validation.
//! * Callers should interpolate environment variables (Phase 2, `selur-compose-interp`)
//!   before calling `plan`.  The planner treats all strings as opaque.
//! * Profile filtering is performed by the planner itself based on
//!   [`PlanOptions::profiles`]; callers do not pre-filter services.
//!
//! # Output invariants
//!
//! * [`Plan::waves`] is a valid topological ordering: every service in wave `n`
//!   depends only on services in waves `0..n-1`.
//! * [`Plan::ops`] lists every operation exactly once, in the order they should
//!   be presented to the driver.  Within a wave all service-level ops may
//!   execute concurrently.
//! * Config hashes (embedded in [`RunSpec::labels`] under the key
//!   `io.podman.compose.config-hash`) are stable: the same `Service` value
//!   always produces the same 64-character lowercase hex SHA-256 digest.
//! * Duplicate [`Op::WaitHealthy`] barriers for the same service are
//!   deduplicated; a diamond `depends_on` pattern with `service_healthy` on
//!   both branches produces exactly one barrier, not two.
//!
//! # Error model
//!
//! All errors are returned as [`PlanError`] variants.  The planner never
//! panics on well-formed input; panics in this crate are bugs.

use std::collections::BTreeMap;

use selur_compose_interp::InterpError;
use selur_compose_schema::Compose;

pub mod dag;
pub mod hash;
pub mod profiles;

// Re-export the types the driver crate (and tests) will need directly.
pub use dag::{EdgeKind, NodeId};

// ---------------------------------------------------------------------------
// Op and its spec structs
// ---------------------------------------------------------------------------

/// A single operation in a compose plan.
///
/// Ops are arranged by [`Plan::waves`] into parallel groups.  Within a wave
/// all ops can execute concurrently.  [`Op::WaitHealthy`] barriers appear
/// between waves when `depends_on.condition = "service_healthy"` is required.
#[derive(Debug, Clone, PartialEq)]
pub enum Op {
    /// Ensure a named network exists (`podman network create …`).
    CreateNetwork(NetworkSpec),
    /// Ensure a named volume exists (`podman volume create …`).
    CreateVolume(VolumeSpec),
    /// Build an image from source (`podman build …`).
    BuildImage(BuildSpec),
    /// Pull an image from a registry (`podman pull …`).
    PullImage(PullSpec),
    /// Start a service container (`podman run …`).
    RunContainer(RunSpec),
    /// Block until a container reports healthy.
    ///
    /// Inserted between waves when a downstream service has
    /// `depends_on.condition = "service_healthy"`.  Deduplicated: at most one
    /// `WaitHealthy` per service per plan.
    WaitHealthy(WaitHealthySpec),
    /// Stop a running container (`podman stop …`).
    StopContainer(StopSpec),
    /// Remove a container (`podman rm …`).
    RemoveContainer(RemoveSpec),
}

/// Spec for [`Op::CreateNetwork`].
#[derive(Debug, Clone, PartialEq)]
pub struct NetworkSpec {
    /// Compose-level network name (un-prefixed).
    pub name: String,
    /// Network driver (e.g. `"bridge"`).
    pub driver: Option<String>,
    /// Labels to apply.
    pub labels: BTreeMap<String, String>,
}

/// Spec for [`Op::CreateVolume`].
#[derive(Debug, Clone, PartialEq)]
pub struct VolumeSpec {
    /// Compose-level volume name (un-prefixed).
    pub name: String,
    /// Volume driver (e.g. `"local"`).
    pub driver: Option<String>,
    /// Labels to apply.
    pub labels: BTreeMap<String, String>,
}

/// Spec for [`Op::BuildImage`].
#[derive(Debug, Clone, PartialEq)]
pub struct BuildSpec {
    /// Service name this build belongs to.
    pub service: String,
    /// Build context directory.
    pub context: std::path::PathBuf,
    /// Path to the Containerfile/Dockerfile relative to the context.
    pub dockerfile: Option<std::path::PathBuf>,
    /// `--build-arg KEY=VAL` entries.
    pub args: BTreeMap<String, String>,
    /// Build target stage (multi-stage builds).
    pub target: Option<String>,
    /// Tag to apply to the built image (e.g. `"burble_server:latest"`).
    pub tag: String,
    /// Pass `--no-cache` to podman build.
    pub no_cache: bool,
}

/// Spec for [`Op::PullImage`].
#[derive(Debug, Clone, PartialEq)]
pub struct PullSpec {
    /// Service name this pull belongs to.
    pub service: String,
    /// Image reference to pull (may include digest).
    pub image: String,
}

/// Spec for [`Op::RunContainer`].
#[derive(Debug, Clone, PartialEq)]
pub struct RunSpec {
    /// Service name.
    pub service: String,
    /// Image to run (either the pull reference or the build tag).
    pub image: String,
    /// Container name (`<project>_<service>`).
    pub container_name: String,
    /// Environment variables (key=value pairs).
    pub environment: Vec<String>,
    /// Port bindings in podman short-form (`"4020:80"`).
    pub ports: Vec<String>,
    /// Volume mount strings.
    pub volumes: Vec<String>,
    /// Networks to attach (empty when `network_mode` is set).
    pub networks: Vec<String>,
    /// Network mode override (e.g. `"host"`).
    pub network_mode: Option<String>,
    /// Command override.
    pub command: Option<Vec<String>>,
    /// Entrypoint override.
    pub entrypoint: Option<Vec<String>>,
    /// Restart policy string (e.g. `"unless-stopped"`).
    pub restart: String,
    /// Labels applied to the container.
    ///
    /// Always includes:
    /// * `io.podman.compose.project=<project>`
    /// * `io.podman.compose.service=<service>`
    /// * `io.podman.compose.config-hash=<sha256>`
    pub labels: BTreeMap<String, String>,
}

/// Spec for [`Op::WaitHealthy`].
#[derive(Debug, Clone, PartialEq)]
pub struct WaitHealthySpec {
    /// Service whose container must become healthy.
    pub service: String,
    /// Expected container name (`<project>_<service>`).
    pub container_name: String,
}

/// Spec for [`Op::StopContainer`].
#[derive(Debug, Clone, PartialEq)]
pub struct StopSpec {
    /// Service name.
    pub service: String,
    /// Container name to stop.
    pub container_name: String,
    /// Grace period in seconds before SIGKILL (0 means immediate).
    pub timeout_secs: u64,
}

/// Spec for [`Op::RemoveContainer`].
#[derive(Debug, Clone, PartialEq)]
pub struct RemoveSpec {
    /// Service name.
    pub service: String,
    /// Container name to remove.
    pub container_name: String,
    /// Pass `--force` to `podman rm`.
    pub force: bool,
}

// ---------------------------------------------------------------------------
// PlanOptions
// ---------------------------------------------------------------------------

/// Options controlling how the planner builds the [`Plan`].
#[derive(Debug, Clone, Default)]
pub struct PlanOptions {
    /// Active profiles.  Services tagged with profiles not in this list are
    /// excluded.  Services with *no* profiles are always included.
    pub profiles: Vec<String>,

    /// Override the project name from `[project].name`.
    pub project_name: Option<String>,

    /// Restrict the plan to these services (and their transitive deps).
    /// Empty means "all services".
    pub services: Vec<String>,
}

// ---------------------------------------------------------------------------
// Plan
// ---------------------------------------------------------------------------

/// The output of [`plan`]: a fully resolved, topologically sorted set of
/// operations ready for the driver to execute.
#[derive(Debug, Clone)]
pub struct Plan {
    /// All operations in the order they should be presented to the driver.
    ///
    /// Ops within the same wave may execute concurrently.
    pub ops: Vec<Op>,

    /// Topological waves.  Each inner `Vec<NodeId>` contains the services
    /// (and their WaitHealthy barriers) that can run concurrently in that wave.
    ///
    /// Network and volume creation ops precede wave 0.
    pub waves: Vec<Vec<NodeId>>,

    /// Resolved project name (from `[project].name` or `PlanOptions::project_name`).
    pub project_name: String,
}

// ---------------------------------------------------------------------------
// PlanError
// ---------------------------------------------------------------------------

/// Errors that the planner can return.
#[derive(Debug, thiserror::Error)]
pub enum PlanError {
    /// A dependency cycle was detected in `depends_on`.
    ///
    /// `path` lists the services that form the cycle, in order.
    #[error("dependency cycle detected: {}", path.join(" → "))]
    Cycle { path: Vec<String> },

    /// A service references another service that does not exist (or was
    /// excluded by profile filtering).
    #[error("service `{from}` depends on unknown service `{to}`")]
    MissingDependency { from: String, to: String },

    /// A service references a named network that is not declared at the
    /// top-level `[networks]` table.
    #[error("service `{service}` references undeclared network `{network}`")]
    UnknownNetwork { service: String, network: String },

    /// A service references a named volume that is not declared at the
    /// top-level `[volumes]` table.  Bind mounts (paths starting with `.` or
    /// `/`) are not subject to this check.
    #[error("service `{service}` references undeclared volume `{volume}`")]
    UnknownVolume { service: String, volume: String },

    /// A profile name was requested via [`PlanOptions::profiles`] but is not
    /// referenced by any service in the compose file.
    #[error("profile `{profile}` is not defined by any service")]
    UnknownProfile { profile: String },

    /// A service name was requested via [`PlanOptions::services`] but is not
    /// present in the compose file.
    #[error("service `{service}` is not defined in the compose file")]
    UnknownService { service: String },

    /// A schema-level parse error was encountered.
    #[error("schema error: {0}")]
    Schema(#[from] selur_compose_schema::ParseError),

    /// An interpolation error occurred during variable expansion.
    #[error("interpolation error: {0}")]
    Interp(#[from] InterpError),
}

// ---------------------------------------------------------------------------
// plan() — the main entry point
// ---------------------------------------------------------------------------

/// Turn a parsed `Compose` into a `Plan`.
///
/// # Errors
///
/// Returns [`PlanError`] when:
/// * A `depends_on` cycle is detected.
/// * A service references a non-existent dependency, network, or volume.
/// * A requested profile or service name is unknown.
///
/// # Example
///
/// ```rust,no_run
/// use selur_compose_schema::parse_str;
/// use selur_compose_plan::{plan, PlanOptions};
///
/// let toml = std::fs::read_to_string("selur-compose.toml").unwrap();
/// let compose = parse_str(&toml, None).unwrap();
/// let opts = PlanOptions::default();
/// let p = plan(&compose, &opts).unwrap();
/// println!("{} wave(s), {} ops", p.waves.len(), p.ops.len());
/// ```
pub fn plan(compose: &Compose, opts: &PlanOptions) -> Result<Plan, PlanError> {
    // 1. Resolve the project name.
    let project_name = opts
        .project_name
        .clone()
        .or_else(|| compose.project.as_ref().map(|p| p.name.clone()))
        .unwrap_or_else(|| "project".to_string());

    // 2. Filter services by profiles.
    let active_services = profiles::filter_services(compose, &opts.profiles)?;

    // 3. Validate service filter list.
    for svc in &opts.services {
        if !active_services.contains_key(svc.as_str()) {
            return Err(PlanError::UnknownService {
                service: svc.clone(),
            });
        }
    }

    // 4. Validate cross-references: networks and volumes.
    validate_references(compose, &active_services)?;

    // 5. Build the dependency graph.
    let graph = dag::build_graph(&active_services)?;

    // 6. Topological sort → waves.
    let service_waves = dag::topological_waves(&graph, &active_services)?;

    // 7. Collect network and volume ops (these run before wave 0).
    let mut ops: Vec<Op> = Vec::new();

    for (net_name, net) in &compose.networks {
        let mut labels = BTreeMap::new();
        labels.insert(
            "io.podman.compose.project".to_string(),
            project_name.clone(),
        );
        ops.push(Op::CreateNetwork(NetworkSpec {
            name: net_name.clone(),
            driver: net.driver.clone(),
            labels,
        }));
    }

    for (vol_name, vol) in &compose.volumes {
        let mut labels = BTreeMap::new();
        labels.insert(
            "io.podman.compose.project".to_string(),
            project_name.clone(),
        );
        ops.push(Op::CreateVolume(VolumeSpec {
            name: vol_name.clone(),
            driver: vol.driver.clone(),
            labels,
        }));
    }

    // 8. Build/pull ops (before containers run, independent of wave order).
    for (svc_name, svc) in &active_services {
        if let Some(build) = &svc.build {
            let tag = format!("{}_{svc_name}:latest", project_name);
            ops.push(Op::BuildImage(BuildSpec {
                service: svc_name.to_string(),
                context: build.context.clone(),
                dockerfile: build.dockerfile.clone(),
                args: build.args.clone(),
                target: build.target.clone(),
                tag,
                no_cache: build.no_cache,
            }));
        } else if let Some(image) = &svc.image {
            ops.push(Op::PullImage(PullSpec {
                service: svc_name.to_string(),
                image: image.clone(),
            }));
        }
    }

    // 9. Wave ops — RunContainer + WaitHealthy barriers.
    //    Track which services we've already emitted a WaitHealthy for.
    let mut wait_healthy_emitted: std::collections::HashSet<String> =
        std::collections::HashSet::new();

    let mut node_wave_index: Vec<Vec<NodeId>> = Vec::new();

    for wave in &service_waves {
        let mut wave_node_ids: Vec<NodeId> = Vec::new();

        // Determine which services in *previous* waves need WaitHealthy before
        // this wave can start.  A WaitHealthy is needed when any service in this
        // wave depends on a predecessor with condition=service_healthy.
        for &node_id in wave {
            let svc_name = graph.name(node_id);
            let svc = &active_services[svc_name];

            // Check all this service's depends_on entries for healthy conditions.
            let healthy_deps = dag::healthy_dependencies(svc);
            for dep_name in &healthy_deps {
                if !wait_healthy_emitted.contains(dep_name.as_str()) {
                    let container_name = format!("{project_name}_{dep_name}");
                    ops.push(Op::WaitHealthy(WaitHealthySpec {
                        service: dep_name.clone(),
                        container_name,
                    }));
                    wait_healthy_emitted.insert(dep_name.clone());
                }
            }
        }

        for &node_id in wave {
            let svc_name = graph.name(node_id);
            let svc = &active_services[svc_name];

            // Config hash
            let config_hash = hash::service_hash(svc);

            // Determine image: built tag or explicit image.
            let image = if svc.build.is_some() {
                format!("{project_name}_{svc_name}:latest")
            } else {
                svc.image.clone().unwrap_or_default()
            };

            let container_name = format!("{project_name}_{svc_name}");

            // Build labels.
            let mut labels = BTreeMap::new();
            labels.insert(
                "io.podman.compose.project".to_string(),
                project_name.clone(),
            );
            labels.insert(
                "io.podman.compose.service".to_string(),
                svc_name.to_string(),
            );
            labels.insert(
                "io.podman.compose.config-hash".to_string(),
                config_hash,
            );

            // Environment variables.
            let environment = match &svc.environment {
                selur_compose_schema::EnvMap::Empty => vec![],
                selur_compose_schema::EnvMap::List(l) => l.clone(),
                selur_compose_schema::EnvMap::Map(m) => m
                    .iter()
                    .map(|(k, v)| match v {
                        Some(val) => format!("{k}={val}"),
                        None => k.clone(),
                    })
                    .collect(),
            };

            // Port bindings — use short string form.
            let ports: Vec<String> = svc
                .ports
                .iter()
                .map(|p| match p {
                    selur_compose_schema::PortBinding::Short(s) => s.clone(),
                    selur_compose_schema::PortBinding::Long(l) => {
                        // Reconstruct a short-form string from the struct.
                        let proto = l.protocol.as_deref().unwrap_or("tcp");
                        match (&l.host_ip, &l.published) {
                            (Some(ip), Some(pub_port)) => {
                                format!("{ip}:{pub_port}:{}/{proto}", l.target)
                            }
                            (None, Some(pub_port)) => {
                                format!("{pub_port}:{}/{proto}", l.target)
                            }
                            _ => format!("{}/{proto}", l.target),
                        }
                    }
                })
                .collect();

            // Volume mounts — use short string form.
            let volumes: Vec<String> = svc
                .volumes
                .iter()
                .map(|v| match v {
                    selur_compose_schema::MountSpec::Short(s) => s.clone(),
                    selur_compose_schema::MountSpec::Long(l) => {
                        let src = l.source.as_ref().map(|p| p.display().to_string()).unwrap_or_default();
                        let tgt = l.target.display().to_string();
                        if l.read_only {
                            format!("{src}:{tgt}:ro")
                        } else {
                            format!("{src}:{tgt}")
                        }
                    }
                })
                .collect();

            // Network mode or network list.
            let network_mode = svc.network_mode.as_ref().map(|nm| {
                use selur_compose_schema::NetworkMode;
                match nm {
                    NetworkMode::Bridge => "bridge".to_string(),
                    NetworkMode::Host => "host".to_string(),
                    NetworkMode::None => "none".to_string(),
                    NetworkMode::Container(id) => format!("container:{id}"),
                    NetworkMode::Custom(s) => s.clone(),
                }
            });
            let networks = if network_mode.is_some() {
                vec![]
            } else {
                svc.networks.clone()
            };

            // Command and entrypoint — normalise to Vec<String>.
            let command = svc.command.as_ref().map(|c| match c {
                selur_compose_schema::StringOrList::String(s) => vec![s.clone()],
                selur_compose_schema::StringOrList::List(l) => l.clone(),
            });
            let entrypoint = svc.entrypoint.as_ref().map(|e| match e {
                selur_compose_schema::StringOrList::String(s) => vec![s.clone()],
                selur_compose_schema::StringOrList::List(l) => l.clone(),
            });

            // Restart policy string.
            let restart = match &svc.restart {
                selur_compose_schema::RestartPolicy::No => "no".to_string(),
                selur_compose_schema::RestartPolicy::Always => "always".to_string(),
                selur_compose_schema::RestartPolicy::OnFailure => "on-failure".to_string(),
                selur_compose_schema::RestartPolicy::UnlessStopped => "unless-stopped".to_string(),
            };

            ops.push(Op::RunContainer(RunSpec {
                service: svc_name.to_string(),
                image,
                container_name,
                environment,
                ports,
                volumes,
                networks,
                network_mode,
                command,
                entrypoint,
                restart,
                labels,
            }));

            wave_node_ids.push(node_id);
        }

        node_wave_index.push(wave_node_ids);
    }

    Ok(Plan {
        ops,
        waves: node_wave_index,
        project_name,
    })
}

// ---------------------------------------------------------------------------
// validate_references — check network/volume references
// ---------------------------------------------------------------------------

fn validate_references(
    compose: &Compose,
    active_services: &std::collections::BTreeMap<&str, &selur_compose_schema::Service>,
) -> Result<(), PlanError> {
    // Compose implicitly creates a `default` network when no `[networks]` table
    // is declared.  A service referencing `"default"` when the compose has no
    // explicit networks section is valid (compose semantics).
    let has_explicit_networks = !compose.networks.is_empty();

    for (&svc_name, svc) in active_services {
        // Validate named networks.
        for net in &svc.networks {
            // "default" is always allowed — it is the implicit compose network.
            if net == "default" {
                continue;
            }
            // If no explicit [networks] section exists, only "default" is valid.
            // If an explicit section exists, the named network must be declared.
            if has_explicit_networks && !compose.networks.contains_key(net) {
                return Err(PlanError::UnknownNetwork {
                    service: svc_name.to_string(),
                    network: net.clone(),
                });
            }
            if !has_explicit_networks && net != "default" {
                return Err(PlanError::UnknownNetwork {
                    service: svc_name.to_string(),
                    network: net.clone(),
                });
            }
        }

        // Validate named volumes (bind mounts start with '.' or '/').
        for mount in &svc.volumes {
            if let selur_compose_schema::MountSpec::Short(s) = mount {
                let source = s.splitn(2, ':').next().unwrap_or("");
                let is_bind = source.starts_with('.') || source.starts_with('/');
                if !is_bind && !compose.volumes.contains_key(source) {
                    return Err(PlanError::UnknownVolume {
                        service: svc_name.to_string(),
                        volume: source.to_string(),
                    });
                }
            }
            // Long-form mounts with type="volume" and a source name are also checked.
            if let selur_compose_schema::MountSpec::Long(l) = mount {
                if l.mount_type == "volume" {
                    if let Some(src) = &l.source {
                        let src_str = src.display().to_string();
                        if !compose.volumes.contains_key(&src_str) {
                            return Err(PlanError::UnknownVolume {
                                service: svc_name.to_string(),
                                volume: src_str,
                            });
                        }
                    }
                }
            }
        }
    }
    Ok(())
}
