//! Integration tests for `interpolate()` — parse + interpolate over real
//! consumer fixtures.
//!
//! These tests correspond to tasks 2.5 (coturn passthrough), 2.6 (public API),
//! and 2.7 (insta snapshots).

use selur_compose_interp::{env::EnvMap, interpolate};
use selur_compose_schema::{parse_str, EnvMap as SchemaEnvMap, StringOrList};

// ---------------------------------------------------------------------------
// Helper
// ---------------------------------------------------------------------------

fn fixture(name: &str) -> String {
    let manifest_dir = env!("CARGO_MANIFEST_DIR");
    let path = format!("{manifest_dir}/tests/fixtures/{name}");
    std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("could not read fixture {path}: {e}"))
}

fn schema_fixture(name: &str) -> String {
    // Real consumer fixtures live in the schema crate.
    let manifest_dir = env!("CARGO_MANIFEST_DIR");
    // Walk up two levels: interp → crates → workspace, then into schema tests.
    let path = format!(
        "{manifest_dir}/../../crates/selur-compose-schema/tests/fixtures/valid/{name}"
    );
    std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("could not read schema fixture {path}: {e}"))
}

fn controlled_env() -> EnvMap {
    EnvMap::from_iter(vec![
        ("TURN_REALM".to_string(), "example.com".to_string()),
        ("TURN_SECRET".to_string(), "hunter2".to_string()),
    ])
}

fn empty_env() -> EnvMap {
    EnvMap::default()
}

// ---------------------------------------------------------------------------
// Task 2.5: coturn $args passthrough
// ---------------------------------------------------------------------------

#[test]
fn coturn_command_passthrough_via_fixture() {
    let toml = fixture("coturn_shell_passthrough.toml");
    let compose = parse_str(&toml, None).unwrap();

    // The command array must survive interpolation verbatim.
    let expected_cmd = r#"args='--config /etc/coturn/turnserver.conf'; args="$args --static-auth-secret=$TURN_SECRET --realm=$TURN_REALM"; [ -n "$TURN_EXTERNAL_IP" ] && args="$args --external-ip=$TURN_EXTERNAL_IP"; exec turnserver $args"#;

    let resolved = interpolate(compose, &empty_env()).unwrap();

    let coturn = resolved.services.get("coturn").expect("coturn service present");
    match coturn.command.as_ref().unwrap() {
        StringOrList::List(items) => {
            assert_eq!(items.len(), 1, "command must be a single-element list");
            assert_eq!(
                items[0], expected_cmd,
                "bare $args and other bare-dollar vars must be preserved verbatim"
            );
        }
        StringOrList::String(s) => {
            assert_eq!(s, expected_cmd, "command string must be preserved verbatim");
        }
    }
}

#[test]
fn coturn_env_vars_are_expanded_in_fixture() {
    let toml = fixture("coturn_shell_passthrough.toml");
    let compose = parse_str(&toml, None).unwrap();

    // The `environment` list uses `${VAR:-default}` — those SHOULD be expanded.
    let resolved = interpolate(compose, &empty_env()).unwrap();
    let coturn = resolved.services.get("coturn").unwrap();

    // environment = ["TURN_SECRET=${TURN_SECRET:-change-me-in-production}", ...]
    let env_list = match &coturn.environment {
        SchemaEnvMap::List(items) => items.clone(),
        _ => panic!("expected list-form environment"),
    };

    // With empty env, defaults kick in.
    assert!(
        env_list.iter().any(|e| e == "TURN_SECRET=change-me-in-production"),
        "TURN_SECRET should expand to its default; got: {env_list:?}"
    );
    assert!(
        env_list.iter().any(|e| e == "TURN_REALM=burble.local"),
        "TURN_REALM should expand to its default; got: {env_list:?}"
    );
    // TURN_EXTERNAL_IP:-  → empty default
    assert!(
        env_list.iter().any(|e| e == "TURN_EXTERNAL_IP="),
        "TURN_EXTERNAL_IP should expand to empty; got: {env_list:?}"
    );
}

// ---------------------------------------------------------------------------
// Task 2.6: public entry point — burble-selur fixture
// ---------------------------------------------------------------------------

#[test]
fn burble_selur_default_env_gives_burble_local_realm() {
    let toml = schema_fixture("burble-selur.toml");
    let compose = parse_str(&toml, None).unwrap();

    let resolved = interpolate(compose, &empty_env()).unwrap();

    let server = resolved.services.get("server").unwrap();
    let env_list = match &server.environment {
        SchemaEnvMap::List(items) => items.clone(),
        _ => panic!("expected list-form environment"),
    };

    // "TURN_URL=turn:${TURN_REALM:-burble.local}:3478" → "TURN_URL=turn:burble.local:3478"
    assert!(
        env_list.iter().any(|e| e == "TURN_URL=turn:burble.local:3478"),
        "TURN_URL must resolve to default realm; got: {env_list:?}"
    );
}

#[test]
fn burble_selur_with_controlled_env_resolves_realm() {
    let toml = schema_fixture("burble-selur.toml");
    let compose = parse_str(&toml, None).unwrap();

    let resolved = interpolate(compose, &controlled_env()).unwrap();

    let server = resolved.services.get("server").unwrap();
    let env_list = match &server.environment {
        SchemaEnvMap::List(items) => items.clone(),
        _ => panic!("expected list-form environment"),
    };

    // With TURN_REALM=example.com, the URL must embed it.
    assert!(
        env_list.iter().any(|e| e == "TURN_URL=turn:example.com:3478"),
        "TURN_URL must resolve to example.com; got: {env_list:?}"
    );
    assert!(
        env_list.iter().any(|e| e == "TURN_SECRET=hunter2"),
        "TURN_SECRET must resolve; got: {env_list:?}"
    );
}

#[test]
fn burble_selur_coturn_command_passthrough() {
    // Verify the real burble-selur fixture also passes the coturn test.
    let toml = schema_fixture("burble-selur.toml");
    let compose = parse_str(&toml, None).unwrap();

    let resolved = interpolate(compose, &empty_env()).unwrap();

    let coturn = resolved.services.get("coturn").unwrap();
    let cmd_string = match coturn.command.as_ref().unwrap() {
        StringOrList::List(items) => items[0].clone(),
        StringOrList::String(s) => s.clone(),
    };

    assert!(
        cmd_string.contains("$args"),
        "bare $args must be preserved; got: {cmd_string}"
    );
    assert!(
        cmd_string.contains("$TURN_SECRET"),
        "bare $TURN_SECRET must be preserved; got: {cmd_string}"
    );
    assert!(
        cmd_string.contains("$TURN_REALM"),
        "bare $TURN_REALM must be preserved; got: {cmd_string}"
    );
}

// ---------------------------------------------------------------------------
// burble-legacy fixture
// ---------------------------------------------------------------------------

#[test]
fn burble_legacy_interpolates_cleanly() {
    let toml = schema_fixture("burble-legacy.toml");
    let compose = parse_str(&toml, None).unwrap();
    // With empty env, defaults kick in; no undefined errors.
    let resolved = interpolate(compose, &empty_env()).unwrap();
    // The legacy file also has coturn with $args.
    let coturn = resolved.services.get("coturn").unwrap();
    let cmd_string = match coturn.command.as_ref().unwrap() {
        StringOrList::List(items) => items[0].clone(),
        StringOrList::String(s) => s.clone(),
    };
    assert!(cmd_string.contains("$args"), "bare $args must survive; got: {cmd_string}");
}

// ---------------------------------------------------------------------------
// Task 2.7: insta snapshot tests
// ---------------------------------------------------------------------------

#[test]
fn snapshot_burble_selur_controlled_env() {
    let toml = schema_fixture("burble-selur.toml");
    let compose = parse_str(&toml, None).unwrap();
    let resolved = interpolate(compose, &controlled_env()).unwrap();

    // Snapshot the environment of the server service (the most variable-heavy one).
    let server = resolved.services.get("server").unwrap();
    let env_list = match &server.environment {
        SchemaEnvMap::List(items) => items.clone(),
        _ => panic!(),
    };

    insta::assert_debug_snapshot!("burble_selur_server_env_controlled", env_list);
}

#[test]
fn snapshot_burble_selur_default_env() {
    let toml = schema_fixture("burble-selur.toml");
    let compose = parse_str(&toml, None).unwrap();
    let resolved = interpolate(compose, &empty_env()).unwrap();

    let server = resolved.services.get("server").unwrap();
    let env_list = match &server.environment {
        SchemaEnvMap::List(items) => items.clone(),
        _ => panic!(),
    };

    insta::assert_debug_snapshot!("burble_selur_server_env_default", env_list);
}

#[test]
fn snapshot_burble_legacy_default_env() {
    let toml = schema_fixture("burble-legacy.toml");
    let compose = parse_str(&toml, None).unwrap();
    let resolved = interpolate(compose, &empty_env()).unwrap();

    // Legacy file has coturn environment.
    let coturn = resolved.services.get("coturn").unwrap();
    let env_list = match &coturn.environment {
        SchemaEnvMap::List(items) => items.clone(),
        _ => panic!(),
    };

    insta::assert_debug_snapshot!("burble_legacy_coturn_env_default", env_list);
}

#[test]
fn snapshot_coturn_passthrough_fixture() {
    let toml = fixture("coturn_shell_passthrough.toml");
    let compose = parse_str(&toml, None).unwrap();
    let resolved = interpolate(compose, &empty_env()).unwrap();

    let coturn = resolved.services.get("coturn").unwrap();
    let cmd = match coturn.command.as_ref().unwrap() {
        StringOrList::List(items) => items.clone(),
        _ => panic!(),
    };

    insta::assert_debug_snapshot!("coturn_passthrough_command", cmd);
}
