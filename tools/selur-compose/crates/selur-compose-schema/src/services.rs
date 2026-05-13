//! `[services]` — service definitions.

use std::{collections::BTreeMap, path::PathBuf};

use serde::{Deserialize, Serialize};

use crate::{
    build::Build,
    depends_on::DependsOn,
    healthcheck::Healthcheck,
    networks::NetworkMode,
    ports::PortBinding,
    secrets::{ConfigRef, SecretRef},
    volumes::MountSpec,
};

/// A single service definition.
///
/// Uses `#[serde(deny_unknown_fields)]` so typos fail loudly at parse time.
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Service {
    /// Container image reference.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image: Option<String>,

    /// Image build configuration.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub build: Option<Build>,

    /// Command to run inside the container.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<StringOrList>,

    /// Override the image's entrypoint.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub entrypoint: Option<StringOrList>,

    /// Environment variables: list form `["KEY=VAL"]` or map form `{KEY="VAL"}`.
    #[serde(default, skip_serializing_if = "EnvMap::is_empty")]
    pub environment: EnvMap,

    /// Paths to `.env`-format files to inject into the container.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub env_file: Vec<PathBuf>,

    /// Port bindings.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub ports: Vec<PortBinding>,

    /// Volume mounts.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub volumes: Vec<MountSpec>,

    /// Named networks this service connects to.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub networks: Vec<String>,

    /// Override the network driver entirely (e.g. `"host"`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub network_mode: Option<NetworkMode>,

    /// Services that must start (or become healthy) before this one.
    #[serde(default, skip_serializing_if = "DependsOn::is_empty")]
    pub depends_on: DependsOn,

    /// Container health probe.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub healthcheck: Option<Healthcheck>,

    /// Container restart policy.
    #[serde(default)]
    pub restart: RestartPolicy,

    /// Named profiles this service belongs to.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub profiles: Vec<String>,

    /// Secrets mounted into the container.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub secrets: Vec<SecretRef>,

    /// Configs mounted into the container.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub configs: Vec<ConfigRef>,

    /// Run as this user inside the container.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub user: Option<String>,

    /// Override the working directory.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub working_dir: Option<String>,

    /// Container hostname.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hostname: Option<String>,

    /// Linux capabilities to add.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub cap_add: Vec<String>,

    /// Linux capabilities to drop.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub cap_drop: Vec<String>,

    /// Run an init process as PID 1.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub init: Option<bool>,

    /// Signal to send to stop the container (default: `SIGTERM`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stop_signal: Option<String>,

    /// Time to wait for the container to stop before killing it.
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        with = "crate::healthcheck::opt_duration"
    )]
    pub stop_grace_period: Option<std::time::Duration>,
}

// ---------------------------------------------------------------------------
// RestartPolicy
// ---------------------------------------------------------------------------

/// Container restart policy.
///
/// ```toml
/// restart = "unless-stopped"   # → RestartPolicy::UnlessStopped
/// restart = "always"           # → RestartPolicy::Always
/// restart = "on-failure"       # → RestartPolicy::OnFailure { max_retries: None }
/// ```
///
/// Uses `#[serde(rename_all = "kebab-case")]` so `UnlessStopped` ↔ `"unless-stopped"`.
#[derive(Debug, Clone, PartialEq, Default, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum RestartPolicy {
    /// Do not restart. This is the default.
    #[default]
    No,
    /// Always restart the container.
    Always,
    /// Restart on non-zero exit code; optionally limit retries.
    OnFailure,
    /// Restart unless the container was explicitly stopped.
    UnlessStopped,
}

// ---------------------------------------------------------------------------
// EnvMap
// ---------------------------------------------------------------------------

/// Environment variable block — two forms accepted:
///
/// ```toml
/// # List form (what burble uses):
/// environment = ["KEY=VAL", "OTHER=VAL2"]
///
/// # Map form:
/// environment = { KEY = "VAL", OTHER = "VAL2" }
/// ```
#[derive(Debug, Clone, PartialEq, Default, Deserialize, Serialize)]
#[serde(untagged)]
pub enum EnvMap {
    /// No environment variables.
    #[default]
    Empty,
    /// `["KEY=VAL"]` list.
    List(Vec<String>),
    /// `{KEY = "VAL"}` map with optional values (bare `KEY` means inherit from environment).
    Map(BTreeMap<String, Option<String>>),
}

impl EnvMap {
    /// Returns `true` when there are no environment entries.
    ///
    /// Used as the `skip_serializing_if` predicate so that the `Empty` variant
    /// (a unit variant in an untagged enum) is never written to TOML — the TOML
    /// serialiser cannot represent bare unit variants as values.
    pub fn is_empty(&self) -> bool {
        matches!(self, EnvMap::Empty)
    }
}

// ---------------------------------------------------------------------------
// StringOrList
// ---------------------------------------------------------------------------

/// A value that is either a single string or an array of strings.
///
/// Used for `command` and `entrypoint`.
///
/// ```toml
/// command = "nginx -g 'daemon off;'"          # → String
/// entrypoint = ["/bin/sh", "-c"]              # → List
/// ```
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
#[serde(untagged)]
pub enum StringOrList {
    /// Single shell string.
    String(String),
    /// Exec-form array.
    List(Vec<String>),
}
