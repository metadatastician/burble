//! Port binding specifications.
//!
//! Accepted string short-forms:
//! - `"4020:80"` — `<host>:<container>`
//! - `"4020:80/tcp"` — with protocol
//! - `"127.0.0.1:4020:80"` — with host IP
//! - `"4020-4030:80-90"` — port ranges
//!
//! The long/struct form is also accepted for full control.

use serde::{Deserialize, Deserializer, Serialize, Serializer};

/// A port binding entry in a service's `ports:` list.
///
/// Short-form strings are preserved verbatim to avoid any round-trip loss.
#[derive(Debug, Clone, PartialEq)]
pub enum PortBinding {
    /// Short-form string preserved verbatim.
    Short(String),
    /// Full struct form.
    Long(PortLong),
}

/// The long/struct form of a port binding.
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct PortLong {
    /// Host IP address to bind to (optional, default all interfaces).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host_ip: Option<String>,

    /// Port (or range) on the container side.
    pub target: u16,

    /// Port (or range) on the host side.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub published: Option<String>,

    /// Protocol: `"tcp"` (default), `"udp"`, or `"sctp"`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub protocol: Option<String>,
}

// ---------------------------------------------------------------------------
// Custom serde: strings → Short, tables → Long
// ---------------------------------------------------------------------------

impl<'de> Deserialize<'de> for PortBinding {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        use serde::de::Error;
        let v: toml::Value = toml::Value::deserialize(d)?;
        match v {
            toml::Value::String(s) => Ok(PortBinding::Short(s)),
            toml::Value::Integer(n) => Ok(PortBinding::Short(n.to_string())),
            toml::Value::Table(_) => {
                let long: PortLong = PortLong::deserialize(v).map_err(Error::custom)?;
                Ok(PortBinding::Long(long))
            }
            other => Err(Error::custom(format!(
                "expected a string or table for a port binding, got {other:?}"
            ))),
        }
    }
}

impl Serialize for PortBinding {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        match self {
            PortBinding::Short(str) => str.serialize(s),
            PortBinding::Long(long) => long.serialize(s),
        }
    }
}
