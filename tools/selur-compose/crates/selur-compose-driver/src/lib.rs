//! Podman CLI driver for selur-compose.
//!
//! This crate provides:
//!
//! - The [`Driver`] async trait — the public contract that consumers program against.
//! - [`PodmanCli`] — production implementation that shells out to `podman`.
//! - [`MockDriver`] — test double that records calls and returns configurable canned responses.
//! - [`executor::execute`] — walks a [`Plan`] in topological waves, firing concurrent tasks.
//! - [`logs::tail_logs`] — multiplexes per-service log streams.
//!
//! # Type hierarchy
//!
//! ```text
//!   selur_compose_plan::Plan
//!          │  (re-exported spec types)
//!          ▼
//!   Driver trait ──► PodmanCli (production)
//!                └─► MockDriver  (testing)
//! ```

use std::time::Duration;

use async_trait::async_trait;
use tokio::io::AsyncRead;

// Re-export plan types that the driver layer (and its consumers) need directly.
pub use selur_compose_plan::{
    BuildSpec, NetworkSpec, PullSpec, RemoveSpec, RunSpec, StopSpec, VolumeSpec, WaitHealthySpec,
};

pub mod argv;
pub mod exec;
pub mod executor;
pub mod healthcheck;
pub mod logs;
pub mod mock;
pub mod podman;

// ---------------------------------------------------------------------------
// Newtype wrappers returned by Driver methods
// ---------------------------------------------------------------------------

/// An image identifier returned by [`Driver::build`] or [`Driver::pull`].
///
/// Contains the full image ID string as reported by podman (sha256 digest or
/// short-form tag reference).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ImageId(pub String);

impl std::fmt::Display for ImageId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

/// A container identifier returned by [`Driver::run`].
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ContainerId(pub String);

impl std::fmt::Display for ContainerId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

// ---------------------------------------------------------------------------
// ContainerState — parsed from `podman inspect`
// ---------------------------------------------------------------------------

/// Health status as reported by podman's built-in healthcheck scheduler.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HealthStatus {
    /// The container is healthy.
    Healthy,
    /// One or more probes have failed; not yet at the retry limit.
    Starting,
    /// The container is unhealthy (failed `retries` consecutive probes).
    Unhealthy,
    /// No healthcheck is configured.
    None,
    /// An unexpected status string was returned.
    Unknown(String),
}

impl From<&str> for HealthStatus {
    fn from(s: &str) -> Self {
        match s {
            "healthy"   => Self::Healthy,
            "unhealthy" => Self::Unhealthy,
            "starting"  => Self::Starting,
            "none"      => Self::None,
            other       => Self::Unknown(other.to_string()),
        }
    }
}

/// The health-probe snapshot as reported by `podman inspect --format json`.
#[derive(Debug, Clone, PartialEq)]
pub struct HealthState {
    /// The current health status.
    pub status: HealthStatus,
    /// Number of consecutive failures since the last successful probe.
    pub failing_streak: u32,
}

/// The full container inspection result (subset relevant to the driver).
#[derive(Debug, Clone, PartialEq)]
pub struct ContainerState {
    /// Container name.
    pub name: String,
    /// OCI state (`"running"`, `"exited"`, `"created"`, …).
    pub status: String,
    /// PID of the container's init process (0 if not running).
    pub pid: u32,
    /// Exit code when the container has stopped.
    pub exit_code: i32,
    /// Health probe state, if the container has a healthcheck.
    pub health: Option<HealthState>,
}

// ---------------------------------------------------------------------------
// LogStream
// ---------------------------------------------------------------------------

/// A streaming source of log lines from a container.
///
/// The concrete type is a boxed `AsyncRead` so the driver impl can return any
/// readable without the trait needing to know the concrete stream type.
pub type LogStream = Box<dyn AsyncRead + Send + Unpin + 'static>;

// ---------------------------------------------------------------------------
// ContainerSummary — returned by Driver::ps
// ---------------------------------------------------------------------------

/// A row in the output of `podman ps --format json` (pruned to the fields we care about).
#[derive(Debug, Clone, PartialEq)]
pub struct ContainerSummary {
    /// Container ID (short form).
    pub id: String,
    /// Container name.
    pub name: String,
    /// Image tag.
    pub image: String,
    /// State string (e.g. `"running"`, `"exited"`).
    pub state: String,
    /// Port bindings as display strings.
    pub ports: Vec<String>,
    /// The compose service label (`io.podman.compose.service`).
    pub service: Option<String>,
}

// ---------------------------------------------------------------------------
// DriverError
// ---------------------------------------------------------------------------

/// Errors returned by [`Driver`] methods.
#[derive(Debug, thiserror::Error)]
pub enum DriverError {
    /// podman exited with a non-zero exit code.
    #[error("podman exited {code}: {stderr}\n  argv: {argv:?}")]
    Podman {
        /// The full argument vector that was passed to podman.
        argv: Vec<String>,
        /// The exit code.
        code: i32,
        /// Standard error output from the process.
        stderr: String,
    },

    /// A service container did not become healthy within the timeout window.
    #[error("service `{service}` did not become healthy within {timeout:?}")]
    HealthcheckTimeout {
        /// The service name.
        service: String,
        /// The total timeout that was applied.
        timeout: Duration,
    },

    /// The container reported `unhealthy` during the health-poll loop.
    #[error("service `{service}` is unhealthy (failing streak: {streak})")]
    Unhealthy {
        /// The service name.
        service: String,
        /// Consecutive failures at the time the error was returned.
        streak: u32,
    },

    /// A port binding was refused because the port is below 1024 and the
    /// process is rootless.  Includes a sysctl hint.
    #[error(
        "service `{service}` tried to bind privileged port {port}: \
         run `sudo sysctl net.ipv4.ip_unprivileged_port_start={port}` \
         to allow rootless binding, or use a port ≥ 1024"
    )]
    PrivilegedPort {
        /// The service that attempted the bind.
        service: String,
        /// The port number.
        port: u16,
    },

    /// An I/O error communicating with the podman subprocess.
    #[error("I/O error communicating with podman: {0}")]
    Io(#[from] std::io::Error),

    /// JSON parsing failed on a podman `--format json` response.
    #[error("failed to parse podman JSON output: {0}")]
    Json(#[from] serde_json::Error),
}

/// Convenience alias.
pub type Result<T, E = DriverError> = std::result::Result<T, E>;

// ---------------------------------------------------------------------------
// Driver — the async trait
// ---------------------------------------------------------------------------

/// The core driver contract.
///
/// Every method maps 1-to-1 to a `podman` subcommand.  Production code uses
/// [`PodmanCli`]; tests use [`MockDriver`].
///
/// # Object safety
///
/// This trait is object-safe via `#[async_trait]`.  You can store a
/// `Box<dyn Driver>` and dispatch dynamically, which is what [`executor::execute`]
/// does.
///
/// # Design §5 (verbatim)
///
/// ```rust,ignore
/// #[async_trait::async_trait]
/// pub trait Driver: Send + Sync {
///     async fn build(&self,  spec: &BuildSpec)   -> Result<ImageId>;
///     async fn pull(&self,   image: &str)        -> Result<ImageId>;
///     async fn create_network(&self, n: &NetworkSpec) -> Result<()>;
///     async fn create_volume(&self,  v: &VolumeSpec)  -> Result<()>;
///     async fn run(&self,    spec: &RunSpec)     -> Result<ContainerId>;
///     async fn inspect(&self, id: &ContainerId)  -> Result<ContainerState>;
///     async fn healthcheck_run(&self, id: &ContainerId) -> Result<HealthState>;
///     async fn stop(&self,    id: &ContainerId, grace: Duration) -> Result<()>;
///     async fn rm(&self,      id: &ContainerId, force: bool)     -> Result<()>;
///     async fn logs(&self,    id: &ContainerId, follow: bool)    -> Result<LogStream>;
///     async fn ps(&self,      project: &str)     -> Result<Vec<ContainerSummary>>;
/// }
/// ```
#[async_trait]
pub trait Driver: Send + Sync {
    /// Build an image from source using `podman build`.
    ///
    /// Returns the fully-qualified image ID of the built image.
    async fn build(&self, spec: &BuildSpec) -> Result<ImageId>;

    /// Pull an image from a registry using `podman pull`.
    ///
    /// Returns the image ID of the pulled image.
    async fn pull(&self, image: &str) -> Result<ImageId>;

    /// Ensure a named network exists (`podman network create`).
    ///
    /// Idempotent: if the network already exists the call succeeds silently.
    async fn create_network(&self, n: &NetworkSpec) -> Result<()>;

    /// Ensure a named volume exists (`podman volume create`).
    ///
    /// Idempotent: if the volume already exists the call succeeds silently.
    async fn create_volume(&self, v: &VolumeSpec) -> Result<()>;

    /// Start a container (`podman run --detach`).
    ///
    /// Returns the container ID of the new container.
    async fn run(&self, spec: &RunSpec) -> Result<ContainerId>;

    /// Inspect a running or stopped container (`podman inspect --format json`).
    async fn inspect(&self, id: &ContainerId) -> Result<ContainerState>;

    /// Run the container's health probe once on demand (`podman healthcheck run`).
    ///
    /// This is used as a fallback when the built-in scheduler hasn't yet
    /// started reporting (e.g. within `--health-start-period`).
    async fn healthcheck_run(&self, id: &ContainerId) -> Result<HealthState>;

    /// Stop a running container (`podman stop --time <grace>`).
    async fn stop(&self, id: &ContainerId, grace: Duration) -> Result<()>;

    /// Remove a container (`podman rm [--force]`).
    async fn rm(&self, id: &ContainerId, force: bool) -> Result<()>;

    /// Tail or stream logs from a container (`podman logs [--follow]`).
    ///
    /// Returns an [`AsyncRead`](tokio::io::AsyncRead) over the combined
    /// stdout+stderr stream with `--timestamps`.
    async fn logs(&self, id: &ContainerId, follow: bool) -> Result<LogStream>;

    /// List containers belonging to `project` (`podman ps --filter label=…`).
    async fn ps(&self, project: &str) -> Result<Vec<ContainerSummary>>;
}
