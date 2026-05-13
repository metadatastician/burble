//! `depends_on:` — service dependency declarations.
//!
//! Two forms appear in the burble compose files:
//!
//! ```toml
//! # List form (web → server):
//! depends_on = ["server"]
//!
//! # Map-with-condition form (server → verisimdb):
//! depends_on = { verisimdb = { condition = "service_healthy" } }
//! ```
//!
//! Both are captured by the untagged [`DependsOn`] enum.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// The `depends_on` value for a service.
///
/// This is an untagged enum because TOML does not tag union variants — the
/// deserialiser tries each variant in order and uses the first that succeeds.
///
/// Ordering matters: `List` must come before `Map` so that a bare string array
/// matches `List` before falling through to `Map`.
#[derive(Debug, Clone, PartialEq, Default, Deserialize, Serialize)]
#[serde(untagged)]
pub enum DependsOn {
    /// No dependencies (field absent or explicitly empty).
    #[default]
    Empty,

    /// Simple dependency list: `depends_on = ["server"]`.
    List(Vec<String>),

    /// Condition-annotated dependencies:
    /// `depends_on = { verisimdb = { condition = "service_healthy" } }`.
    Map(BTreeMap<String, DependsOnSpec>),
}

/// Per-dependency specification used in the map form of `depends_on`.
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DependsOnSpec {
    /// Condition that must be satisfied before the depending service starts.
    pub condition: DependsCondition,

    /// Whether to restart this service when the dependency restarts.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub restart: bool,
}

impl DependsOn {
    /// Returns `true` when there are no dependencies.
    ///
    /// Used as the `skip_serializing_if` predicate so that the `Empty` variant
    /// (a unit variant in an untagged enum) is never written to TOML.
    pub fn is_empty(&self) -> bool {
        matches!(self, DependsOn::Empty)
    }
}

/// The condition under which a dependency is considered satisfied.
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DependsCondition {
    /// Dependency container has started (default).
    ServiceStarted,
    /// Dependency container reports healthy (requires a healthcheck).
    ServiceHealthy,
    /// Dependency container has exited with code 0.
    ServiceCompletedSuccessfully,
}
