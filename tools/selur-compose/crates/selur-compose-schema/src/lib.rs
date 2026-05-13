//! `selur-compose-schema` — pure serde types for TOML compose files.
//!
//! The root entry point is [`parse_str`], which wraps [`toml::from_str`] and
//! returns a typed [`Compose`] value.  This crate does no I/O; callers are
//! responsible for reading the file.
//!
//! # Usage
//!
//! ```rust,no_run
//! use selur_compose_schema::parse_str;
//!
//! let toml = std::fs::read_to_string("selur-compose.toml").unwrap();
//! let compose = parse_str(&toml, Some(std::path::Path::new("selur-compose.toml"))).unwrap();
//! println!("{} services", compose.services.len());
//! ```

use std::{collections::BTreeMap, path::Path};

use serde::{Deserialize, Serialize};

pub mod build;
pub mod depends_on;
pub mod error;
pub mod healthcheck;
pub mod networks;
pub mod ports;
pub mod secrets;
pub mod services;
pub mod volumes;

// Re-export the most commonly used types at the crate root.
pub use build::Build;
pub use depends_on::{DependsCondition, DependsOn, DependsOnSpec};
pub use error::ParseError;
pub use healthcheck::{Healthcheck, HealthcheckTest};
pub use networks::{Network, NetworkMode};
pub use ports::PortBinding;
pub use secrets::{Config, ConfigRef, Secret, SecretRef};
pub use services::{EnvMap, RestartPolicy, Service, StringOrList};
pub use volumes::{MountSpec, Volume};

// ---------------------------------------------------------------------------
// Root compose document
// ---------------------------------------------------------------------------

/// The root document of a selur-compose TOML file.
///
/// `deny_unknown_fields` is intentionally **off** at this level so that
/// `[x-svalinn]`, `[x-stapeln]`, and similar extension tables are tolerated
/// and captured in `extensions`.  Unknown fields inside service/network/volume
/// bodies still produce errors (those types use `deny_unknown_fields`).
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct Compose {
    /// Optional `[project]` table.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project: Option<Project>,

    /// `[services]` table.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub services: BTreeMap<String, Service>,

    /// `[networks]` table.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub networks: BTreeMap<String, Network>,

    /// `[volumes]` table.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub volumes: BTreeMap<String, Volume>,

    /// `[secrets]` table.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub secrets: BTreeMap<String, Secret>,

    /// `[configs]` table.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub configs: BTreeMap<String, Config>,

    /// Extension tables (`[x-*]`) captured as raw TOML values.
    ///
    /// This field uses `#[serde(flatten)]` so any top-level key not matched by
    /// the fields above ends up here.  The `[x-svalinn]` table referenced in
    /// burble's compose files is captured this way.
    #[serde(flatten)]
    pub extensions: BTreeMap<String, toml::Value>,
}

/// `[project]` — optional project metadata.
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Project {
    /// The project name, used to prefix container/network/volume names.
    pub name: String,
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

/// Parse a TOML compose document from a string.
///
/// # Arguments
///
/// * `s` — TOML source text.
/// * `source_path` — path used in error messages; pass `None` when the source
///   is not a file (e.g. in tests).
///
/// # Errors
///
/// Returns [`ParseError::Toml`] for any TOML syntax or schema error.
/// Additional semantic errors (e.g. `MissingImageOrBuild`) are returned
/// after structural parsing succeeds.
pub fn parse_str(s: &str, source_path: Option<&Path>) -> Result<Compose, ParseError> {
    let path = source_path
        .map(|p| p.to_path_buf())
        .unwrap_or_else(|| std::path::PathBuf::from("<input>"));

    let compose: Compose = toml::from_str(s).map_err(|e| ParseError::Toml {
        file:   path.clone(),
        source: e,
    })?;

    // Post-parse semantic validation
    validate(&compose, &path)?;

    Ok(compose)
}

/// Post-parse semantic validation (things serde cannot express).
fn validate(compose: &Compose, _path: &Path) -> Result<(), ParseError> {
    for (name, svc) in &compose.services {
        if svc.image.is_none() && svc.build.is_none() {
            return Err(ParseError::MissingImageOrBuild {
                service: name.clone(),
            });
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// did_you_mean helper (used by error reporting callers)
// ---------------------------------------------------------------------------

/// Return the closest field name from `candidates` to `input`, or `None`
/// if no candidate is within a Levenshtein distance of 3.
pub fn did_you_mean<'a>(input: &str, candidates: &[&'a str]) -> Option<&'a str> {
    candidates
        .iter()
        .map(|&c| (c, strsim::levenshtein(input, c)))
        .filter(|(_, dist)| *dist <= 3)
        .min_by_key(|(_, dist)| *dist)
        .map(|(c, _)| c)
}

