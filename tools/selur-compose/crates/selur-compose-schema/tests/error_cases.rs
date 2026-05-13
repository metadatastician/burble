//! Tests asserting that invalid fixtures produce the expected `ParseError` variants.

use selur_compose_schema::{parse_str, ParseError};
use std::path::Path;

/// Parse a fixture from `tests/fixtures/invalid/` and assert it fails.
fn parse_invalid(name: &str, src: &str) -> ParseError {
    parse_str(src, Some(Path::new(name))).expect_err("expected parse to fail")
}

#[test]
fn missing_image_or_build_is_error() {
    let src = include_str!("fixtures/invalid/missing_image_or_build.toml");
    let err = parse_invalid("missing_image_or_build.toml", src);
    assert!(
        matches!(err, ParseError::MissingImageOrBuild { ref service } if service == "oops"),
        "expected MissingImageOrBuild, got: {err}"
    );
}

#[test]
fn unknown_field_is_toml_error() {
    // `imag` is unknown in Service (which has deny_unknown_fields).
    // toml::from_str surfaces this as a Toml error because serde's deny_unknown_fields
    // generates an error message that toml propagates.
    let src = include_str!("fixtures/invalid/unknown_field.toml");
    let err = parse_invalid("unknown_field.toml", src);
    assert!(
        matches!(err, ParseError::Toml { .. }),
        "expected ParseError::Toml for unknown field, got: {err}"
    );
    // Check the error message mentions the unknown field name
    let msg = err.to_string();
    assert!(
        msg.contains("imag") || msg.contains("unknown"),
        "error message should reference the unknown field: {msg}"
    );
}

#[test]
fn bad_duration_is_toml_error() {
    let src = include_str!("fixtures/invalid/bad_duration.toml");
    let err = parse_invalid("bad_duration.toml", src);
    assert!(
        matches!(err, ParseError::Toml { .. }),
        "expected ParseError::Toml for bad duration, got: {err}"
    );
}

#[test]
fn cycle_in_depends_on_parses_ok() {
    // Cycle detection is the planner's job, not the parser's.
    let src = include_str!("fixtures/invalid/cycle_in_depends_on.toml");
    parse_str(src, Some(Path::new("cycle_in_depends_on.toml")))
        .expect("cycle in depends_on should parse without error (planner catches it)");
}

#[test]
fn bad_port_long_form_is_toml_error() {
    // Missing required `target` field in the long port form.
    let src = include_str!("fixtures/invalid/bad_port.toml");
    let err = parse_invalid("bad_port.toml", src);
    assert!(
        matches!(err, ParseError::Toml { .. }),
        "expected ParseError::Toml for bad port, got: {err}"
    );
}
