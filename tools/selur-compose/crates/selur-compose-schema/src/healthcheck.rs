//! `healthcheck:` — container health probe configuration.

use std::time::Duration;

use humantime_serde::re::humantime;
use serde::{Deserialize, Deserializer, Serialize, Serializer};

/// Health probe configuration for a service.
///
/// ```toml
/// healthcheck = { test = "wget -q --spider http://localhost:8080/health || exit 1",
///                 interval = "30s", timeout = "5s", retries = 3 }
/// ```
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Healthcheck {
    /// The probe command to run.
    pub test: HealthcheckTest,

    /// How often to run the probe.
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        with = "opt_duration"
    )]
    pub interval: Option<Duration>,

    /// Maximum time to wait for the probe to complete.
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        with = "opt_duration"
    )]
    pub timeout: Option<Duration>,

    /// Number of consecutive failures before declaring unhealthy.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub retries: Option<u32>,

    /// Initial delay before starting health probes.
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        with = "opt_duration"
    )]
    pub start_period: Option<Duration>,

    /// Disable the healthcheck inherited from the image.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub disable: bool,
}

/// The probe command.
///
/// Two forms are accepted:
///
/// - `Shell(String)` — a bare shell string:
///   `test = "wget -q --spider http://localhost:8080/health || exit 1"`
/// - `Exec(Vec<String>)` — an exec-form array:
///   `test = ["CMD", "wget", "-q", "--spider", "http://localhost:8080/health"]`
///
/// The `Shell` form is what all three burble fixtures use; the `Exec` form is
/// the idiomatic Docker/Podman form and must also be supported.
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
#[serde(untagged)]
pub enum HealthcheckTest {
    /// Shell-string form: run via `/bin/sh -c "<string>"`.
    Shell(String),
    /// Exec-array form: `["CMD", …]` or `["CMD-SHELL", "…"]`.
    Exec(Vec<String>),
}

// ---------------------------------------------------------------------------
// Shared serde helper: Option<Duration> via humantime strings
// This module is also used by services::Service::stop_grace_period.
// ---------------------------------------------------------------------------

/// Serde module for `Option<Duration>` using humantime string format.
///
/// Serialises `Some(Duration)` as `"30s"`, `"5m"`, etc.
/// Deserialises `None` / absent fields as `None`.
pub mod opt_duration {
    use super::*;

    /// Serialise an `Option<Duration>` as a humantime string.
    pub fn serialize<S>(val: &Option<Duration>, s: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        match val {
            None    => s.serialize_none(),
            Some(d) => s.serialize_some(&humantime::format_duration(*d).to_string()),
        }
    }

    /// Deserialise an `Option<Duration>` from a humantime string.
    pub fn deserialize<'de, D>(d: D) -> Result<Option<Duration>, D::Error>
    where
        D: Deserializer<'de>,
    {
        let opt: Option<String> = Option::deserialize(d)?;
        match opt {
            None    => Ok(None),
            Some(s) => humantime::parse_duration(&s)
                .map(Some)
                .map_err(serde::de::Error::custom),
        }
    }
}
