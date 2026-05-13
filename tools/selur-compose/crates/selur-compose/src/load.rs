//! Shared compose-file loader.
//!
//! Every subcommand uses [`load`] to locate the compose file, discover `.env`
//! files, parse, interpolate, and plan in a single step.
//!
//! # File discovery
//!
//! 1. If `-f / --file` is provided, use that path.
//! 2. Otherwise look for `selur-compose.toml` in the current working directory.
//! 3. Fall back to `compose.toml` in the current working directory.
//!
//! # `.env` discovery
//!
//! 1. Look for a `.env` file in the **directory containing the compose file**.
//! 2. Then apply any `--env-file` paths (in the order given), each overriding
//!    earlier values.
//!
//! This matches the rule documented in `docs/superpowers/specs/…design.md §12.4`.

use std::path::{Path, PathBuf};

use anyhow::{Context, Result};

use selur_compose_interp::{env::EnvMap, interpolate};
use selur_compose_plan::{plan, Plan, PlanOptions};
use selur_compose_schema::{parse_str, Compose};

/// The output of [`load`]: the resolved plan and the interpolated compose.
#[allow(dead_code)] // compose_path will be used by driver-dependent subcommands in Phase 4
pub struct Loaded {
    pub compose: Compose,
    pub plan:    Plan,
    /// Absolute path to the compose file that was loaded.
    pub compose_path: PathBuf,
}

/// Load, interpolate, and plan a compose file.
///
/// # Arguments
///
/// * `file`         — explicit path from `-f/--file`, or `None` for auto-discovery.
/// * `env_files`    — extra env files from `--env-file` (applied in order).
/// * `profiles`     — active profiles from `--profile`.
/// * `project_name` — optional override from `-p/--project-name`.
/// * `services`     — restrict to these services (empty = all).
pub fn load(
    file:         Option<&Path>,
    env_files:    &[PathBuf],
    profiles:     &[String],
    project_name: Option<&str>,
    services:     &[String],
) -> Result<Loaded> {
    // -----------------------------------------------------------------------
    // 1. Locate the compose file
    // -----------------------------------------------------------------------
    let compose_path = resolve_compose_file(file)
        .context("could not find a compose file (tried selur-compose.toml, compose.toml)")?;

    let toml_src = std::fs::read_to_string(&compose_path)
        .with_context(|| format!("failed to read {}", compose_path.display()))?;

    // -----------------------------------------------------------------------
    // 2. Parse
    // -----------------------------------------------------------------------
    let compose = parse_str(&toml_src, Some(&compose_path))
        .with_context(|| format!("failed to parse {}", compose_path.display()))?;

    // -----------------------------------------------------------------------
    // 3. Build env map
    // -----------------------------------------------------------------------
    // Start from process environment, then layer the compose-dir .env, then
    // any --env-file overrides.
    let env = build_env(&compose_path, env_files)
        .context("failed to load environment files")?;

    // -----------------------------------------------------------------------
    // 4. Interpolate
    // -----------------------------------------------------------------------
    let compose = interpolate(compose, &env)
        .with_context(|| format!("variable interpolation failed for {}", compose_path.display()))?;

    // -----------------------------------------------------------------------
    // 5. Plan
    // -----------------------------------------------------------------------
    let opts = PlanOptions {
        profiles:     profiles.to_vec(),
        project_name: project_name.map(str::to_string),
        services:     services.to_vec(),
    };
    let plan = plan(&compose, &opts)
        .with_context(|| format!("planning failed for {}", compose_path.display()))?;

    Ok(Loaded { compose, plan, compose_path })
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Resolve the compose file path.
fn resolve_compose_file(explicit: Option<&Path>) -> Option<PathBuf> {
    if let Some(p) = explicit {
        return Some(p.to_path_buf());
    }
    let cwd = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    let candidates = ["selur-compose.toml", "compose.toml"];
    for name in &candidates {
        let p = cwd.join(name);
        if p.exists() {
            return Some(p);
        }
    }
    None
}

/// Build an `EnvMap` from process env + compose-dir `.env` + extra env files.
fn build_env(compose_path: &Path, extra_env_files: &[PathBuf]) -> Result<EnvMap> {
    // Start from process environment.
    let mut env = EnvMap::from_process();

    // Look for a .env in the compose file's directory.
    let compose_dir = compose_path
        .parent()
        .unwrap_or_else(|| Path::new("."));
    let dot_env = compose_dir.join(".env");
    if dot_env.exists() {
        env = env
            .with_env_files(&[dot_env])
            .context("failed to load .env file from compose directory")?;
    }

    // Apply --env-file overrides.
    if !extra_env_files.is_empty() {
        env = env
            .with_env_files(extra_env_files)
            .context("failed to load --env-file override")?;
    }

    Ok(env)
}
