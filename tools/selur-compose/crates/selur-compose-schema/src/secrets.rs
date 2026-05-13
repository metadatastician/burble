//! Secret and config definitions and service-level references.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
// Top-level [secrets] definitions
// ---------------------------------------------------------------------------

/// A named secret defined at the compose root.
///
/// ```toml
/// [secrets.my-secret]
/// file = "./secret.txt"
/// ```
#[derive(Debug, Clone, PartialEq, Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Secret {
    /// Path to a file containing the secret value.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file: Option<PathBuf>,

    /// Use a pre-existing, externally managed secret.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub external: bool,

    /// Custom name, overriding the compose-prefixed default.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
}

// ---------------------------------------------------------------------------
// Top-level [configs] definitions
// ---------------------------------------------------------------------------

/// A named config defined at the compose root.
///
/// ```toml
/// [configs.my-config]
/// file = "./my-config.txt"
/// ```
#[derive(Debug, Clone, PartialEq, Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    /// Path to a file containing the config content.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file: Option<PathBuf>,

    /// Use a pre-existing, externally managed config.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub external: bool,

    /// Custom name, overriding the compose-prefixed default.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
}

// ---------------------------------------------------------------------------
// Service-level secret references
// ---------------------------------------------------------------------------

/// A secret referenced from a service.
///
/// Two forms:
/// - Short: `secrets = ["my-secret"]` — just the secret name.
/// - Long:  `secrets = [{ source = "my-secret", target = "/run/secrets/mysecret" }]`.
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
#[serde(untagged)]
pub enum SecretRef {
    /// Short form: just the secret name.
    Name(String),
    /// Long form with target path, uid/gid, and mode.
    Long(SecretRefLong),
}

/// Long form of a service-level secret reference.
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct SecretRefLong {
    /// Name of the secret defined at the compose root.
    pub source: String,

    /// Path inside the container.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target: Option<PathBuf>,

    /// UID that owns the file inside the container.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub uid: Option<String>,

    /// GID that owns the file inside the container.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gid: Option<String>,

    /// File permission mode (octal string, e.g. `"0400"`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mode: Option<u32>,
}

// ---------------------------------------------------------------------------
// Service-level config references
// ---------------------------------------------------------------------------

/// A config referenced from a service.
///
/// Mirrors the same two-form pattern as [`SecretRef`].
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
#[serde(untagged)]
pub enum ConfigRef {
    /// Short form: just the config name.
    Name(String),
    /// Long form with target path, uid/gid, and mode.
    Long(ConfigRefLong),
}

/// Long form of a service-level config reference.
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ConfigRefLong {
    /// Name of the config defined at the compose root.
    pub source: String,

    /// Path inside the container.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target: Option<PathBuf>,

    /// UID that owns the file inside the container.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub uid: Option<String>,

    /// GID that owns the file inside the container.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gid: Option<String>,

    /// File permission mode (octal string, e.g. `"0444"`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mode: Option<u32>,
}
