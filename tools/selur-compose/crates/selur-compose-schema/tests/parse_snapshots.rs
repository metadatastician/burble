//! insta snapshot tests for the parsed `Compose` debug representation.
//!
//! On first run, snapshots are written to `tests/snapshots/`.
//! Review and accept them with `cargo insta review` (or `just snapshot-review`).

use selur_compose_schema::parse_str;
use std::path::Path;

#[test]
fn snapshot_burble_selur() {
    let src = include_str!("fixtures/valid/burble-selur.toml");
    let compose = parse_str(src, Some(Path::new("burble-selur.toml"))).unwrap();
    insta::assert_debug_snapshot!("burble_selur", compose);
}

#[test]
fn snapshot_burble_legacy() {
    let src = include_str!("fixtures/valid/burble-legacy.toml");
    let compose = parse_str(src, Some(Path::new("burble-legacy.toml"))).unwrap();
    insta::assert_debug_snapshot!("burble_legacy", compose);
}

#[test]
fn snapshot_boj_server() {
    let src = include_str!("fixtures/valid/boj-server.toml");
    let compose = parse_str(src, Some(Path::new("boj-server.toml"))).unwrap();
    insta::assert_debug_snapshot!("boj_server", compose);
}
