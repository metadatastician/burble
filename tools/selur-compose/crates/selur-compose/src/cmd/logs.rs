//! `selur-compose logs` — tail service logs.
//!
//! 1. Calls `driver.ps(project)` to map service names → container IDs.
//! 2. Filters the result to only the services requested (or all services
//!    if `args.services` is empty).
//! 3. Calls `selur_compose_driver::logs::tail_logs` to multiplex log
//!    streams.
//! 4. Drains the receiver and prints each `[service] line` to stdout.
//!
//! Honours `-f/--follow` and `[SERVICE...]`.  `--tail <N>` is accepted
//! but deferred to v0.2 (see Open Issues in the release report).

use std::collections::HashMap;
use std::sync::Arc;

use anyhow::Result;

use selur_compose_driver::{Driver, logs::tail_logs, podman::PodmanCli, ContainerId};

use crate::{
    cli::{Format, LogsArgs},
    load,
};

pub async fn run(
    args:         &LogsArgs,
    file:         Option<&std::path::Path>,
    env_files:    &[std::path::PathBuf],
    profiles:     &[String],
    project_name: Option<&str>,
    _format:      Format,
) -> Result<()> {
    let loaded = load::load(file, env_files, profiles, project_name, &args.services)?;
    let project = &loaded.plan.project_name;

    let driver = Arc::new(PodmanCli::new());

    // Query running containers and build service → container-id map.
    let all_containers = driver.ps(project).await
        .map_err(|e| anyhow::anyhow!(e))?;

    let services_map: HashMap<String, ContainerId> = all_containers
        .into_iter()
        .filter_map(|c| {
            let svc = c.service?;
            // If a service filter was given, honour it.
            if !args.services.is_empty() && !args.services.contains(&svc) {
                return None;
            }
            Some((svc, ContainerId(c.id)))
        })
        .collect();

    if services_map.is_empty() {
        println!("No running containers found for project `{project}`.");
        return Ok(());
    }

    // --tail: accepted, deferred to v0.2.
    if args.tail.is_some() {
        tracing::warn!("--tail <N> is not yet implemented (v0.2); showing all available log lines");
    }

    let mut rx = tail_logs(driver.as_ref(), &services_map, args.follow).await;

    while let Some(line) = rx.recv().await {
        println!("{line}");
    }

    Ok(())
}
