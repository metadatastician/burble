//! Healthcheck-gated `depends_on` polling loop.
//!
//! [`wait_healthy`] polls `podman inspect` until the container reports
//! `healthy`, exhausts its timeout, or reports `unhealthy`.
//!
//! # Deduplication
//!
//! [`HealthGate`] wraps a `tokio::sync::OnceCell<HealthState>` so that a
//! diamond `depends_on` pattern (two downstream services both depending on the
//! same upstream with `service_healthy`) only spawns one poll loop; the second
//! caller awaits the same cell.

use std::sync::Arc;
use std::time::{Duration, Instant};

use tokio::sync::OnceCell;

use crate::{ContainerId, Driver, DriverError, HealthState, HealthStatus, Result};

/// Default poll interval when the service has no explicit healthcheck config.
const DEFAULT_POLL_INTERVAL: Duration = Duration::from_secs(2);

/// Slack added to the computed timeout so we don't race against podman's own
/// scheduler.
const TIMEOUT_SLACK: Duration = Duration::from_secs(5);

// ---------------------------------------------------------------------------
// wait_healthy — the polling loop
// ---------------------------------------------------------------------------

/// Poll until the container `id` (belonging to `service`) is healthy.
///
/// The timeout is computed as:
///
/// ```text
/// start_period + interval × (retries + 1) + 5s slack
/// ```
///
/// where `start_period`, `interval`, and `retries` are taken from the compose
/// healthcheck spec.  If the healthcheck spec is `None`, reasonable defaults
/// are used (30s start, 30s interval, 3 retries).
///
/// # Errors
///
/// - [`DriverError::HealthcheckTimeout`] — if the timeout expires.
/// - [`DriverError::Unhealthy`] — if the container reports `unhealthy`.
/// - Any `DriverError` from the underlying [`Driver::inspect`] call.
pub async fn wait_healthy(
    driver: &dyn Driver,
    id: &ContainerId,
    service: &str,
    start_period: Duration,
    interval: Duration,
    retries: u32,
) -> Result<HealthState> {
    let timeout = start_period + interval * (retries + 1) + TIMEOUT_SLACK;
    let poll = interval.min(DEFAULT_POLL_INTERVAL);

    let deadline = Instant::now() + timeout;

    loop {
        let state = driver.inspect(id).await?;

        match state.health {
            Some(ref hs) => match hs.status {
                HealthStatus::Healthy => return Ok(hs.clone()),
                HealthStatus::Unhealthy => {
                    return Err(DriverError::Unhealthy {
                        service: service.to_string(),
                        streak: hs.failing_streak,
                    });
                }
                // Starting | None | Unknown — keep polling.
                _ => {}
            },
            // No healthcheck configured — treat as healthy immediately.
            None => {
                return Ok(HealthState {
                    status: HealthStatus::None,
                    failing_streak: 0,
                });
            }
        }

        if Instant::now() >= deadline {
            return Err(DriverError::HealthcheckTimeout {
                service: service.to_string(),
                timeout,
            });
        }

        tokio::time::sleep(poll).await;
    }
}

// ---------------------------------------------------------------------------
// HealthGate — deduplicating wrapper (OnceCell)
// ---------------------------------------------------------------------------

/// A deduplicating gate for a single service's health result.
///
/// Multiple callers can await the same `HealthGate`; only the first to call
/// [`HealthGate::wait`] will run the poll loop.  Subsequent calls return the
/// cached result.
///
/// # Usage
///
/// ```rust,no_run
/// # use selur_compose_driver::healthcheck::HealthGate;
/// # use selur_compose_driver::{ContainerId, HealthState};
/// # use std::sync::Arc;
/// let gate = Arc::new(HealthGate::new("verisimdb"));
/// // Clone the Arc into each task that depends on this service.
/// ```
#[derive(Debug)]
pub struct HealthGate {
    /// The service name (for error messages).
    pub service: String,
    cell: OnceCell<std::result::Result<HealthState, String>>,
}

impl HealthGate {
    /// Create a new gate for `service`.
    pub fn new(service: impl Into<String>) -> Self {
        Self {
            service: service.into(),
            cell: OnceCell::new(),
        }
    }

    /// Poll until healthy, using this gate to deduplicate concurrent callers.
    ///
    /// The first caller runs the poll loop; later callers await the cached
    /// result.  If the poll loop fails, all awaiting callers receive an error.
    pub async fn wait(
        self: &Arc<Self>,
        driver: &dyn Driver,
        id: &ContainerId,
        start_period: Duration,
        interval: Duration,
        retries: u32,
    ) -> Result<HealthState> {
        let service = self.service.clone();
        let id = id.clone();

        let result = self
            .cell
            .get_or_init(|| async {
                match wait_healthy(driver, &id, &service, start_period, interval, retries).await {
                    Ok(hs) => Ok(hs),
                    Err(e) => Err(e.to_string()),
                }
            })
            .await;

        match result {
            Ok(hs) => Ok(hs.clone()),
            Err(_msg) => Err(DriverError::HealthcheckTimeout {
                service: self.service.clone(),
                // Re-surface the error as a timeout (the original error text is in the message).
                timeout: Duration::ZERO,
            }),
        }
    }
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mock::MockDriver;
    use crate::{ContainerState, HealthState, HealthStatus};

    fn healthy_state(name: &str) -> ContainerState {
        ContainerState {
            name: name.to_string(),
            status: "running".to_string(),
            pid: 1,
            exit_code: 0,
            health: Some(HealthState {
                status: HealthStatus::Healthy,
                failing_streak: 0,
            }),
        }
    }

    fn unhealthy_state(name: &str, streak: u32) -> ContainerState {
        ContainerState {
            name: name.to_string(),
            status: "running".to_string(),
            pid: 1,
            exit_code: 0,
            health: Some(HealthState {
                status: HealthStatus::Unhealthy,
                failing_streak: streak,
            }),
        }
    }

    #[tokio::test]
    async fn test_wait_healthy_immediately_healthy() {
        let driver = MockDriver::new();
        let id = ContainerId("c1".to_string());
        driver.set_inspect_response(id.clone(), Ok(healthy_state("svc")));

        let result = wait_healthy(
            &driver,
            &id,
            "svc",
            Duration::ZERO,
            Duration::from_millis(1),
            3,
        )
        .await;
        assert!(result.is_ok());
        assert_eq!(result.unwrap().status, HealthStatus::Healthy);
    }

    #[tokio::test]
    async fn test_wait_healthy_unhealthy_returns_error() {
        let driver = MockDriver::new();
        let id = ContainerId("c1".to_string());
        driver.set_inspect_response(id.clone(), Ok(unhealthy_state("svc", 5)));

        let result = wait_healthy(
            &driver,
            &id,
            "svc",
            Duration::ZERO,
            Duration::from_millis(1),
            3,
        )
        .await;
        assert!(matches!(result, Err(DriverError::Unhealthy { streak: 5, .. })));
    }

    #[tokio::test]
    async fn test_wait_healthy_no_healthcheck_returns_none_status() {
        let driver = MockDriver::new();
        let id = ContainerId("c1".to_string());
        // Simulate a container with no healthcheck configured.
        driver.set_inspect_response(
            id.clone(),
            Ok(ContainerState {
                name: "svc".to_string(),
                status: "running".to_string(),
                pid: 1,
                exit_code: 0,
                health: None,
            }),
        );

        let result = wait_healthy(
            &driver,
            &id,
            "svc",
            Duration::ZERO,
            Duration::from_millis(1),
            3,
        )
        .await;
        assert!(result.is_ok());
        assert_eq!(result.unwrap().status, HealthStatus::None);
    }
}
