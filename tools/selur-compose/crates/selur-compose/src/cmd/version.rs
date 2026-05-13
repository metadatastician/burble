//! `selur-compose version` — print version information.
//!
//! Prints the package version and the version of the `podman` binary found
//! in `$PATH`.  The podman version is obtained by running `podman --version`
//! and parsing its stdout.  If `podman` is not found or returns an error, we
//! print `"unknown"` rather than failing hard — version is a read-only check.

use std::process::Command as StdCommand;

use anyhow::Result;

use crate::{cli::Format, output::print_version};

/// Package version, baked in at compile time by Cargo.
const PKG_VERSION: &str = env!("CARGO_PKG_VERSION");

pub fn run(format: Format) -> Result<()> {
    let podman_ver = query_podman_version();
    print_version(PKG_VERSION, &podman_ver, format);
    Ok(())
}

/// Run `podman --version` and extract the version string.
///
/// Returns `"unknown"` on any failure (binary not found, non-zero exit, parse
/// error) so that `version` never fails even on machines without podman.
fn query_podman_version() -> String {
    let output = StdCommand::new("podman").arg("--version").output();
    match output {
        Err(_) => "unknown (podman not found in PATH)".to_string(),
        Ok(out) if !out.status.success() => {
            format!("unknown (podman exited {})", out.status)
        }
        Ok(out) => {
            // stdout is typically "podman version 5.4.2\n"
            let raw = String::from_utf8_lossy(&out.stdout);
            raw.split_whitespace()
                .last()
                .unwrap_or("unknown")
                .trim()
                .to_string()
        }
    }
}
