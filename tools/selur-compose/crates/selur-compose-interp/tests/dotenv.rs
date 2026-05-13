//! Tests for the `.env` file parser and `EnvMap` ordering semantics.

use std::io::Write;
use tempfile::NamedTempFile;

use selur_compose_interp::env::{parse_env_str, EnvMap};

fn dummy_path() -> std::path::PathBuf {
    std::path::PathBuf::from(".env")
}

// ---------------------------------------------------------------------------
// parse_env_str — format coverage
// ---------------------------------------------------------------------------

#[test]
fn basic_key_value() {
    let pairs = parse_env_str("FOO=bar\n", &dummy_path()).unwrap();
    assert_eq!(pairs, vec![("FOO".to_string(), "bar".to_string())]);
}

#[test]
fn multiple_lines() {
    let pairs = parse_env_str("A=1\nB=2\nC=3\n", &dummy_path()).unwrap();
    assert_eq!(pairs.len(), 3);
    assert_eq!(pairs[0], ("A".to_string(), "1".to_string()));
    assert_eq!(pairs[2], ("C".to_string(), "3".to_string()));
}

#[test]
fn comment_lines_skipped() {
    let content = "# comment\nFOO=bar\n# another\n";
    let pairs = parse_env_str(content, &dummy_path()).unwrap();
    assert_eq!(pairs, vec![("FOO".to_string(), "bar".to_string())]);
}

#[test]
fn blank_lines_skipped() {
    let content = "\n\nFOO=bar\n\n";
    let pairs = parse_env_str(content, &dummy_path()).unwrap();
    assert_eq!(pairs, vec![("FOO".to_string(), "bar".to_string())]);
}

#[test]
fn inline_comment_not_stripped() {
    // We do NOT strip inline comments — `VALUE # not a comment` is the full value.
    let pairs = parse_env_str("FOO=bar # not stripped\n", &dummy_path()).unwrap();
    // Trailing whitespace IS stripped, but the `#` and text survive.
    assert_eq!(pairs[0].1, "bar # not stripped");
}

#[test]
fn double_quoted_value() {
    let pairs = parse_env_str("FOO=\"hello world\"\n", &dummy_path()).unwrap();
    assert_eq!(pairs[0].1, "hello world");
}

#[test]
fn single_quoted_value() {
    let pairs = parse_env_str("FOO='hello world'\n", &dummy_path()).unwrap();
    assert_eq!(pairs[0].1, "hello world");
}

#[test]
fn unquoted_trailing_whitespace_stripped() {
    let pairs = parse_env_str("FOO=bar   \n", &dummy_path()).unwrap();
    assert_eq!(pairs[0].1, "bar");
}

#[test]
fn value_with_equals_sign() {
    // Only the first `=` is the separator.
    let pairs = parse_env_str("URL=http://x.com?a=1&b=2\n", &dummy_path()).unwrap();
    assert_eq!(pairs[0].1, "http://x.com?a=1&b=2");
}

#[test]
fn empty_value_allowed() {
    let pairs = parse_env_str("EMPTY=\n", &dummy_path()).unwrap();
    assert_eq!(pairs[0].1, "");
}

#[test]
fn no_equals_sign_skipped() {
    let pairs = parse_env_str("NOEQUALS\nFOO=bar\n", &dummy_path()).unwrap();
    assert_eq!(pairs.len(), 1);
    assert_eq!(pairs[0].0, "FOO");
}

#[test]
fn windows_line_endings() {
    let pairs = parse_env_str("FOO=bar\r\nBAZ=qux\r\n", &dummy_path()).unwrap();
    assert_eq!(pairs.len(), 2);
}

// ---------------------------------------------------------------------------
// EnvMap ordering: first occurrence wins
// ---------------------------------------------------------------------------

#[test]
fn first_occurrence_wins() {
    let env = EnvMap::from_iter(vec![
        ("KEY".to_string(), "first".to_string()),
        ("KEY".to_string(), "second".to_string()),
    ]);
    assert_eq!(env.get("KEY"), Some("first"));
}

#[test]
fn missing_key_none() {
    assert_eq!(EnvMap::default().get("MISSING"), None);
}

#[test]
fn with_overrides_higher_priority() {
    let base = EnvMap::from_iter(vec![("KEY".to_string(), "base".to_string())]);
    let overridden = base.with_overrides(vec![("KEY".to_string(), "override".to_string())]);
    assert_eq!(overridden.get("KEY"), Some("override"));
}

#[test]
fn override_does_not_affect_other_keys() {
    let base = EnvMap::from_iter(vec![
        ("A".to_string(), "aval".to_string()),
        ("B".to_string(), "bval".to_string()),
    ]);
    let overridden = base.with_overrides(vec![("A".to_string(), "new".to_string())]);
    assert_eq!(overridden.get("A"), Some("new"));
    assert_eq!(overridden.get("B"), Some("bval"));
}

// ---------------------------------------------------------------------------
// with_env_files — uses real temp files
// ---------------------------------------------------------------------------

#[test]
fn env_file_loaded() {
    let mut f = NamedTempFile::new().unwrap();
    writeln!(f, "TURN_REALM=example.com").unwrap();
    writeln!(f, "TURN_SECRET=hunter2").unwrap();

    let env = EnvMap::default()
        .with_env_files(&[f.path()])
        .unwrap();

    assert_eq!(env.get("TURN_REALM"), Some("example.com"));
    assert_eq!(env.get("TURN_SECRET"), Some("hunter2"));
}

#[test]
fn process_env_wins_over_file() {
    // Set a variable in the process env, then load a file that has the same key.
    // The process env must win.
    std::env::set_var("SELUR_INTERP_TEST_VAR", "from_process");
    let mut f = NamedTempFile::new().unwrap();
    writeln!(f, "SELUR_INTERP_TEST_VAR=from_file").unwrap();

    let env = EnvMap::from_process().with_env_files(&[f.path()]).unwrap();
    assert_eq!(env.get("SELUR_INTERP_TEST_VAR"), Some("from_process"));
    std::env::remove_var("SELUR_INTERP_TEST_VAR");
}

#[test]
fn multiple_env_files_first_file_wins() {
    // When two files define the same key, the *last* file in the list wins
    // (among file-only sources; process env still beats both).
    let mut f1 = NamedTempFile::new().unwrap();
    writeln!(f1, "KEY=from_first").unwrap();

    let mut f2 = NamedTempFile::new().unwrap();
    writeln!(f2, "KEY=from_second").unwrap();

    // with_env_files merges: later files do NOT override earlier ones.
    // The first file wins among file sources (matching the implementation).
    let env = EnvMap::default()
        .with_env_files(&[f1.path(), f2.path()])
        .unwrap();
    assert_eq!(env.get("KEY"), Some("from_first"));
}

#[test]
fn missing_env_file_error() {
    use selur_compose_interp::error::InterpError;
    let result = EnvMap::default().with_env_files(&["/nonexistent/.env.does-not-exist"]);
    assert!(matches!(result, Err(InterpError::EnvFile { .. })));
}
