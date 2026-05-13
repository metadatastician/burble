//! Low-level podman subprocess runner.
//!
//! [`run_podman`] is the single choke-point through which all `podman`
//! invocations flow.  It captures stdout and stderr, checks the exit code, and
//! maps failures to [`DriverError::Podman`].

use std::process::Output;

use tokio::process::Command;

use crate::{DriverError, Result};

/// Invoke `podman` with the given argument vector and capture its output.
///
/// # Arguments
///
/// `argv` — the full argument list, **including** `"podman"` as element 0.
/// The function forwards elements `argv[1..]` to the process.
///
/// # Errors
///
/// - [`DriverError::Io`] — if the process could not be spawned (e.g. `podman`
///   not found on `$PATH`, or a file-system error).
/// - [`DriverError::Podman`] — if the process exits with a non-zero status.
///
/// # Returns
///
/// The raw [`std::process::Output`] on success (exit code == 0).
pub async fn run_podman(argv: &[String]) -> Result<Output> {
    let program = argv.first().map(|s| s.as_str()).unwrap_or("podman");
    let args = argv.get(1..).unwrap_or(&[]);

    let output = Command::new(program)
        .args(args)
        .output()
        .await
        .map_err(DriverError::Io)?;

    if output.status.success() {
        Ok(output)
    } else {
        let code = output.status.code().unwrap_or(-1);
        let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
        Err(DriverError::Podman {
            argv: argv.to_vec(),
            code,
            stderr,
        })
    }
}

/// Attempt to detect the "permission denied" EACCES pattern in podman stderr
/// that occurs when a rootless process tries to bind a privileged port (<1024).
///
/// Returns `Some(port)` if the pattern is matched, `None` otherwise.
pub fn detect_privileged_port(stderr: &str) -> Option<u16> {
    // Podman/netavark typically emits one of:
    //   "Error: rootlessport cannot expose privileged port 80, …"
    //   "Error: listen tcp 0.0.0.0:80: bind: permission denied"
    //   "EACCES: permission denied trying to bind :443"
    //
    // We search for tokens containing a colon-prefixed numeric fragment
    // while also requiring a "permission denied" or "EACCES" substring.
    if !stderr.contains("permission denied") && !stderr.contains("EACCES") {
        return None;
    }

    for token in stderr.split_whitespace() {
        // Strip trailing punctuation
        let token = token.trim_end_matches([',', '.', ';', ':']);
        // Extract the last colon-separated segment that is purely numeric
        if let Some(portstr) = token.rsplit(':').next() {
            if let Ok(port) = portstr.parse::<u16>() {
                if port < 1024 {
                    return Some(port);
                }
            }
        }
    }
    None
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_run_podman_echo_succeeds() {
        // Use /bin/echo as a stand-in — always present and always exits 0.
        let argv: Vec<String> = vec![
            "/bin/echo".to_string(),
            "hello".to_string(),
            "world".to_string(),
        ];
        let out = run_podman(&argv).await.expect("echo should succeed");
        let stdout = String::from_utf8_lossy(&out.stdout);
        assert!(stdout.contains("hello"));
    }

    #[tokio::test]
    async fn test_run_podman_nonzero_exit() {
        // `false` always exits 1.
        let argv: Vec<String> = vec!["/bin/false".to_string()];
        let err = run_podman(&argv).await.unwrap_err();
        assert!(
            matches!(err, DriverError::Podman { code: 1, .. }),
            "expected Podman error with code 1, got {err:?}"
        );
    }

    #[test]
    fn test_detect_privileged_port_found() {
        let stderr = "Error: rootlessport cannot expose privileged port 80, \
                      you can add 'net.ipv4.ip_unprivileged_port_start=80' to \
                      /etc/sysctl.d/: listen tcp 0.0.0.0:80: bind: permission denied";
        assert_eq!(detect_privileged_port(stderr), Some(80));
    }

    #[test]
    fn test_detect_privileged_port_not_found_high_port() {
        // Port 8080 is not privileged — should not match even with permission denied.
        let stderr = "Error: listen tcp 0.0.0.0:8080: bind: permission denied";
        assert_eq!(detect_privileged_port(stderr), None);
    }

    #[test]
    fn test_detect_privileged_port_eacces() {
        let stderr = "EACCES: permission denied trying to bind :443";
        assert_eq!(detect_privileged_port(stderr), Some(443));
    }

    #[test]
    fn test_detect_privileged_port_no_permission_message() {
        // Has a low port but no "permission denied" — should not match.
        let stderr = "Something went wrong with port 22 (unrelated)";
        assert_eq!(detect_privileged_port(stderr), None);
    }
}
