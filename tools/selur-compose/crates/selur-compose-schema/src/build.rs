//! `build:` section — image build configuration.

use std::{collections::BTreeMap, path::PathBuf};

use serde::{Deserialize, Serialize};

/// Image build configuration.
///
/// Accepts both the inline-table short form
/// (`build = { context = ".", dockerfile = "Containerfile" }`)
/// and a full `[services.foo.build]` TOML table.
///
/// ```toml
/// build = { context = "../tools/nextgen-databases/verisimdb",
///           dockerfile = "container/Containerfile",
///           args = { FEATURES = "persistent" } }
/// ```
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Build {
    /// Build context path (relative to the compose file or absolute).
    pub context: PathBuf,

    /// Path to the Containerfile / Dockerfile, relative to `context`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dockerfile: Option<PathBuf>,

    /// Build-time `ARG` values.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub args: BTreeMap<String, String>,

    /// Build target stage name for multi-stage builds.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target: Option<String>,

    /// Labels applied to the built image.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub labels: BTreeMap<String, String>,

    /// Disable layer caching (`--no-cache`).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub no_cache: bool,
}
