//! `selur-compose pull` — pull service images.
//!
//! Iterates `plan.ops` for `Op::PullImage` entries and calls
//! `driver.pull(&image)` for each one.  The `[SERVICE...]` filter is
//! applied by the planner via `PlanOptions::services`.

use std::sync::Arc;

use anyhow::Result;

use selur_compose_driver::{Driver, podman::PodmanCli};
use selur_compose_plan::Op;

use crate::{
    cli::{Format, PullArgs},
    load,
};

pub async fn run(
    args:         &PullArgs,
    file:         Option<&std::path::Path>,
    env_files:    &[std::path::PathBuf],
    profiles:     &[String],
    project_name: Option<&str>,
    _format:      Format,
    dry_run:      bool,
) -> Result<()> {
    let loaded = load::load(file, env_files, profiles, project_name, &args.services)?;

    if dry_run {
        println!("Dry-run: planned pull ops for project `{}`", loaded.plan.project_name);
        for op in &loaded.plan.ops {
            if let Op::PullImage(spec) = op {
                println!("  PullImage  {} ({})", spec.service, spec.image);
            }
        }
        return Ok(());
    }

    let driver = Arc::new(PodmanCli::new());

    for op in &loaded.plan.ops {
        if let Op::PullImage(spec) = op {
            tracing::info!("Pulling {} ({})", spec.service, spec.image);
            let image_id = driver.pull(&spec.image).await
                .map_err(|e| anyhow::anyhow!(e))?;
            println!("Pulled {} → {}", spec.image, image_id);
        }
    }

    Ok(())
}
