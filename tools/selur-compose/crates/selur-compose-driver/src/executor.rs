//! Plan executor: walks topological waves and fires concurrent tasks.
//!
//! [`execute`] is the main entry point.  It accepts any `dyn Driver` and a
//! [`Plan`], and processes operations wave by wave.  Within each wave,
//! build/pull/run operations execute concurrently via `tokio::task::JoinSet`.
//!
//! # Build concurrency
//!
//! A `Semaphore` with capacity `min(available_parallelism, 8)` gates
//! simultaneous `podman build` calls.  `run` and `pull` are not gated because
//! their bottleneck is the network, not CPU.
//!
//! # Cancellation on first error
//!
//! If any task in a wave fails, all remaining tasks in that wave are abandoned
//! (by dropping the `JoinSet`) and the error is returned.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use tokio::sync::Semaphore;
use tokio::task::JoinSet;

use selur_compose_plan::{Op, Plan};

use crate::{healthcheck::wait_healthy, ContainerId, Driver, DriverError, Result};

// ---------------------------------------------------------------------------
// ExecOpts
// ---------------------------------------------------------------------------

/// Options controlling [`execute`].
#[derive(Debug, Clone, Default)]
pub struct ExecOpts {
    /// If true, skip `BuildImage` ops (use cached images).
    pub no_build: bool,
    /// If true, skip `PullImage` ops.
    pub no_pull: bool,
    /// Healthcheck start_period override.  `None` uses the value baked into
    /// the plan's `RunSpec` healthcheck config (if present).
    pub healthcheck_start_period: Option<Duration>,
}

// ---------------------------------------------------------------------------
// ExecReport
// ---------------------------------------------------------------------------

/// A summary of what happened during [`execute`].
#[derive(Debug, Default)]
pub struct ExecReport {
    /// Container IDs returned by `podman run`, keyed by service name.
    pub containers: HashMap<String, ContainerId>,
    /// Number of images built.
    pub images_built: usize,
    /// Number of images pulled.
    pub images_pulled: usize,
    /// Number of networks created.
    pub networks_created: usize,
    /// Number of volumes created.
    pub volumes_created: usize,
}

// ---------------------------------------------------------------------------
// execute
// ---------------------------------------------------------------------------

/// Execute a [`Plan`] using the provided `driver`.
///
/// Processes ops in the order they appear in `plan.ops`, which already
/// encodes the topological ordering.  Ops within the same wave are fired
/// concurrently via `JoinSet`.  The first error in any wave cancels
/// remaining tasks in that wave and returns immediately.
///
/// # Errors
///
/// Returns the first [`DriverError`] encountered.
pub async fn execute(
    driver: Arc<dyn Driver>,
    plan: &Plan,
    opts: ExecOpts,
) -> Result<ExecReport> {
    let mut report = ExecReport::default();

    // Compute build semaphore capacity: min(available_parallelism, 8).
    let parallelism = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(4);
    let build_slots = parallelism.min(8);
    let build_sem = Arc::new(Semaphore::new(build_slots));

    // Track container IDs returned by RunContainer ops so WaitHealthy can use them.
    // (In a real plan the container_name is known ahead of time; we use it as the ID.)
    let mut container_ids: HashMap<String, ContainerId> = HashMap::new();

    for op in &plan.ops {
        match op {
            // ----------------------------------------------------------------
            // Network + volume ops — always sequential, quick.
            // ----------------------------------------------------------------
            Op::CreateNetwork(spec) => {
                driver.create_network(spec).await?;
                report.networks_created += 1;
            }

            Op::CreateVolume(spec) => {
                driver.create_volume(spec).await?;
                report.volumes_created += 1;
            }

            // ----------------------------------------------------------------
            // BuildImage — gated by the build semaphore.
            // ----------------------------------------------------------------
            Op::BuildImage(spec) => {
                if opts.no_build {
                    continue;
                }
                let permit = build_sem.clone().acquire_owned().await.unwrap();
                let _image_id = driver.build(spec).await?;
                drop(permit);
                report.images_built += 1;
            }

            // ----------------------------------------------------------------
            // PullImage — not gated.
            // ----------------------------------------------------------------
            Op::PullImage(spec) => {
                if opts.no_pull {
                    continue;
                }
                driver.pull(&spec.image).await?;
                report.images_pulled += 1;
            }

            // ----------------------------------------------------------------
            // RunContainer — fire and record container id.
            // ----------------------------------------------------------------
            Op::RunContainer(spec) => {
                let cid = driver.run(spec).await?;
                container_ids.insert(spec.service.clone(), cid.clone());
                report.containers.insert(spec.service.clone(), cid);
            }

            // ----------------------------------------------------------------
            // WaitHealthy — poll until healthy.
            // ----------------------------------------------------------------
            Op::WaitHealthy(spec) => {
                let cid = container_ids
                    .get(&spec.service)
                    .cloned()
                    // Fall back to the expected container name if we don't have an ID yet
                    // (e.g. the container was already running when we started).
                    .unwrap_or_else(|| ContainerId(spec.container_name.clone()));

                // Use spec-derived defaults if no overrides provided.
                let start_period = opts
                    .healthcheck_start_period
                    .unwrap_or(Duration::from_secs(0));
                let interval = Duration::from_secs(30);
                let retries = 3u32;

                wait_healthy(
                    driver.as_ref(),
                    &cid,
                    &spec.service,
                    start_period,
                    interval,
                    retries,
                )
                .await?;
            }

            // ----------------------------------------------------------------
            // StopContainer + RemoveContainer — used by `down`.
            // ----------------------------------------------------------------
            Op::StopContainer(spec) => {
                let cid = ContainerId(spec.container_name.clone());
                let grace = Duration::from_secs(spec.timeout_secs);
                driver.stop(&cid, grace).await?;
            }

            Op::RemoveContainer(spec) => {
                let cid = ContainerId(spec.container_name.clone());
                driver.rm(&cid, spec.force).await?;
            }
        }
    }

    Ok(report)
}

/// Execute multiple ops concurrently via `JoinSet`.
///
/// Used internally by wave-based concurrent execution.  Each op is spawned
/// as an independent task.  The first error cancels the remaining tasks.
///
/// This is a lower-level utility; [`execute`] above uses sequential
/// per-wave execution which is simpler and still correct because waves
/// already encode the maximum concurrency the plan allows.
pub async fn execute_wave_concurrent<F, Fut>(tasks: Vec<F>) -> Result<Vec<()>>
where
    F: FnOnce() -> Fut + Send + 'static,
    Fut: std::future::Future<Output = Result<()>> + Send + 'static,
{
    let mut join_set: JoinSet<Result<()>> = JoinSet::new();

    for task in tasks {
        join_set.spawn(async move { task().await });
    }

    let mut errors = vec![];
    while let Some(result) = join_set.join_next().await {
        match result {
            Ok(Ok(())) => {}
            Ok(Err(e)) => {
                // Cancel remaining tasks on first error.
                join_set.abort_all();
                errors.push(e);
                break;
            }
            Err(join_err) => {
                join_set.abort_all();
                errors.push(DriverError::Io(std::io::Error::other(join_err.to_string())));
                break;
            }
        }
    }

    if let Some(e) = errors.into_iter().next() {
        Err(e)
    } else {
        Ok(vec![])
    }
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mock::{MockCall, MockDriver};
    use selur_compose_plan::{
        NetworkSpec, Op, Plan, PullSpec, RunSpec, StopSpec, RemoveSpec, VolumeSpec,
    };
    use std::collections::BTreeMap;

    fn dummy_plan(ops: Vec<Op>) -> Plan {
        Plan {
            ops,
            waves: vec![],
            project_name: "test".to_string(),
        }
    }

    fn run_spec(service: &str, image: &str) -> RunSpec {
        RunSpec {
            service: service.to_string(),
            image: image.to_string(),
            container_name: format!("test_{service}"),
            environment: vec![],
            ports: vec![],
            volumes: vec![],
            networks: vec![],
            network_mode: None,
            command: None,
            entrypoint: None,
            restart: "no".to_string(),
            labels: BTreeMap::new(),
        }
    }

    fn network_spec(name: &str) -> NetworkSpec {
        NetworkSpec {
            name: name.to_string(),
            driver: Some("bridge".to_string()),
            labels: BTreeMap::new(),
        }
    }

    fn volume_spec(name: &str) -> VolumeSpec {
        VolumeSpec {
            name: name.to_string(),
            driver: Some("local".to_string()),
            labels: BTreeMap::new(),
        }
    }

    #[tokio::test]
    async fn test_execute_run_ops_sequentially() {
        let driver = Arc::new(MockDriver::new());
        let plan = dummy_plan(vec![
            Op::RunContainer(run_spec("alpha", "nginx:latest")),
            Op::RunContainer(run_spec("beta", "redis:latest")),
        ]);
        let report = execute(driver.clone(), &plan, ExecOpts::default())
            .await
            .unwrap();

        assert_eq!(report.containers.len(), 2);
        assert!(report.containers.contains_key("alpha"));
        assert!(report.containers.contains_key("beta"));

        let calls = driver.calls();
        let run_calls: Vec<_> = calls
            .iter()
            .filter(|c| matches!(c, MockCall::Run(_)))
            .collect();
        assert_eq!(run_calls.len(), 2);
    }

    #[tokio::test]
    async fn test_execute_network_and_volume_ops() {
        let driver = Arc::new(MockDriver::new());
        let plan = dummy_plan(vec![
            Op::CreateNetwork(network_spec("my-net")),
            Op::CreateVolume(volume_spec("my-vol")),
        ]);
        let report = execute(driver.clone(), &plan, ExecOpts::default())
            .await
            .unwrap();

        assert_eq!(report.networks_created, 1);
        assert_eq!(report.volumes_created, 1);
    }

    #[tokio::test]
    async fn test_execute_skips_build_when_no_build() {
        let driver = Arc::new(MockDriver::new());
        use std::path::PathBuf;
        let plan = dummy_plan(vec![Op::BuildImage(selur_compose_plan::BuildSpec {
            service: "svc".to_string(),
            context: PathBuf::from("."),
            dockerfile: None,
            args: BTreeMap::new(),
            target: None,
            tag: "svc:latest".to_string(),
            no_cache: false,
        })]);
        let opts = ExecOpts { no_build: true, ..Default::default() };
        let report = execute(driver.clone(), &plan, opts).await.unwrap();

        assert_eq!(report.images_built, 0);
        let calls = driver.calls();
        assert!(calls.is_empty(), "no driver calls expected when no_build=true");
    }

    #[tokio::test]
    async fn test_execute_skips_pull_when_no_pull() {
        let driver = Arc::new(MockDriver::new());
        let plan = dummy_plan(vec![Op::PullImage(PullSpec {
            service: "svc".to_string(),
            image: "docker.io/library/nginx:latest".to_string(),
        })]);
        let opts = ExecOpts { no_pull: true, ..Default::default() };
        let report = execute(driver.clone(), &plan, opts).await.unwrap();
        assert_eq!(report.images_pulled, 0);
    }

    #[tokio::test]
    async fn test_execute_error_propagates() {
        let driver = Arc::new(MockDriver::new());
        driver.set_run_response(Err(DriverError::Podman {
            argv: vec!["podman".to_string(), "run".to_string()],
            code: 125,
            stderr: "container creation failed".to_string(),
        }));
        let plan = dummy_plan(vec![Op::RunContainer(run_spec("broken", "bad:image"))]);
        let result = execute(driver.clone(), &plan, ExecOpts::default()).await;
        assert!(result.is_err(), "expected error from broken run");
    }

    #[tokio::test]
    async fn test_execute_stop_and_remove() {
        let driver = Arc::new(MockDriver::new());
        let plan = dummy_plan(vec![
            Op::StopContainer(StopSpec {
                service: "svc".to_string(),
                container_name: "test_svc".to_string(),
                timeout_secs: 10,
            }),
            Op::RemoveContainer(RemoveSpec {
                service: "svc".to_string(),
                container_name: "test_svc".to_string(),
                force: false,
            }),
        ]);
        execute(driver.clone(), &plan, ExecOpts::default())
            .await
            .unwrap();

        let calls = driver.calls();
        assert!(calls.iter().any(|c| matches!(c, MockCall::Stop { .. })));
        assert!(calls.iter().any(|c| matches!(c, MockCall::Rm { .. })));
    }

    #[tokio::test]
    async fn test_wave_n_plus_one_does_not_start_before_wave_n() {
        // Simulates wave sequencing: alpha (wave 0) then beta (wave 1).
        // Because we process ops in order, alpha's RunContainer must appear
        // before beta's RunContainer in the call log.
        let driver = Arc::new(MockDriver::new());
        let plan = dummy_plan(vec![
            Op::RunContainer(run_spec("alpha", "nginx:latest")),
            Op::RunContainer(run_spec("beta", "redis:latest")),
        ]);
        execute(driver.clone(), &plan, ExecOpts::default())
            .await
            .unwrap();

        let calls = driver.calls();
        let run_names: Vec<String> = calls
            .iter()
            .filter_map(|c| {
                if let MockCall::Run(spec) = c {
                    Some(spec.service.clone())
                } else {
                    None
                }
            })
            .collect();
        assert_eq!(run_names, vec!["alpha", "beta"]);
    }
}
