//! Deterministic config-hash computation for service definitions.
//!
//! The hash is a SHA-256 digest over a canonical JSON serialisation of the
//! [`selur_compose_schema::Service`] value.  Using JSON (via `serde_json`)
//! gives us stable, sorted-key output because we drive serialisation through
//! `serde_json::Value`, then re-serialise with sorted keys via the `BTreeMap`
//! internally used by `serde_json::Map`.
//!
//! # Stability guarantee
//!
//! * The same `Service` value always produces the same 64-character lowercase
//!   hex SHA-256 digest.
//! * A one-character change to any string field changes the hash.
//! * Fields that serialize to their defaults (and are thus absent from the JSON
//!   due to `skip_serializing_if`) do not affect the hash.
//!
//! # Usage
//!
//! ```rust
//! use selur_compose_schema::parse_str;
//! use selur_compose_plan::hash::service_hash;
//!
//! let toml = r#"
//!     [services.app]
//!     image = "myimage:latest"
//! "#;
//! let compose = parse_str(toml, None).unwrap();
//! let svc = compose.services.values().next().unwrap();
//! let h = service_hash(svc);
//! assert_eq!(h.len(), 64);
//! ```

use sha2::{Digest, Sha256};

use selur_compose_schema::Service;

/// Compute a deterministic SHA-256 hash of a service definition.
///
/// Returns a 64-character lowercase hex string.
pub fn service_hash(svc: &Service) -> String {
    // Serialise to serde_json::Value first.  serde_json internally uses a
    // LinkedHashMap (or BTreeMap when "preserve_order" is off), but we
    // need sorted keys for stability.  Easiest way: convert the Value to a
    // sorted JSON string by going through `to_string` after sorting the map.
    let val = serde_json::to_value(svc)
        .expect("Service is always JSON-serialisable");

    // Re-serialise with sorted keys using our helper.
    let canonical = canonical_json(&val);

    // Hash the canonical bytes.
    let mut hasher = Sha256::new();
    hasher.update(canonical.as_bytes());
    let digest = hasher.finalize();

    // Format as lowercase hex.
    digest
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect::<String>()
}

/// Recursively serialise a `serde_json::Value` to a JSON string with
/// object keys sorted alphabetically.  This gives us a canonical form
/// regardless of the order `serde` emits keys.
fn canonical_json(val: &serde_json::Value) -> String {
    match val {
        serde_json::Value::Object(map) => {
            // Collect and sort keys.
            let mut pairs: Vec<(&String, &serde_json::Value)> = map.iter().collect();
            pairs.sort_by_key(|(k, _)| k.as_str());
            let inner: Vec<String> = pairs
                .into_iter()
                .map(|(k, v)| format!("{}:{}", serde_json::to_string(k).unwrap(), canonical_json(v)))
                .collect();
            format!("{{{}}}", inner.join(","))
        }
        serde_json::Value::Array(arr) => {
            let items: Vec<String> = arr.iter().map(canonical_json).collect();
            format!("[{}]", items.join(","))
        }
        // Primitives: use serde_json's own serialisation (stable for booleans,
        // numbers, strings, and null).
        other => serde_json::to_string(other).unwrap(),
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn parse_service(toml_snippet: &str) -> Service {
        let compose = selur_compose_schema::parse_str(toml_snippet, None).unwrap();
        compose.services.into_values().next().unwrap()
    }

    #[test]
    fn hash_is_64_hex_chars() {
        let svc = parse_service("[services.app]\nimage = \"alpine:latest\"\n");
        let h = service_hash(&svc);
        assert_eq!(h.len(), 64, "hash must be 64 hex chars");
        assert!(h.chars().all(|c| c.is_ascii_hexdigit()), "hash must be hex");
    }

    #[test]
    fn same_service_same_hash() {
        let toml = "[services.app]\nimage = \"alpine:latest\"\n";
        let svc1 = parse_service(toml);
        let svc2 = parse_service(toml);
        assert_eq!(service_hash(&svc1), service_hash(&svc2));
    }

    #[test]
    fn different_image_different_hash() {
        let svc1 = parse_service("[services.app]\nimage = \"alpine:latest\"\n");
        let svc2 = parse_service("[services.app]\nimage = \"alpine:3.18\"\n");
        assert_ne!(
            service_hash(&svc1),
            service_hash(&svc2),
            "different images must produce different hashes"
        );
    }

    #[test]
    fn hash_is_stable_across_calls() {
        let toml = "[services.app]\nimage = \"nginx:stable\"\nrestart = \"always\"\n";
        let svc = parse_service(toml);
        let h1 = service_hash(&svc);
        let h2 = service_hash(&svc);
        assert_eq!(h1, h2);
    }

    #[test]
    fn canonical_json_sorts_keys() {
        // Build a Value with out-of-order keys and check canonical form.
        let mut map = serde_json::Map::new();
        map.insert("z".to_string(), serde_json::Value::Bool(true));
        map.insert("a".to_string(), serde_json::Value::Bool(false));
        let val = serde_json::Value::Object(map);
        let canon = canonical_json(&val);
        // "a" must appear before "z" in the output.
        let a_pos = canon.find("\"a\"").unwrap();
        let z_pos = canon.find("\"z\"").unwrap();
        assert!(a_pos < z_pos, "keys must be sorted: got {canon}");
    }
}
