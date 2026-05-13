//! Production `Driver` implementation: [`PodmanCli`].
//!
//! Each method composes an argv via [`crate::argv`], runs it via
//! [`crate::exec::run_podman`], and parses any JSON output through the
//! [`PodmanV5Adapter`] shims defined at the bottom of this file.

use std::time::Duration;

use async_trait::async_trait;
use serde::Deserialize;
use tokio::process::Command;

use selur_compose_plan::{BuildSpec, NetworkSpec, RunSpec, VolumeSpec};

use crate::{
    argv,
    exec::{detect_privileged_port, run_podman},
    ContainerId, ContainerState, ContainerSummary, Driver, DriverError, HealthState, HealthStatus,
    ImageId, LogStream, Result,
};

// ---------------------------------------------------------------------------
// PodmanCli — production Driver impl
// ---------------------------------------------------------------------------

/// The production [`Driver`] implementation.
///
/// Shells out to `podman` for every operation.  All JSON output is parsed
/// through the [`PodmanV5Adapter`] shims which use `#[serde(default)]` to
/// tolerate schema churn across podman point-releases.
pub struct PodmanCli {
    /// The podman binary path (default: `"podman"`).
    pub binary: String,
}

impl Default for PodmanCli {
    fn default() -> Self {
        Self { binary: "podman".to_string() }
    }
}

impl PodmanCli {
    /// Create a new [`PodmanCli`] using the default `podman` binary.
    pub fn new() -> Self {
        Self::default()
    }

    /// Create a [`PodmanCli`] with a custom binary path.
    pub fn with_binary(binary: impl Into<String>) -> Self {
        Self { binary: binary.into() }
    }

    /// Replace `"podman"` in `argv[0]` with `self.binary` when it differs.
    fn patch_argv(&self, mut argv: Vec<String>) -> Vec<String> {
        if let Some(first) = argv.first_mut() {
            *first = self.binary.clone();
        }
        argv
    }
}

#[async_trait]
impl Driver for PodmanCli {
    async fn build(&self, spec: &BuildSpec) -> Result<ImageId> {
        let argv = self.patch_argv(argv::build_argv(spec));
        let out = run_podman(&argv).await?;
        // `podman build` prints the image ID on the last non-empty line of stdout.
        let id = String::from_utf8_lossy(&out.stdout)
            .lines()
            .filter(|l| !l.is_empty())
            .last()
            .unwrap_or_default()
            .trim()
            .to_string();
        Ok(ImageId(id))
    }

    async fn pull(&self, image: &str) -> Result<ImageId> {
        let argv = self.patch_argv(argv::pull_argv(image));
        let out = run_podman(&argv).await?;
        let id = String::from_utf8_lossy(&out.stdout).trim().to_string();
        Ok(ImageId(id))
    }

    async fn create_network(&self, n: &NetworkSpec) -> Result<()> {
        let argv = self.patch_argv(argv::network_create_argv(n));
        // Ignore "already exists" errors — idempotent.
        match run_podman(&argv).await {
            Ok(_) => Ok(()),
            Err(DriverError::Podman { ref stderr, .. }) if stderr.contains("already exists") => {
                Ok(())
            }
            Err(e) => Err(e),
        }
    }

    async fn create_volume(&self, v: &VolumeSpec) -> Result<()> {
        let argv = self.patch_argv(argv::volume_create_argv(v));
        match run_podman(&argv).await {
            Ok(_) => Ok(()),
            Err(DriverError::Podman { ref stderr, .. }) if stderr.contains("already exists") => {
                Ok(())
            }
            Err(e) => Err(e),
        }
    }

    async fn run(&self, spec: &RunSpec) -> Result<ContainerId> {
        let argv = self.patch_argv(argv::run_argv(spec));
        let result = run_podman(&argv).await;
        match result {
            Ok(out) => {
                let id = String::from_utf8_lossy(&out.stdout).trim().to_string();
                Ok(ContainerId(id))
            }
            Err(DriverError::Podman { ref stderr, ref argv, code }) => {
                // EACCES privileged-port detection (task 4.10).
                if let Some(port) = detect_privileged_port(stderr) {
                    return Err(DriverError::PrivilegedPort {
                        service: spec.service.clone(),
                        port,
                    });
                }
                Err(DriverError::Podman {
                    argv: argv.clone(),
                    code,
                    stderr: stderr.clone(),
                })
            }
            Err(e) => Err(e),
        }
    }

    async fn inspect(&self, id: &ContainerId) -> Result<ContainerState> {
        let argv = self.patch_argv(argv::inspect_argv(&id.0));
        let out = run_podman(&argv).await?;
        let json = String::from_utf8_lossy(&out.stdout);
        // `podman inspect` returns a JSON array; we take the first element.
        let items: Vec<PodmanContainerJson> = serde_json::from_str(&json)?;
        let item = items.into_iter().next().ok_or_else(|| {
            DriverError::Podman {
                argv: argv.clone(),
                code: 0,
                stderr: "empty inspect response".to_string(),
            }
        })?;
        Ok(item.into_container_state())
    }

    async fn healthcheck_run(&self, id: &ContainerId) -> Result<HealthState> {
        let argv = self.patch_argv(argv::healthcheck_run_argv(&id.0));
        // `podman healthcheck run` exits 0 if healthy, 1 if unhealthy.
        // We re-inspect the container afterwards for the full HealthState.
        let _ = run_podman(&argv).await;
        // Re-inspect to read the updated health state.
        let state = self.inspect(id).await?;
        Ok(state.health.unwrap_or(HealthState {
            status: HealthStatus::None,
            failing_streak: 0,
        }))
    }

    async fn stop(&self, id: &ContainerId, grace: Duration) -> Result<()> {
        let argv = self.patch_argv(argv::stop_argv(&id.0, grace.as_secs()));
        run_podman(&argv).await?;
        Ok(())
    }

    async fn rm(&self, id: &ContainerId, force: bool) -> Result<()> {
        let argv = self.patch_argv(argv::rm_argv(&id.0, force));
        // Ignore "no such container" — rm is idempotent.
        match run_podman(&argv).await {
            Ok(_) => Ok(()),
            Err(DriverError::Podman { ref stderr, .. })
                if stderr.contains("no such container")
                    || stderr.contains("No such container") =>
            {
                Ok(())
            }
            Err(e) => Err(e),
        }
    }

    async fn logs(&self, id: &ContainerId, follow: bool) -> Result<LogStream> {
        let argv = self.patch_argv(argv::logs_argv(&id.0, follow));
        // Spawn the process and return its combined stdout+stderr as an AsyncRead.
        let mut cmd = Command::new(&argv[0]);
        cmd.args(&argv[1..]);
        // Merge stdout and stderr into stdout for unified log stream.
        cmd.stdout(std::process::Stdio::piped());
        cmd.stderr(std::process::Stdio::piped());

        let mut child = cmd.spawn().map_err(DriverError::Io)?;
        // Use stdout only (podman logs writes to stdout by default for non-tty).
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| DriverError::Io(std::io::Error::other("no stdout on child")))?;
        Ok(Box::new(stdout))
    }

    async fn ps(&self, project: &str) -> Result<Vec<ContainerSummary>> {
        let argv = self.patch_argv(argv::ps_argv(project));
        let out = run_podman(&argv).await?;
        let json = String::from_utf8_lossy(&out.stdout);
        if json.trim().is_empty() || json.trim() == "null" {
            return Ok(vec![]);
        }
        let items: Vec<PodmanPsJson> = serde_json::from_str(&json)?;
        Ok(items.into_iter().map(|i| i.into_summary()).collect())
    }
}

// ---------------------------------------------------------------------------
// PodmanV5Adapter — JSON shims (task 4.9)
//
// These structs use #[serde(default)] and #[serde(rename)] aggressively so
// that we tolerate field additions / renames across podman point-releases.
// ---------------------------------------------------------------------------

/// Minimal deserialization target for `podman inspect --format json`.
///
/// Only the fields we actually use are listed; everything else is silently
/// ignored via the absence of `#[serde(deny_unknown_fields)]`.
#[derive(Debug, Deserialize)]
pub struct PodmanContainerJson {
    #[serde(default, rename = "Name")]
    pub name: String,

    #[serde(default, rename = "State")]
    pub state: PodmanStateJson,
}

/// The nested `State` object inside a `podman inspect` JSON item.
#[derive(Debug, Deserialize, Default)]
pub struct PodmanStateJson {
    #[serde(default, rename = "Status")]
    pub status: String,

    #[serde(default, rename = "Pid")]
    pub pid: u32,

    #[serde(default, rename = "ExitCode")]
    pub exit_code: i32,

    #[serde(default, rename = "Health")]
    pub health: Option<PodmanHealthJson>,
}

/// The nested `Health` object inside `State`.
#[derive(Debug, Deserialize, Default)]
pub struct PodmanHealthJson {
    #[serde(default, rename = "Status")]
    pub status: String,

    #[serde(default, rename = "FailingStreak")]
    pub failing_streak: u32,
}

impl PodmanContainerJson {
    /// Convert into our domain [`ContainerState`].
    pub fn into_container_state(self) -> ContainerState {
        let health = self.state.health.map(|h| HealthState {
            status: HealthStatus::from(h.status.as_str()),
            failing_streak: h.failing_streak,
        });
        ContainerState {
            name: self.name,
            status: self.state.status,
            pid: self.state.pid,
            exit_code: self.state.exit_code,
            health,
        }
    }
}

/// Minimal deserialization target for `podman ps --format json`.
#[derive(Debug, Deserialize)]
pub struct PodmanPsJson {
    #[serde(default, rename = "Id")]
    pub id: String,

    #[serde(default, rename = "Names")]
    pub names: Vec<String>,

    #[serde(default, rename = "Image")]
    pub image: String,

    #[serde(default, rename = "State")]
    pub state: String,

    #[serde(default, rename = "Ports")]
    pub ports: Option<Vec<PodmanPortJson>>,

    #[serde(default, rename = "Labels")]
    pub labels: std::collections::HashMap<String, String>,
}

/// A port mapping entry in `podman ps --format json`.
#[derive(Debug, Deserialize, Default)]
pub struct PodmanPortJson {
    #[serde(default, rename = "host_ip")]
    pub host_ip: String,

    #[serde(default, rename = "container_port")]
    pub container_port: u16,

    #[serde(default, rename = "host_port")]
    pub host_port: u16,

    #[serde(default, rename = "protocol")]
    pub protocol: String,
}

impl PodmanPsJson {
    /// Convert into our domain [`ContainerSummary`].
    pub fn into_summary(self) -> ContainerSummary {
        let name = self.names.into_iter().next().unwrap_or_default();
        let ports: Vec<String> = self
            .ports
            .unwrap_or_default()
            .into_iter()
            .map(|p| {
                if p.host_ip.is_empty() {
                    format!("{}:{}/{}", p.host_port, p.container_port, p.protocol)
                } else {
                    format!("{}:{}:{}/{}", p.host_ip, p.host_port, p.container_port, p.protocol)
                }
            })
            .collect();
        let service = self
            .labels
            .get("io.podman.compose.service")
            .cloned();
        ContainerSummary {
            id: self.id,
            name,
            image: self.image,
            state: self.state,
            ports,
            service,
        }
    }
}

// ---------------------------------------------------------------------------
// Unit tests (no live podman)
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_inspect_json_parse() {
        let json = r#"[{
            "Name": "burble_server",
            "State": {
                "Status": "running",
                "Pid": 1234,
                "ExitCode": 0,
                "Health": {
                    "Status": "healthy",
                    "FailingStreak": 0
                }
            }
        }]"#;
        let items: Vec<PodmanContainerJson> = serde_json::from_str(json).unwrap();
        let state = items.into_iter().next().unwrap().into_container_state();
        assert_eq!(state.name, "burble_server");
        assert_eq!(state.status, "running");
        assert_eq!(state.health.as_ref().unwrap().status, HealthStatus::Healthy);
        assert_eq!(state.health.unwrap().failing_streak, 0);
    }

    #[test]
    fn test_inspect_json_parse_no_health() {
        let json = r#"[{
            "Name": "mycontainer",
            "State": {
                "Status": "exited",
                "Pid": 0,
                "ExitCode": 137
            }
        }]"#;
        let items: Vec<PodmanContainerJson> = serde_json::from_str(json).unwrap();
        let state = items.into_iter().next().unwrap().into_container_state();
        assert_eq!(state.exit_code, 137);
        assert!(state.health.is_none());
    }

    #[test]
    fn test_inspect_json_tolerates_unknown_fields() {
        // Extra fields that podman might add in future versions.
        let json = r#"[{
            "Name": "c1",
            "FutureField": "ignored",
            "State": {
                "Status": "running",
                "Pid": 42,
                "ExitCode": 0,
                "NewField2030": true
            }
        }]"#;
        let result: Result<Vec<PodmanContainerJson>, _> = serde_json::from_str(json);
        assert!(result.is_ok(), "should tolerate unknown fields: {result:?}");
    }

    #[test]
    fn test_ps_json_parse() {
        let json = r#"[{
            "Id": "abc123def456",
            "Names": ["burble_web"],
            "Image": "burble_web:latest",
            "State": "running",
            "Ports": [
                {
                    "host_ip": "",
                    "container_port": 80,
                    "host_port": 4020,
                    "protocol": "tcp"
                }
            ],
            "Labels": {
                "io.podman.compose.project": "burble",
                "io.podman.compose.service": "web"
            }
        }]"#;
        let items: Vec<PodmanPsJson> = serde_json::from_str(json).unwrap();
        let summary = items.into_iter().next().unwrap().into_summary();
        assert_eq!(summary.id, "abc123def456");
        assert_eq!(summary.name, "burble_web");
        assert_eq!(summary.state, "running");
        assert_eq!(summary.service.as_deref(), Some("web"));
        assert!(summary.ports[0].contains("4020"));
    }

    #[test]
    fn test_ps_empty_json() {
        // podman ps can return an empty array.
        let json = r#"[]"#;
        let items: Vec<PodmanPsJson> = serde_json::from_str(json).unwrap();
        assert!(items.is_empty());
    }

    #[test]
    fn test_health_status_from_str() {
        assert_eq!(HealthStatus::from("healthy"), HealthStatus::Healthy);
        assert_eq!(HealthStatus::from("unhealthy"), HealthStatus::Unhealthy);
        assert_eq!(HealthStatus::from("starting"), HealthStatus::Starting);
        assert_eq!(HealthStatus::from("none"), HealthStatus::None);
        assert!(matches!(HealthStatus::from("weird"), HealthStatus::Unknown(_)));
    }
}
