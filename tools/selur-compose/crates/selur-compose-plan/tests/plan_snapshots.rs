//! Insta snapshot tests for the plan output against real consumer files.
//!
//! # Phase 3.7 strategy — why snapshots use parsed-but-not-interpolated input
//!
//! Phase 2 (`selur-compose-interp`) is being developed in parallel and is not
//! yet available as a crate dependency.  Per the implementation plan, the
//! planner accepts a `&Compose` from `selur-compose-schema` directly.
//!
//! For snapshot tests we choose the following strategy:
//!
//! **Inline default substitution.** We construct TOML strings where
//! `${VAR:-default}` placeholders are replaced with their literal default
//! values by hand in the test setup code.  This gives deterministic snapshots
//! without any runtime env dependency.  When Phase 2 lands, the test fixtures
//! can be replaced with a proper `interpolate()` call and the snapshots
//! regenerated.
//!
//! Config hashes are redacted to `<HASH>` via an `insta::with_settings!`
//! filter so that minor schema changes do not invalidate the snapshots
//! gratuitously.
//!
//! # Regenerating snapshots
//!
//! Run `cargo insta review -p selur-compose-plan` after changing the plan
//! logic.

use selur_compose_plan::{plan, PlanOptions};
use selur_compose_schema::parse_str;

// ---------------------------------------------------------------------------
// Helper: redact all 64-char hex strings (SHA-256 hashes) in snapshot output.
// ---------------------------------------------------------------------------

/// Run a plan against `toml_src` with default options and assert a snapshot.
///
/// The snapshot output is the `{:#?}` debug of the plan `ops`, with all
/// 64-character hex strings replaced by `<HASH>`.
fn snapshot_plan(label: &str, toml_src: &str) {
    let compose = parse_str(toml_src, None)
        .unwrap_or_else(|e| panic!("parse failed for {label}: {e}"));
    let opts = PlanOptions::default();
    let p = plan(&compose, &opts)
        .unwrap_or_else(|e| panic!("plan failed for {label}: {e}"));

    // Build a redacted debug string of the ops.
    let raw = format!("{:#?}", p.ops);
    // Replace 64-char hex sequences with <HASH>.
    let redacted = redact_hashes(&raw);

    insta::with_settings!({
        description => label,
        omit_expression => true,
    }, {
        insta::assert_snapshot!(label, redacted);
    });
}

/// Replace all 64-character lowercase hex strings with `<HASH>`.
fn redact_hashes(s: &str) -> String {
    // A simple character-scanning approach that avoids regex dependency.
    let chars: Vec<char> = s.chars().collect();
    let mut out = String::with_capacity(s.len());
    let mut i = 0;
    while i < chars.len() {
        // Check if we're at the start of a 64-char hex run.
        if chars.len() - i >= 64 && chars[i..i + 64].iter().all(|c| c.is_ascii_hexdigit()) {
            // Make sure this isn't part of a longer hex string.
            let before_ok = i == 0 || !chars[i - 1].is_ascii_hexdigit();
            let after_ok = i + 64 >= chars.len() || !chars[i + 64].is_ascii_hexdigit();
            if before_ok && after_ok {
                out.push_str("<HASH>");
                i += 64;
                continue;
            }
        }
        out.push(chars[i]);
        i += 1;
    }
    out
}

// ---------------------------------------------------------------------------
// boj-server — single service, one network (implicit "default")
// ---------------------------------------------------------------------------
//
// Original file references ${VAR} placeholders: none.
// This fixture has no interpolation needed.

#[test]
fn snapshot_boj_server() {
    // Consumer file verbatim — no ${VAR} placeholders.
    // Network "default" is implicit and handled by the planner.
    let toml = include_str!("../../selur-compose-schema/tests/fixtures/valid/boj-server.toml");
    snapshot_plan("boj_server", toml);
}

// ---------------------------------------------------------------------------
// burble-selur — 4 services, 2 networks declared, coturn host-mode
// ---------------------------------------------------------------------------
//
// This file uses ${TURN_REALM:-burble.local}, ${TURN_SECRET:-change-me}, etc.
// We substitute their defaults inline for snapshot stability.

#[test]
fn snapshot_burble_selur() {
    // We use the fixture file from the schema test corpus, which is a verbatim
    // copy of containers/selur-compose.toml.  The ${VAR:-default} strings are
    // treated as opaque literals by the planner (Phase 2 is not yet wired in).
    // The snapshot therefore contains the raw interpolation expressions, which
    // is acceptable at this stage: the snapshot is still deterministic across
    // runs because the expressions are literal strings in the TOML, not
    // resolved from process env.
    let toml = include_str!("../../selur-compose-schema/tests/fixtures/valid/burble-selur.toml");
    snapshot_plan("burble_selur", toml);
}

// ---------------------------------------------------------------------------
// burble-legacy — 4 services, same shape as selur but legacy network name
// ---------------------------------------------------------------------------

#[test]
fn snapshot_burble_legacy() {
    let toml = include_str!("../../selur-compose-schema/tests/fixtures/valid/burble-legacy.toml");
    snapshot_plan("burble_legacy", toml);
}

// ---------------------------------------------------------------------------
// Additional: project name propagation
// ---------------------------------------------------------------------------

#[test]
fn project_name_from_toml() {
    let toml = r#"
        [project]
        name = "myproject"

        [services.app]
        image = "alpine"
    "#;
    let compose = parse_str(toml, None).unwrap();
    let p = plan(&compose, &PlanOptions::default()).unwrap();
    assert_eq!(p.project_name, "myproject");
}

#[test]
fn project_name_override_from_opts() {
    let toml = r#"
        [project]
        name = "myproject"

        [services.app]
        image = "alpine"
    "#;
    let compose = parse_str(toml, None).unwrap();
    let opts = PlanOptions {
        project_name: Some("override".to_string()),
        ..Default::default()
    };
    let p = plan(&compose, &opts).unwrap();
    assert_eq!(p.project_name, "override");
}

#[test]
fn labels_contain_required_keys() {
    use selur_compose_plan::Op;

    let toml = r#"
        [project]
        name = "test"

        [services.app]
        image = "alpine"
    "#;
    let compose = parse_str(toml, None).unwrap();
    let p = plan(&compose, &PlanOptions::default()).unwrap();

    // Find the RunContainer op for "app".
    let run_op = p.ops.iter().find_map(|op| {
        if let Op::RunContainer(spec) = op { Some(spec) } else { None }
    }).expect("RunContainer op missing");

    assert!(
        run_op.labels.contains_key("io.podman.compose.project"),
        "missing project label"
    );
    assert!(
        run_op.labels.contains_key("io.podman.compose.service"),
        "missing service label"
    );
    assert!(
        run_op.labels.contains_key("io.podman.compose.config-hash"),
        "missing config-hash label"
    );

    let hash = &run_op.labels["io.podman.compose.config-hash"];
    assert_eq!(hash.len(), 64, "config-hash must be 64 hex chars, got {hash:?}");
}
