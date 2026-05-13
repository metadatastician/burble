//! Top-level `[networks]` declarations and `network_mode` on services.

use std::collections::BTreeMap;

use serde::{Deserialize, Deserializer, Serialize, Serializer};

/// A named network definition at the compose root.
///
/// ```toml
/// [networks.burble-internal]
/// driver = "bridge"
/// ```
#[derive(Debug, Clone, PartialEq, Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Network {
    /// Network driver (`bridge`, `host`, `macvlan`, …).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub driver: Option<String>,

    /// Driver-specific options.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub driver_opts: BTreeMap<String, String>,

    /// Whether this network is externally managed (already exists).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub external: bool,

    /// Custom name to use instead of the compose-prefixed name.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,

    /// IPAM configuration.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ipam: Option<Ipam>,

    /// Labels to apply to the network.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub labels: BTreeMap<String, String>,

    /// Mark the network as internal (no external connectivity).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub internal: bool,
}

/// IPAM (IP address management) configuration.
#[derive(Debug, Clone, PartialEq, Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Ipam {
    /// IPAM driver.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub driver: Option<String>,

    /// IPAM driver config pools.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub config: Vec<BTreeMap<String, String>>,
}

/// The `network_mode` value for a service.
///
/// ```toml
/// network_mode = "host"         # → NetworkMode::Host
/// network_mode = "bridge"       # → NetworkMode::Bridge
/// network_mode = "none"         # → NetworkMode::None
/// network_mode = "container:id" # → NetworkMode::Container("id")
/// network_mode = "custom-name"  # → NetworkMode::Custom("custom-name")
/// ```
///
/// Serialisation: we implement custom ser/de so that the named variants round-trip
/// to their exact lowercase string forms, and `Container("id")` serialises to
/// `"container:id"`.
#[derive(Debug, Clone, PartialEq)]
pub enum NetworkMode {
    /// Standard bridge network.
    Bridge,
    /// Host networking (service sees host network stack directly).
    Host,
    /// Disable networking.
    None,
    /// Share another container's network namespace.
    Container(String),
    /// Any other driver name.
    Custom(String),
}

impl<'de> Deserialize<'de> for NetworkMode {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let s = String::deserialize(d)?;
        Ok(match s.as_str() {
            "bridge" => NetworkMode::Bridge,
            "host"   => NetworkMode::Host,
            "none"   => NetworkMode::None,
            other if other.starts_with("container:") => {
                NetworkMode::Container(other["container:".len()..].to_owned())
            }
            other => NetworkMode::Custom(other.to_owned()),
        })
    }
}

impl Serialize for NetworkMode {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        let text = match self {
            NetworkMode::Bridge          => "bridge".to_owned(),
            NetworkMode::Host            => "host".to_owned(),
            NetworkMode::None            => "none".to_owned(),
            NetworkMode::Container(id)   => format!("container:{id}"),
            NetworkMode::Custom(name)    => name.clone(),
        };
        text.serialize(s)
    }
}
