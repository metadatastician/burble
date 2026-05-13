//! Table-driven grammar tests for the expander.
//!
//! These tests exercise the full grammar defined in `src/grammar.md` via the
//! public `expand` function.  Each row tests one semantic case.

use selur_compose_interp::{
    env::EnvMap,
    error::InterpError,
    expander::expand,
};

// Helper: build an EnvMap from a slice of static pairs.
fn env(pairs: &[(&str, &str)]) -> EnvMap {
    EnvMap::from_iter(pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())))
}

fn empty() -> EnvMap {
    EnvMap::default()
}

// ---------------------------------------------------------------------------
// Plain literals
// ---------------------------------------------------------------------------

#[test]
fn literal_no_dollar() {
    assert_eq!(expand("hello world", &empty()).unwrap(), "hello world");
}

#[test]
fn literal_empty() {
    assert_eq!(expand("", &empty()).unwrap(), "");
}

// ---------------------------------------------------------------------------
// $$ escape → literal $
// ---------------------------------------------------------------------------

#[test]
fn escape_double_dollar() {
    assert_eq!(expand("$$", &empty()).unwrap(), "$");
}

#[test]
fn escape_in_prefix() {
    assert_eq!(expand("prefix$$suffix", &empty()).unwrap(), "prefix$suffix");
}

// ---------------------------------------------------------------------------
// ${VAR} — plain reference
// ---------------------------------------------------------------------------

#[test]
fn plain_var_set() {
    assert_eq!(expand("${VAR}", &env(&[("VAR", "value")])).unwrap(), "value");
}

#[test]
fn plain_var_set_empty() {
    // Empty string is a valid value for ${VAR}.
    assert_eq!(expand("${VAR}", &env(&[("VAR", "")])).unwrap(), "");
}

#[test]
fn plain_var_unset_is_error() {
    let err = expand("${VAR}", &empty()).unwrap_err();
    assert!(matches!(err, InterpError::Undefined { ref name, .. } if name == "VAR"));
}

#[test]
fn plain_var_embedded() {
    let e = env(&[("REALM", "example.com")]);
    assert_eq!(
        expand("turn:${REALM}:3478", &e).unwrap(),
        "turn:example.com:3478"
    );
}

// ---------------------------------------------------------------------------
// ${VAR:-default} — colon-dash (unset OR empty → default)
// ---------------------------------------------------------------------------

#[test]
fn colon_dash_var_set_nonempty() {
    assert_eq!(
        expand("${V:-default}", &env(&[("V", "val")])).unwrap(),
        "val"
    );
}

#[test]
fn colon_dash_var_unset() {
    assert_eq!(expand("${V:-default}", &empty()).unwrap(), "default");
}

#[test]
fn colon_dash_var_empty_uses_default() {
    // Empty string → colon form uses the default.
    assert_eq!(
        expand("${V:-default}", &env(&[("V", "")])).unwrap(),
        "default"
    );
}

#[test]
fn colon_dash_empty_default() {
    // ${V:-} → empty string as default.
    assert_eq!(expand("${V:-}", &env(&[("V", "")])).unwrap(), "");
}

// ---------------------------------------------------------------------------
// ${VAR-default} — dash only (unset → default; empty string kept)
// ---------------------------------------------------------------------------

#[test]
fn dash_only_var_set() {
    assert_eq!(
        expand("${V-default}", &env(&[("V", "val")])).unwrap(),
        "val"
    );
}

#[test]
fn dash_only_var_unset() {
    assert_eq!(expand("${V-default}", &empty()).unwrap(), "default");
}

#[test]
fn dash_only_var_empty_kept() {
    // Empty string is preserved (no colon).
    assert_eq!(
        expand("${V-default}", &env(&[("V", "")])).unwrap(),
        ""
    );
}

// ---------------------------------------------------------------------------
// ${VAR:?msg} — colon-question (unset OR empty → MissingRequired)
// ---------------------------------------------------------------------------

#[test]
fn colon_question_var_set_nonempty() {
    assert_eq!(
        expand("${SECRET:?must set it}", &env(&[("SECRET", "abc")])).unwrap(),
        "abc"
    );
}

#[test]
fn colon_question_var_unset_errors() {
    let err = expand("${SECRET:?must set it}", &empty()).unwrap_err();
    assert!(
        matches!(err, InterpError::MissingRequired { ref name, ref msg, .. }
            if name == "SECRET" && msg == "must set it")
    );
}

#[test]
fn colon_question_var_empty_errors() {
    let err = expand("${SECRET:?must set it}", &env(&[("SECRET", "")])).unwrap_err();
    assert!(matches!(err, InterpError::MissingRequired { .. }));
}

// ---------------------------------------------------------------------------
// ${VAR?msg} — question only (unset → MissingRequired; empty allowed)
// ---------------------------------------------------------------------------

#[test]
fn question_only_var_set_nonempty() {
    assert_eq!(
        expand("${SECRET?oops}", &env(&[("SECRET", "xyz")])).unwrap(),
        "xyz"
    );
}

#[test]
fn question_only_var_unset_errors() {
    let err = expand("${SECRET?oops}", &empty()).unwrap_err();
    assert!(matches!(err, InterpError::MissingRequired { ref name, .. } if name == "SECRET"));
}

#[test]
fn question_only_var_empty_ok() {
    // Empty string is allowed with no-colon form.
    assert_eq!(
        expand("${SECRET?oops}", &env(&[("SECRET", "")])).unwrap(),
        ""
    );
}

// ---------------------------------------------------------------------------
// Bare $VAR — must NOT be expanded
// ---------------------------------------------------------------------------

#[test]
fn bare_dollar_var_passthrough() {
    // Even if VAR is set in env, $VAR without braces must be preserved.
    let e = env(&[("args", "would-break-if-expanded")]);
    assert_eq!(expand("exec $args", &e).unwrap(), "exec $args");
}

#[test]
fn bare_dollar_at_end() {
    assert_eq!(expand("trailing$", &empty()).unwrap(), "trailing$");
}

// ---------------------------------------------------------------------------
// The coturn load-bearing case
// ---------------------------------------------------------------------------

#[test]
fn coturn_command_passthrough() {
    let cmd = r#"args='--config /etc/coturn/turnserver.conf'; args="$args --static-auth-secret=$TURN_SECRET --realm=$TURN_REALM"; [ -n "$TURN_EXTERNAL_IP" ] && args="$args --external-ip=$TURN_EXTERNAL_IP"; exec turnserver $args"#;
    // No env needed — none of the references have braces.
    assert_eq!(expand(cmd, &empty()).unwrap(), cmd);
}

// ---------------------------------------------------------------------------
// Unterminated brace
// ---------------------------------------------------------------------------

#[test]
fn unterminated_brace() {
    let err = expand("${FOO", &empty()).unwrap_err();
    assert!(matches!(err, InterpError::Unterminated { .. }));
}

// ---------------------------------------------------------------------------
// Composite / real-world cases
// ---------------------------------------------------------------------------

#[test]
fn turn_url_with_override() {
    let e = env(&[("TURN_REALM", "example.com")]);
    assert_eq!(
        expand("turn:${TURN_REALM:-burble.local}:3478", &e).unwrap(),
        "turn:example.com:3478"
    );
}

#[test]
fn turn_url_with_default() {
    assert_eq!(
        expand("turn:${TURN_REALM:-burble.local}:3478", &empty()).unwrap(),
        "turn:burble.local:3478"
    );
}

#[test]
fn external_ip_empty_default() {
    assert_eq!(expand("${TURN_EXTERNAL_IP:-}", &empty()).unwrap(), "");
}

#[test]
fn multiple_expansions_in_one_string() {
    let e = env(&[("A", "hello"), ("B", "world")]);
    assert_eq!(
        expand("${A:-x} ${B:-y}", &e).unwrap(),
        "hello world"
    );
}

#[test]
fn env_entry_with_key_value_interpolation() {
    // Simulates what happens when environment list entries like
    // "TURN_SECRET=${TURN_SECRET:-change-me}" are processed.
    let e = env(&[("TURN_SECRET", "hunter2")]);
    assert_eq!(
        expand("TURN_SECRET=${TURN_SECRET:-change-me-in-production}", &e).unwrap(),
        "TURN_SECRET=hunter2"
    );
}

#[test]
fn env_entry_with_key_value_default() {
    assert_eq!(
        expand("TURN_SECRET=${TURN_SECRET:-change-me-in-production}", &empty()).unwrap(),
        "TURN_SECRET=change-me-in-production"
    );
}
