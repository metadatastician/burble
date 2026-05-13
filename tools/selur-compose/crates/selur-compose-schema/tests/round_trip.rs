//! Round-trip tests: parse → serialise → parse → compare.
//!
//! Each fixture in `tests/fixtures/valid/` must survive a full
//! TOML round-trip with no semantic loss (serde_json value equality).

use selur_compose_schema::parse_str;
use std::path::Path;

/// Parse `toml_src`, serialise back to TOML, parse again, then assert that
/// the two parsed values are equal when compared via their `serde_json`
/// representations.  This catches cases where `skip_serializing_if` or custom
/// ser/de code drops fields or changes their shape.
fn round_trip_ok(toml_src: &str, label: &str) {
    // First parse
    let first = parse_str(toml_src, Some(Path::new(label)))
        .unwrap_or_else(|e| panic!("first parse of {label} failed: {e}"));

    // Serialise back to TOML
    let re_serialised = toml::to_string(&first)
        .unwrap_or_else(|e| panic!("serialise of {label} failed: {e}"));

    // Second parse
    let second = parse_str(&re_serialised, Some(Path::new(label)))
        .unwrap_or_else(|e| panic!("second parse of {label} failed: {e}\nreserialised:\n{re_serialised}"));

    // Compare via serde_json values to avoid derive-order issues
    let j1 = serde_json::to_value(&first)
        .unwrap_or_else(|e| panic!("json1 of {label} failed: {e}"));
    let j2 = serde_json::to_value(&second)
        .unwrap_or_else(|e| panic!("json2 of {label} failed: {e}"));

    assert_eq!(j1, j2, "round-trip mismatch for {label}");
}

#[test]
fn round_trip_burble_selur() {
    let src = include_str!("fixtures/valid/burble-selur.toml");
    round_trip_ok(src, "burble-selur.toml");
}

#[test]
fn round_trip_burble_legacy() {
    let src = include_str!("fixtures/valid/burble-legacy.toml");
    round_trip_ok(src, "burble-legacy.toml");
}

#[test]
fn round_trip_boj_server() {
    let src = include_str!("fixtures/valid/boj-server.toml");
    round_trip_ok(src, "boj-server.toml");
}
