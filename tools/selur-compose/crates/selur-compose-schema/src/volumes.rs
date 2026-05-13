//! Top-level `[volumes]` definitions and per-service `volumes:` mount specs.

use std::{collections::BTreeMap, path::PathBuf};

use serde::{Deserialize, Deserializer, Serialize, Serializer};

/// A named volume definition at the compose root.
///
/// ```toml
/// [volumes.burble-verisimdb-data]
/// driver = "local"
/// ```
#[derive(Debug, Clone, PartialEq, Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Volume {
    /// Volume driver (`local`, `nfs`, …).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub driver: Option<String>,

    /// Driver-specific options.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub driver_opts: BTreeMap<String, String>,

    /// Use a pre-existing, externally managed volume.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub external: bool,

    /// Custom name, overriding the compose-prefixed default.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,

    /// Labels applied to the volume.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub labels: BTreeMap<String, String>,
}

/// A per-service volume mount specification.
///
/// Both string short-forms and the struct form are accepted.
///
/// String short-forms:
/// - `"named-vol:/data"` — named volume
/// - `"./conf:/etc/conf:ro"` — bind mount with options
/// - `"/abs:/abs"` — absolute-path bind mount
///
/// The string is preserved verbatim on serialisation to avoid any round-trip
/// loss (e.g. `./coturn.conf:/etc/coturn/turnserver.conf:ro`).
#[derive(Debug, Clone, PartialEq)]
pub enum MountSpec {
    /// Short-form string preserved verbatim.
    Short(String),
    /// Struct form for richer control.
    Long(MountLong),
}

/// The long/struct form of a volume mount.
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct MountLong {
    /// Mount type: `"volume"`, `"bind"`, `"tmpfs"`, or `"npipe"`.
    #[serde(rename = "type")]
    pub mount_type: String,

    /// Source (volume name or host path).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<PathBuf>,

    /// Target path inside the container.
    pub target: PathBuf,

    /// Mount as read-only.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub read_only: bool,

    /// Bind mount options.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bind: Option<BindOptions>,

    /// Volume mount options.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub volume: Option<VolumeOptions>,
}

/// Options specific to bind mounts.
#[derive(Debug, Clone, PartialEq, Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct BindOptions {
    /// Propagation mode (`shared`, `slave`, `private`, `rprivate`, …).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub propagation: Option<String>,
    /// Create the host path if it does not exist.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub create_host_path: bool,
}

/// Options specific to named-volume mounts.
#[derive(Debug, Clone, PartialEq, Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct VolumeOptions {
    /// Do not copy image data when volume is first created.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub nocopy: bool,
}

// ---------------------------------------------------------------------------
// Custom serde for MountSpec: strings → Short, tables → Long
// ---------------------------------------------------------------------------

impl<'de> Deserialize<'de> for MountSpec {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        use serde::de::Error;
        let v: toml::Value = toml::Value::deserialize(d)?;
        match v {
            toml::Value::String(s) => Ok(MountSpec::Short(s)),
            toml::Value::Table(_) => {
                let long: MountLong = MountLong::deserialize(v).map_err(Error::custom)?;
                Ok(MountSpec::Long(long))
            }
            other => Err(Error::custom(format!(
                "expected a string or table for a volume mount, got {other:?}"
            ))),
        }
    }
}

impl Serialize for MountSpec {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        match self {
            MountSpec::Short(str) => str.serialize(s),
            MountSpec::Long(long) => long.serialize(s),
        }
    }
}
