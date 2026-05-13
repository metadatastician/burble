//! Test double: [`MockDriver`].
//!
//! Records every call into a `Vec<MockCall>` (protected by a `Mutex`) and
//! returns configurable canned responses.  Useful for unit-testing the
//! executor and any consumer crate that imports `selur_compose_driver`.
//!
//! # Example
//!
//! ```rust,no_run
//! use selur_compose_driver::mock::MockDriver;
//! use selur_compose_driver::ContainerId;
//!
//! let driver = MockDriver::new();
//! driver.set_run_response(Ok(ContainerId("abc".to_string())));
//! // … call driver.run(&spec).await …
//! ```

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::Duration;

use async_trait::async_trait;

use selur_compose_plan::{BuildSpec, NetworkSpec, RunSpec, VolumeSpec};

use crate::{
    ContainerId, ContainerState, ContainerSummary, Driver, DriverError, HealthState, HealthStatus,
    ImageId, LogStream, Result,
};

// ---------------------------------------------------------------------------
// MockCall — a record of one invocation
// ---------------------------------------------------------------------------

/// A record of a single [`Driver`] method invocation.
#[derive(Debug, Clone)]
pub enum MockCall {
    /// `Driver::build` was called.
    Build(BuildSpec),
    /// `Driver::pull` was called.
    Pull(String),
    /// `Driver::create_network` was called.
    CreateNetwork(NetworkSpec),
    /// `Driver::create_volume` was called.
    CreateVolume(VolumeSpec),
    /// `Driver::run` was called.
    Run(RunSpec),
    /// `Driver::inspect` was called.
    Inspect(ContainerId),
    /// `Driver::healthcheck_run` was called.
    HealthcheckRun(ContainerId),
    /// `Driver::stop` was called.
    Stop { id: ContainerId, grace: Duration },
    /// `Driver::rm` was called.
    Rm { id: ContainerId, force: bool },
    /// `Driver::logs` was called.
    Logs { id: ContainerId, follow: bool },
    /// `Driver::ps` was called.
    Ps(String),
}

// ---------------------------------------------------------------------------
// MockDriver
// ---------------------------------------------------------------------------

/// A recording test double for [`Driver`].
///
/// All methods record their call and return canned responses.  Responses can
/// be configured before the test or replaced mid-test.
pub struct MockDriver {
    calls: Mutex<Vec<MockCall>>,
    // Canned responses — Option::None means "return a default success".
    run_response:     Mutex<Option<Result<ContainerId>>>,
    build_response:   Mutex<Option<Result<ImageId>>>,
    pull_response:    Mutex<Option<Result<ImageId>>>,
    inspect_map:      Mutex<HashMap<String, Result<ContainerState>>>,
    healthcheck_map:  Mutex<HashMap<String, Result<HealthState>>>,
    ps_response:      Mutex<Option<Result<Vec<ContainerSummary>>>>,
}

impl MockDriver {
    /// Create a new `MockDriver` with all-success defaults.
    pub fn new() -> Self {
        Self {
            calls:            Mutex::new(Vec::new()),
            run_response:     Mutex::new(None),
            build_response:   Mutex::new(None),
            pull_response:    Mutex::new(None),
            inspect_map:      Mutex::new(HashMap::new()),
            healthcheck_map:  Mutex::new(HashMap::new()),
            ps_response:      Mutex::new(None),
        }
    }

    // ---- call recording ----

    /// Return a snapshot of all recorded calls, in order.
    pub fn calls(&self) -> Vec<MockCall> {
        self.calls.lock().unwrap().clone()
    }

    fn record(&self, call: MockCall) {
        self.calls.lock().unwrap().push(call);
    }

    // ---- canned-response setters ----

    /// Configure the canned response for `Driver::run`.
    pub fn set_run_response(&self, r: Result<ContainerId>) {
        *self.run_response.lock().unwrap() = Some(r);
    }

    /// Configure the canned response for `Driver::build`.
    pub fn set_build_response(&self, r: Result<ImageId>) {
        *self.build_response.lock().unwrap() = Some(r);
    }

    /// Configure the canned response for `Driver::pull`.
    pub fn set_pull_response(&self, r: Result<ImageId>) {
        *self.pull_response.lock().unwrap() = Some(r);
    }

    /// Configure the canned `inspect` response for a specific container.
    pub fn set_inspect_response(&self, id: ContainerId, r: Result<ContainerState>) {
        self.inspect_map.lock().unwrap().insert(id.0, r);
    }

    /// Configure the canned `healthcheck_run` response for a specific container.
    pub fn set_healthcheck_response(&self, id: ContainerId, r: Result<HealthState>) {
        self.healthcheck_map.lock().unwrap().insert(id.0, r);
    }

    /// Configure the canned response for `Driver::ps`.
    pub fn set_ps_response(&self, r: Result<Vec<ContainerSummary>>) {
        *self.ps_response.lock().unwrap() = Some(r);
    }

    // ---- helpers ----

    fn default_container_state() -> ContainerState {
        ContainerState {
            name: "mock_container".to_string(),
            status: "running".to_string(),
            pid: 1,
            exit_code: 0,
            health: Some(HealthState {
                status: HealthStatus::Healthy,
                failing_streak: 0,
            }),
        }
    }
}

impl Default for MockDriver {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl Driver for MockDriver {
    async fn build(&self, spec: &BuildSpec) -> Result<ImageId> {
        self.record(MockCall::Build(spec.clone()));
        let guard = self.build_response.lock().unwrap();
        match guard.as_ref() {
            Some(Ok(id)) => Ok(id.clone()),
            Some(Err(e)) => Err(mock_error(e)),
            None => Ok(ImageId("sha256:mock0000build".to_string())),
        }
    }

    async fn pull(&self, image: &str) -> Result<ImageId> {
        self.record(MockCall::Pull(image.to_string()));
        let guard = self.pull_response.lock().unwrap();
        match guard.as_ref() {
            Some(Ok(id)) => Ok(id.clone()),
            Some(Err(e)) => Err(mock_error(e)),
            None => Ok(ImageId(format!("sha256:mock0000{image}"))),
        }
    }

    async fn create_network(&self, n: &NetworkSpec) -> Result<()> {
        self.record(MockCall::CreateNetwork(n.clone()));
        Ok(())
    }

    async fn create_volume(&self, v: &VolumeSpec) -> Result<()> {
        self.record(MockCall::CreateVolume(v.clone()));
        Ok(())
    }

    async fn run(&self, spec: &RunSpec) -> Result<ContainerId> {
        self.record(MockCall::Run(spec.clone()));
        let guard = self.run_response.lock().unwrap();
        match guard.as_ref() {
            Some(Ok(id)) => Ok(id.clone()),
            Some(Err(e)) => Err(mock_error(e)),
            None => Ok(ContainerId(format!("mock_{}", spec.container_name))),
        }
    }

    async fn inspect(&self, id: &ContainerId) -> Result<ContainerState> {
        self.record(MockCall::Inspect(id.clone()));
        let map = self.inspect_map.lock().unwrap();
        match map.get(&id.0) {
            Some(Ok(state)) => Ok(state.clone()),
            Some(Err(e)) => Err(mock_error(e)),
            None => Ok(Self::default_container_state()),
        }
    }

    async fn healthcheck_run(&self, id: &ContainerId) -> Result<HealthState> {
        self.record(MockCall::HealthcheckRun(id.clone()));
        let map = self.healthcheck_map.lock().unwrap();
        match map.get(&id.0) {
            Some(Ok(hs)) => Ok(hs.clone()),
            Some(Err(e)) => Err(mock_error(e)),
            None => Ok(HealthState {
                status: HealthStatus::Healthy,
                failing_streak: 0,
            }),
        }
    }

    async fn stop(&self, id: &ContainerId, grace: Duration) -> Result<()> {
        self.record(MockCall::Stop { id: id.clone(), grace });
        Ok(())
    }

    async fn rm(&self, id: &ContainerId, force: bool) -> Result<()> {
        self.record(MockCall::Rm { id: id.clone(), force });
        Ok(())
    }

    async fn logs(&self, id: &ContainerId, follow: bool) -> Result<LogStream> {
        self.record(MockCall::Logs { id: id.clone(), follow });
        // Return an empty cursor.
        Ok(Box::new(tokio::io::empty()))
    }

    async fn ps(&self, project: &str) -> Result<Vec<ContainerSummary>> {
        self.record(MockCall::Ps(project.to_string()));
        let guard = self.ps_response.lock().unwrap();
        match guard.as_ref() {
            Some(Ok(list)) => Ok(list.clone()),
            Some(Err(e)) => Err(mock_error(e)),
            None => Ok(vec![]),
        }
    }
}

/// Clone a `DriverError` for canned-response replay.
///
/// `DriverError` is not `Clone` (it may contain `std::io::Error` which isn't
/// clone), so we convert it to a string-based Podman error for replay.
fn mock_error(e: &DriverError) -> DriverError {
    DriverError::Podman {
        argv: vec!["mock".to_string()],
        code: -1,
        stderr: e.to_string(),
    }
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_mock_driver_records_calls() {
        let driver = MockDriver::new();
        let id = ContainerId("c1".to_string());
        driver.inspect(&id).await.unwrap();
        driver.stop(&id, Duration::from_secs(10)).await.unwrap();

        let calls = driver.calls();
        assert_eq!(calls.len(), 2);
        assert!(matches!(calls[0], MockCall::Inspect(_)));
        assert!(matches!(calls[1], MockCall::Stop { .. }));
    }

    #[tokio::test]
    async fn test_mock_driver_canned_run_error() {
        let driver = MockDriver::new();
        driver.set_run_response(Err(DriverError::Podman {
            argv: vec!["podman".to_string(), "run".to_string()],
            code: 1,
            stderr: "image not found".to_string(),
        }));

        let spec = RunSpec {
            service: "web".to_string(),
            image: "nonexistent:latest".to_string(),
            container_name: "proj_web".to_string(),
            environment: vec![],
            ports: vec![],
            volumes: vec![],
            networks: vec![],
            network_mode: None,
            command: None,
            entrypoint: None,
            restart: "no".to_string(),
            labels: Default::default(),
        };
        let result = driver.run(&spec).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn test_mock_driver_canned_inspect_response() {
        let driver = MockDriver::new();
        let id = ContainerId("abc".to_string());
        driver.set_inspect_response(
            id.clone(),
            Ok(ContainerState {
                name: "test_svc".to_string(),
                status: "exited".to_string(),
                pid: 0,
                exit_code: 1,
                health: None,
            }),
        );
        let state = driver.inspect(&id).await.unwrap();
        assert_eq!(state.status, "exited");
        assert_eq!(state.exit_code, 1);
    }

    #[tokio::test]
    async fn test_mock_driver_ps_default_empty() {
        let driver = MockDriver::new();
        let result = driver.ps("burble").await.unwrap();
        assert!(result.is_empty());
    }

    #[tokio::test]
    async fn test_mock_driver_logs_returns_empty_stream() {
        let driver = MockDriver::new();
        let id = ContainerId("c1".to_string());
        let stream = driver.logs(&id, false).await.unwrap();
        // Just verify the stream is returned without panic.
        drop(stream);
    }
}
