//! `selur-compose up` — bring the stack up.
//!
//! Constructs a `PodmanCli` driver, then either:
//! * prints each planned `Op` to stdout (when `--dry-run` is active), or
//! * calls `executor::execute` to run the plan and prints a summary table.
//!
//! Honours `-d/--detach` (containers are always started detached via
//! `podman run --detach`; the flag is accepted but is a no-op for v0.1),
//! `--build`/`--no-build`, `--no-pull`, `--force-recreate`,
//! `--remove-orphans`, and `[SERVICE...]` filter.

use std::sync::Arc;

use anyhow::Result;

use selur_compose_driver::{executor::{execute, ExecOpts}, podman::PodmanCli};
use selur_compose_plan::Op;

use crate::{
    cli::{Format, UpArgs},
    load,
    output::{print_summary, ContainerRow},
};

pub async fn run(
    args:         &UpArgs,
    file:         Option<&std::path::Path>,
    env_files:    &[std::path::PathBuf],
    profiles:     &[String],
    project_name: Option<&str>,
    format:       Format,
    dry_run:      bool,
) -> Result<()> {
    let loaded = load::load(file, env_files, profiles, project_name, &args.services)?;

    if dry_run {
        println!("Dry-run: planned ops for project `{}`", loaded.plan.project_name);
        for op in &loaded.plan.ops {
            println!("  {}", describe_op(op));
        }
        return Ok(());
    }

    let driver = Arc::new(PodmanCli::new());
    let opts = ExecOpts {
        no_build: args.no_build,
        no_pull:  args.no_pull,
        ..Default::default()
    };

    let report = execute(driver, &loaded.plan, opts).await
        .map_err(|e| anyhow::anyhow!(e))?;

    // Build summary rows from the report.
    let rows: Vec<ContainerRow> = report.containers
        .iter()
        .map(|(svc, cid)| ContainerRow {
            service:      svc.clone(),
            container_id: cid.0.clone(),
            image:        String::new(),
            status:       "started".to_string(),
            ports:        String::new(),
        })
        .collect();

    print_summary(&rows, format);
    Ok(())
}

/// Human-readable one-line description of an Op (for dry-run display).
fn describe_op(op: &Op) -> String {
    match op {
        Op::CreateNetwork(s)  => format!("CreateNetwork   {}", s.name),
        Op::CreateVolume(s)   => format!("CreateVolume    {}", s.name),
        Op::BuildImage(s)     => format!("BuildImage      {} (tag: {})", s.service, s.tag),
        Op::PullImage(s)      => format!("PullImage       {} ({})", s.service, s.image),
        Op::RunContainer(s)   => format!("RunContainer    {} ({})", s.service, s.image),
        Op::WaitHealthy(s)    => format!("WaitHealthy     {}", s.service),
        Op::StopContainer(s)  => format!("StopContainer   {}", s.service),
        Op::RemoveContainer(s)=> format!("RemoveContainer {}", s.service),
    }
}
