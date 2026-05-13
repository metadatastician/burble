//! `selur-compose ps` — list containers for the project.
//!
//! Calls `driver.ps(&project_name)` to get `Vec<ContainerSummary>`, maps
//! each entry to a `ContainerRow`, and passes the result to
//! `output::print_ps`.

use std::sync::Arc;

use anyhow::Result;

use selur_compose_driver::{Driver, podman::PodmanCli};

use crate::{
    cli::{Format, PsArgs},
    load,
    output::{print_ps, ContainerRow},
};

pub async fn run(
    _args:        &PsArgs,
    file:         Option<&std::path::Path>,
    env_files:    &[std::path::PathBuf],
    profiles:     &[String],
    project_name: Option<&str>,
    format:       Format,
) -> Result<()> {
    let loaded = load::load(file, env_files, profiles, project_name, &[])?;
    let project = &loaded.plan.project_name;

    let driver = Arc::new(PodmanCli::new());

    let summaries = driver.ps(project).await
        .map_err(|e| anyhow::anyhow!(e))?;

    let rows: Vec<ContainerRow> = summaries
        .into_iter()
        .map(|s| ContainerRow {
            service:      s.service.unwrap_or_else(|| s.name.clone()),
            container_id: s.id,
            image:        s.image,
            status:       s.state,
            ports:        s.ports.join(", "),
        })
        .collect();

    print_ps(&rows, format);
    Ok(())
}
