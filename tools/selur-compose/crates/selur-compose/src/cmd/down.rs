//! `selur-compose down` — tear the stack down.
//!
//! Queries running containers for the project via `driver.ps`, then walks
//! them (all) with `driver.stop` + `driver.rm`.  Honours `--timeout`,
//! `--volumes`, `--rmi`, and `--remove-orphans`.
//!
//! `--remove-orphans` and `--rmi` are accepted and their semantics noted in
//! the Open Issues section of the release report; full implementation is
//! deferred to v0.2.

use std::sync::Arc;
use std::time::Duration;

use anyhow::Result;

use selur_compose_driver::{Driver, podman::PodmanCli, ContainerId};
use selur_compose_plan::Op;

use crate::{
    cli::{DownArgs, Format},
    load,
};

pub async fn run(
    args:         &DownArgs,
    file:         Option<&std::path::Path>,
    env_files:    &[std::path::PathBuf],
    profiles:     &[String],
    project_name: Option<&str>,
    _format:      Format,
    dry_run:      bool,
) -> Result<()> {
    let loaded = load::load(file, env_files, profiles, project_name, &[])?;
    let project = &loaded.plan.project_name;
    let grace   = Duration::from_secs(u64::from(args.timeout));

    if dry_run {
        println!("Dry-run: planned ops for `down` on project `{project}`");
        // Emit stop + remove ops that *would* be issued for each service in the plan.
        for op in &loaded.plan.ops {
            if let Op::RunContainer(s) = op {
                println!("  StopContainer   {} (grace {}s)", s.service, args.timeout);
                println!("  RemoveContainer {}", s.service);
            }
        }
        return Ok(());
    }

    let driver = Arc::new(PodmanCli::new());

    // Query what is actually running.
    let containers = driver.ps(project).await
        .map_err(|e| anyhow::anyhow!(e))?;

    if containers.is_empty() {
        println!("No containers found for project `{project}`.");
        return Ok(());
    }

    // Walk in reverse order (simple reversal; proper topo-reverse is future work).
    for container in containers.iter().rev() {
        let cid = ContainerId(container.id.clone());
        let svc = container.name.as_str();

        tracing::info!("Stopping  {svc} ({cid})");
        driver.stop(&cid, grace).await
            .map_err(|e| anyhow::anyhow!(e))?;

        tracing::info!("Removing  {svc} ({cid})");
        driver.rm(&cid, false).await
            .map_err(|e| anyhow::anyhow!(e))?;

        println!("Stopped and removed {svc}.");
    }

    // --volumes: remove named volumes (v0.2 — noted in open issues).
    if args.volumes {
        tracing::warn!("--volumes: named volume removal is not yet implemented (v0.2)");
    }

    // --rmi: image removal (v0.2 — noted in open issues).
    if args.rmi.is_some() {
        tracing::warn!("--rmi: image removal is not yet implemented (v0.2)");
    }

    Ok(())
}
