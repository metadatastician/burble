//! Deterministic config-hash computation for service definitions.
//!
//! The hash is a SHA-256 digest over the RFC 8785 (JCS) canonical bytes of
//! the [`selur_compose_schema::Service`] value's JSON form.  The bytes come
//! from [`ijson_jcs::to_jcs`], the estate's one JSON canonicaliser: object
//! keys are sorted by UTF-16 code unit, numbers are written as ECMAScript
//! writes them, and the value must be I-JSON (RFC 7493).
//!
//! # Stability guarantee
//!
//! * The same `Service` value always produces the same 64-character lowercase
//!   hex SHA-256 digest.
//! * A one-character change to any string field changes the hash.
//! * Fields that serialize to their defaults (and are thus absent from the JSON
//!   due to `skip_serializing_if`) do not affect the hash.
//!
//! # Compatibility with earlier hashes
//!
//! Earlier versions hashed the output of a private `serde_json` writer that
//! sorted keys by code point.  For a `Service`, the JCS bytes are the same
//! except in one case: a map with user-chosen keys (`environment`,
//! `build.args`, `build.labels`) holding two keys that first differ at a
//! character above U+FFFF in one and a character in U+E000–U+FFFF in the
//! other.  UTF-16 order puts the first key first; code-point order put it
//! second, so that service's hash changes.  The other JCS differences, float
//! formatting and integers beyond 2^53, need an `f64` or a wide integer, and
//! no `Service` field is either.
//!
//! One input that used to hash is now refused: a string holding a Unicode
//! noncharacter is not I-JSON, so [`service_hash`] returns an error and
//! `plan` reports `PlanError::ConfigHash` naming the service.
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
//! let h = service_hash(svc).unwrap();
//! assert_eq!(h.len(), 64);
//! ```

use sha2::{Digest, Sha256};

use selur_compose_schema::Service;

/// Compute a deterministic SHA-256 hash of a service definition.
///
/// Returns a 64-character lowercase hex string: the SHA-256 digest of the
/// service's RFC 8785 canonical JSON bytes.
///
/// # Errors
///
/// Returns [`ijson_jcs::CanonicalizationError`] when the service's JSON form
/// is not I-JSON (RFC 7493).  The only way a `Service` gets there is a
/// Unicode noncharacter (U+FDD0–U+FDEF, or any code point ending in FFFE or
/// FFFF) in one of its strings.
pub fn service_hash(svc: &Service) -> Result<String, ijson_jcs::CanonicalizationError> {
    let val = serde_json::to_value(svc).expect("Service is always JSON-serialisable");

    // RFC 8785 canonical bytes: UTF-16 key order, ECMAScript numbers.
    let canonical = ijson_jcs::to_jcs(&val)?;

    // Hash the canonical bytes.
    let mut hasher = Sha256::new();
    hasher.update(&canonical);
    let digest = hasher.finalize();

    // Format as lowercase hex.
    Ok(digest
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect::<String>())
}

/// The writer `service_hash` used before JCS, kept as the test oracle.
///
/// Serialises a `serde_json::Value` with object keys sorted by code point
/// (Rust `str` order) and primitives written by `serde_json`.  The tests
/// compare its bytes with [`ijson_jcs::to_jcs`] to show where the two differ.
#[cfg(test)]
fn legacy_canonical_json(val: &serde_json::Value) -> String {
    match val {
        serde_json::Value::Object(map) => {
            // Collect and sort keys.
            let mut pairs: Vec<(&String, &serde_json::Value)> = map.iter().collect();
            pairs.sort_by_key(|(k, _)| k.as_str());
            let inner: Vec<String> = pairs
                .into_iter()
                .map(|(k, v)| {
                    format!(
                        "{}:{}",
                        serde_json::to_string(k).unwrap(),
                        legacy_canonical_json(v)
                    )
                })
                .collect();
            format!("{{{}}}", inner.join(","))
        }
        serde_json::Value::Array(arr) => {
            let items: Vec<String> = arr.iter().map(legacy_canonical_json).collect();
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

    /// Parse a TOML snippet holding one service and return that service.
    fn parse_service(toml_snippet: &str) -> Service {
        let compose = selur_compose_schema::parse_str(toml_snippet, None).unwrap();
        compose.services.into_values().next().unwrap()
    }

    /// Lowercase hex SHA-256 of `bytes`, to state an expected hash directly.
    fn sha256_hex(bytes: &[u8]) -> String {
        Sha256::digest(bytes)
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect()
    }

    /// The compose files whose services the oracle compares: every compose
    /// file in the repository that parses.  That is the schema crate's valid
    /// fixtures, the interpolation fixture, and the two compose files burble
    /// deploys from (`containers/`).  Left out, because `plan` can never hash
    /// them: the `invalid/` fixtures, and the workspace-level
    /// `tests/fixtures/coturn_shell_passthrough.toml`, which no test reads and
    /// which does not parse (`healthcheck.test_cmd` is not a schema field).
    const ORACLE_FILES: &[(&str, &str)] = &[
        (
            "schema/fixtures/valid/boj-server.toml",
            include_str!("../../selur-compose-schema/tests/fixtures/valid/boj-server.toml"),
        ),
        (
            "schema/fixtures/valid/burble-legacy.toml",
            include_str!("../../selur-compose-schema/tests/fixtures/valid/burble-legacy.toml"),
        ),
        (
            "schema/fixtures/valid/burble-selur.toml",
            include_str!("../../selur-compose-schema/tests/fixtures/valid/burble-selur.toml"),
        ),
        (
            "interp/fixtures/coturn_shell_passthrough.toml",
            include_str!("../../selur-compose-interp/tests/fixtures/coturn_shell_passthrough.toml"),
        ),
        (
            "containers/selur-compose.toml",
            include_str!("../../../../../containers/selur-compose.toml"),
        ),
        (
            "containers/compose.toml",
            include_str!("../../../../../containers/compose.toml"),
        ),
    ];

    /// Services across [`ORACLE_FILES`], so a fixture that silently stops
    /// contributing services fails the oracle instead of shrinking it.
    const ORACLE_SERVICE_COUNT: usize = 18;

    /// Hashing yields 64 lowercase hex characters.
    #[test]
    fn hash_is_64_hex_chars() {
        let svc = parse_service("[services.app]\nimage = \"alpine:latest\"\n");
        let h = service_hash(&svc).unwrap();
        assert_eq!(h.len(), 64, "hash must be 64 hex chars");
        assert!(h.chars().all(|c| c.is_ascii_hexdigit()), "hash must be hex");
    }

    /// Two parses of the same TOML hash identically.
    #[test]
    fn same_service_same_hash() {
        let toml = "[services.app]\nimage = \"alpine:latest\"\n";
        let svc1 = parse_service(toml);
        let svc2 = parse_service(toml);
        assert_eq!(service_hash(&svc1).unwrap(), service_hash(&svc2).unwrap());
    }

    /// A different image gives a different hash.
    #[test]
    fn different_image_different_hash() {
        let svc1 = parse_service("[services.app]\nimage = \"alpine:latest\"\n");
        let svc2 = parse_service("[services.app]\nimage = \"alpine:3.18\"\n");
        assert_ne!(
            service_hash(&svc1).unwrap(),
            service_hash(&svc2).unwrap(),
            "different images must produce different hashes"
        );
    }

    /// Hashing one value twice gives the same digest.
    #[test]
    fn hash_is_stable_across_calls() {
        let toml = "[services.app]\nimage = \"nginx:stable\"\nrestart = \"always\"\n";
        let svc = parse_service(toml);
        let h1 = service_hash(&svc).unwrap();
        let h2 = service_hash(&svc).unwrap();
        assert_eq!(h1, h2);
    }

    /// The legacy oracle sorts ASCII keys, as it always did.
    #[test]
    fn legacy_canonical_json_sorts_keys() {
        // Build a Value with out-of-order keys and check canonical form.
        let mut map = serde_json::Map::new();
        map.insert("z".to_string(), serde_json::Value::Bool(true));
        map.insert("a".to_string(), serde_json::Value::Bool(false));
        let val = serde_json::Value::Object(map);
        let canon = legacy_canonical_json(&val);
        // "a" must appear before "z" in the output.
        let a_pos = canon.find("\"a\"").unwrap();
        let z_pos = canon.find("\"z\"").unwrap();
        assert!(a_pos < z_pos, "keys must be sorted: got {canon}");
    }

    /// Oracle: on every service of every real compose file, the JCS bytes
    /// equal the legacy writer's bytes, so no existing hash changes.
    #[test]
    fn jcs_bytes_match_the_legacy_writer_on_every_fixture() {
        let mut services = 0;
        for (label, src) in ORACLE_FILES {
            let compose = selur_compose_schema::parse_str(src, None)
                .unwrap_or_else(|e| panic!("{label} must parse for the oracle: {e}"));
            assert!(!compose.services.is_empty(), "{label} holds no services");
            for (name, svc) in &compose.services {
                let val = serde_json::to_value(svc).unwrap();
                let legacy = legacy_canonical_json(&val);
                let jcs = ijson_jcs::to_jcs(&val)
                    .unwrap_or_else(|e| panic!("{label} service `{name}` is not I-JSON: {e}"));
                assert_eq!(
                    legacy.as_bytes(),
                    jcs.as_slice(),
                    "{label} service `{name}`: JCS bytes differ from the legacy writer"
                );
                assert_eq!(service_hash(svc).unwrap(), sha256_hex(legacy.as_bytes()));
                services += 1;
            }
        }
        assert_eq!(
            services, ORACLE_SERVICE_COUNT,
            "oracle service count changed"
        );
    }

    /// Divergence class 1, reachable: keys that first differ at a character
    /// above U+FFFF and one in U+E000–U+FFFF.  JCS sorts by UTF-16 code unit
    /// (U+1F600 is D83D DE00, before E000); the legacy writer sorted by code
    /// point (E000 before 1F600).  Planted through TOML, so a `Service` can
    /// carry it.
    #[test]
    fn utf16_key_order_diverges_from_code_point_order() {
        let svc = parse_service(
            "[services.app]\nimage = \"alpine\"\n\
             [services.app.environment]\n\"\\uE000\" = \"bmp\"\n\"\\U0001F600\" = \"astral\"\n",
        );
        let val = serde_json::to_value(&svc).unwrap();
        let jcs_env = ijson_jcs::to_jcs(&val["environment"]).unwrap();
        assert_eq!(
            String::from_utf8(jcs_env).unwrap(),
            "{\"\u{1F600}\":\"astral\",\"\u{E000}\":\"bmp\"}"
        );
        assert_eq!(
            legacy_canonical_json(&val["environment"]),
            "{\"\u{E000}\":\"bmp\",\"\u{1F600}\":\"astral\"}"
        );
        // The hash follows JCS, not the legacy order.
        let jcs_all = ijson_jcs::to_jcs(&val).unwrap();
        assert_eq!(service_hash(&svc).unwrap(), sha256_hex(&jcs_all));
        assert_ne!(
            service_hash(&svc).unwrap(),
            sha256_hex(legacy_canonical_json(&val).as_bytes())
        );
    }

    /// Divergence class 2, not reachable from a `Service` (no field is a
    /// float): ECMAScript number formatting differs from `serde_json`'s for
    /// integral floats and for magnitudes ES writes without an exponent.
    /// `0.1` and `1e21` are written alike, as a control.
    #[test]
    fn float_formatting_diverges_on_values_a_service_cannot_hold() {
        for (f, jcs, legacy) in [
            (1.0_f64, "1", "1.0"),
            (-0.0, "0", "-0.0"),
            (1e20, "100000000000000000000", "1e+20"),
            (1e-6, "0.000001", "1e-6"),
            (0.1, "0.1", "0.1"),
            (1e21, "1e+21", "1e+21"),
        ] {
            let val = serde_json::json!(f);
            assert_eq!(
                ijson_jcs::to_jcs(&val).unwrap(),
                jcs.as_bytes(),
                "JCS of {f:e}"
            );
            assert_eq!(legacy_canonical_json(&val), legacy, "legacy of {f:e}");
        }
    }

    /// Divergence class 3, not reachable from a `Service` (its widest integer
    /// is `u32`): an integer beyond 2^53 is refused by I-JSON, where the
    /// legacy writer printed it.  2^53 − 1 is the boundary control.
    #[test]
    fn integer_beyond_2_pow_53_is_refused_on_values_a_service_cannot_hold() {
        let edge = serde_json::json!(9_007_199_254_740_991_u64);
        assert_eq!(ijson_jcs::to_jcs(&edge).unwrap(), b"9007199254740991");
        let over = serde_json::json!(9_007_199_254_740_993_u64);
        assert!(ijson_jcs::to_jcs(&over).is_err());
        assert_eq!(legacy_canonical_json(&over), "9007199254740993");
    }

    /// Refusal class, reachable: a Unicode noncharacter in a service string
    /// is not I-JSON, so the service cannot be hashed.  The legacy writer
    /// hashed it.
    #[test]
    fn noncharacter_in_a_service_string_is_refused() {
        let svc = parse_service("[services.app]\nimage = \"alpine\\uFFFE\"\n");
        assert!(svc.image.as_deref().unwrap().ends_with('\u{FFFE}'));
        let err = service_hash(&svc).unwrap_err();
        assert!(
            matches!(
                err,
                ijson_jcs::CanonicalizationError::ValidationError(
                    ijson_jcs::ValidationError::Noncharacter { .. }
                )
            ),
            "unexpected error: {err:?}"
        );
        let val = serde_json::to_value(&svc).unwrap();
        assert!(legacy_canonical_json(&val).contains('\u{FFFE}'));
    }

    /// `plan` reports an unhashable service as `PlanError::ConfigHash`,
    /// naming it, instead of panicking.
    #[test]
    fn plan_reports_an_unhashable_service_by_name() {
        let compose =
            selur_compose_schema::parse_str("[services.web]\nimage = \"alpine\\uFFFF\"\n", None)
                .unwrap();
        let err = crate::plan(&compose, &crate::PlanOptions::default()).unwrap_err();
        assert!(
            matches!(&err, crate::PlanError::ConfigHash { service, .. } if service == "web"),
            "unexpected error: {err:?}"
        );
    }
}
