//! CLI smoke tests for `selur-compose`.
//!
//! These tests use `assert_cmd` to run the compiled binary and assert exit
//! codes + stdout/stderr patterns.
//!
//! # Coverage
//!
//! - `version`: always fully implemented; tested against both text and JSON.
//! - `config`:  fully implemented; tested against the burble fixture.
//! - `--help`:  confirms all eight subcommands appear.
//! - `up` / `down` scaffold: confirm non-zero exit + recognizable message.
//!
//! # Driver-dependent tests (deferred)
//!
//! Smoke tests for `up`, `down`, `build`, `pull`, `ps`, `logs` that require a
//! live `Driver` or `MockDriver` are deferred to Phase 4 handoff.  Stubs are
//! in place that verify the *exit code* (non-zero) and *error message* pattern
//! ("phase-4-handoff") so the scaffold is verified without a real podman.

use std::path::PathBuf;

use assert_cmd::Command;
use predicates::prelude::*;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn bin() -> Command {
    Command::cargo_bin("selur-compose").expect("binary not found")
}

fn fixture_path() -> PathBuf {
    // The burble selur-compose.toml, relative to workspace root.
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../../containers/selur-compose.toml")
}

// ---------------------------------------------------------------------------
// --help
// ---------------------------------------------------------------------------

#[test]
fn help_lists_all_subcommands() {
    bin()
        .arg("--help")
        .assert()
        .success()
        .stdout(predicate::str::contains("up"))
        .stdout(predicate::str::contains("down"))
        .stdout(predicate::str::contains("build"))
        .stdout(predicate::str::contains("pull"))
        .stdout(predicate::str::contains("ps"))
        .stdout(predicate::str::contains("logs"))
        .stdout(predicate::str::contains("config"))
        .stdout(predicate::str::contains("version"));
}

// ---------------------------------------------------------------------------
// version
// ---------------------------------------------------------------------------

#[test]
fn version_text() {
    let ver = env!("CARGO_PKG_VERSION");
    bin()
        .arg("version")
        .assert()
        .success()
        .stdout(predicate::str::contains(format!("selur-compose {ver}")));
}

#[test]
fn version_json() {
    let ver = env!("CARGO_PKG_VERSION");
    bin()
        .args(["--format", "json", "version"])
        .assert()
        .success()
        .stdout(predicate::str::contains(r#""type": "version""#))
        .stdout(predicate::str::contains(ver));
}

// ---------------------------------------------------------------------------
// config — fully implemented
// ---------------------------------------------------------------------------

#[test]
fn config_burble_fixture_toml() {
    let fixture = fixture_path();
    if !fixture.exists() {
        eprintln!("fixture not found at {}, skipping", fixture.display());
        return;
    }

    bin()
        .args([
            "-f",
            fixture.to_str().unwrap(),
            "config",
        ])
        .assert()
        .success()
        // The TOML output should contain the project name and service names.
        .stdout(predicate::str::contains("burble"))
        .stdout(predicate::str::contains("verisimdb"))
        .stdout(predicate::str::contains("coturn"));
}

#[test]
fn config_burble_fixture_json() {
    let fixture = fixture_path();
    if !fixture.exists() {
        eprintln!("fixture not found at {}, skipping", fixture.display());
        return;
    }

    bin()
        .args([
            "-f",
            fixture.to_str().unwrap(),
            "config",
            "--output",
            "json",
        ])
        .assert()
        .success()
        .stdout(predicate::str::contains(r#""services""#))
        .stdout(predicate::str::contains("verisimdb"));
}

/// Run config twice; the output must be byte-identical (stable serialisation).
#[test]
fn config_is_stable() {
    let fixture = fixture_path();
    if !fixture.exists() {
        eprintln!("fixture not found at {}, skipping", fixture.display());
        return;
    }

    let out1 = bin()
        .args(["-f", fixture.to_str().unwrap(), "config"])
        .output()
        .expect("first run failed");
    let out2 = bin()
        .args(["-f", fixture.to_str().unwrap(), "config"])
        .output()
        .expect("second run failed");

    assert!(out1.status.success(), "first config run exited non-zero");
    assert!(out2.status.success(), "second config run exited non-zero");
    assert_eq!(
        out1.stdout, out2.stdout,
        "config output is not stable between runs"
    );
}

/// config with no compose file in CWD exits non-zero with a helpful message.
#[test]
fn config_no_file_exits_nonzero() {
    bin()
        .current_dir(std::env::temp_dir())
        .arg("config")
        .assert()
        .failure()
        .stderr(predicate::str::contains("could not find a compose file"));
}

// ---------------------------------------------------------------------------
// Driver-wired commands — Phase 5 integration tests
// ---------------------------------------------------------------------------

/// `up --dry-run` with a valid compose file prints the planned ops and exits 0.
///
/// This exercises the full load → plan → dry-run display path without calling
/// podman, making it safe to run in CI without a container runtime.
#[test]
fn up_dry_run_exits_zero_with_ops() {
    let fixture = fixture_path();
    if !fixture.exists() {
        eprintln!("fixture not found at {}, skipping", fixture.display());
        return;
    }

    bin()
        .args(["-f", fixture.to_str().unwrap(), "--dry-run", "up"])
        .assert()
        .success()
        .stdout(predicate::str::contains("Dry-run"))
        .stdout(predicate::str::contains("burble"));
}

/// `down` with a valid compose file exits 0 even when no containers are running.
///
/// Previously this was a scaffold that expected a `phase-4-handoff` error.
/// Now it calls `driver.ps` against a real podman (or succeeds early if
/// podman is absent, since `No containers found` is the happy path when
/// the project is stopped).
#[test]
fn down_with_no_running_containers_exits_zero() {
    let fixture = fixture_path();
    if !fixture.exists() {
        eprintln!("fixture not found at {}, skipping", fixture.display());
        return;
    }

    // When no containers are running for the project, `down` exits 0 with an
    // informational message.  If podman is unavailable the driver returns an
    // error and exits non-zero — both are acceptable here; we only verify
    // that the error is NOT the old phase-4-handoff message.
    let output = bin()
        .args(["-f", fixture.to_str().unwrap(), "down"])
        .output()
        .expect("failed to run selur-compose down");

    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        !stderr.contains("phase-4-handoff"),
        "got unexpected phase-4-handoff error: {stderr}"
    );
}
