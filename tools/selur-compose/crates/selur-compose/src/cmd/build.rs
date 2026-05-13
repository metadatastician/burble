//! `selur-compose build` — build service images.
//!
//! Iterates `plan.ops` for `Op::BuildImage` entries and calls
//! `driver.build(&spec)` for each one.  Honours `--no-cache`, `--pull`,
//! and `[SERVICE...]` (the service filter is applied by the planner via
//! `PlanOptions::services`).

use std::sync::Arc;

use anyhow::Result;

use selur_compose_driver::{Driver, podman::PodmanCli};
use selur_compose_plan::Op;

use crate::{
    cli::{BuildArgs, Format},
    load,
};

pub async fn run(
    args:         &BuildArgs,
    file:         Option<&std::path::Path>,
    env_files:    &[std::path::PathBuf],
    profiles:     &[String],
    project_name: Option<&str>,
    _format:      Format,
    dry_run:      bool,
) -> Result<()> {
    let loaded = load::load(file, env_files, profiles, project_name, &args.services)?;

    if dry_run {
        println!("Dry-run: planned build ops for project `{}`", loaded.plan.project_name);
        for op in &loaded.plan.ops {
            if let Op::BuildImage(spec) = op {
                println!("  BuildImage  {} (tag: {})", spec.service, spec.tag);
            }
        }
        return Ok(());
    }

    let driver = Arc::new(PodmanCli::new());

    for op in &loaded.plan.ops {
        if let Op::BuildImage(spec) = op {
            // Apply --no-cache flag at the subcommand level.
            let mut effective = spec.clone();
            if args.no_cache {
                effective.no_cache = true;
            }

            tracing::info!("Building {} → {}", spec.service, spec.tag);
            let image_id = driver.build(&effective).await
                .map_err(|e| anyhow::anyhow!(e))?;
            println!("Built {} → {}", spec.tag, image_id);
        }
    }

    Ok(())
}
