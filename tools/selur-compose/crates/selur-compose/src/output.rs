//! Shared output formatters for `selur-compose` subcommands.
//!
//! All structured output goes through this module so that `--format json`
//! works uniformly across commands.
//!
//! # JSON schema
//!
//! See `docs/cli-json-schema.adoc` in the workspace root for the documented
//! JSON output schema.  Each command that produces JSON output uses a distinct
//! top-level `type` discriminant.
//!
//! ## `ps` output
//!
//! ```json
//! {
//!   "type": "ps",
//!   "containers": [
//!     {
//!       "service":      "web",
//!       "container_id": "abc123…",
//!       "image":        "burble_web:latest",
//!       "status":       "Up 3 minutes (healthy)",
//!       "ports":        "0.0.0.0:4020->80/tcp"
//!     }
//!   ]
//! }
//! ```
//!
//! ## `version` output
//!
//! ```json
//! {
//!   "type": "version",
//!   "selur_compose": "0.1.0",
//!   "podman":        "5.4.2"
//! }
//! ```
//!
//! ## `config` output
//!
//! The config command emits either pretty TOML (text) or the raw `Compose`
//! struct serialised to JSON (json mode).  No wrapper type discriminant.

use serde::Serialize;

use crate::cli::Format;

// ---------------------------------------------------------------------------
// Container summary (used by `ps`)
// ---------------------------------------------------------------------------

/// A single row in `selur-compose ps` output.
#[derive(Debug, Clone, Serialize)]
pub struct ContainerRow {
    pub service:      String,
    pub container_id: String,
    pub image:        String,
    pub status:       String,
    pub ports:        String,
}

// ---------------------------------------------------------------------------
// ps formatter
// ---------------------------------------------------------------------------

/// Print a list of container rows to stdout.
pub fn print_ps(rows: &[ContainerRow], format: Format) {
    match format {
        Format::Json => {
            #[derive(Serialize)]
            struct PsOutput<'a> {
                #[serde(rename = "type")]
                kind:       &'static str,
                containers: &'a [ContainerRow],
            }
            let out = PsOutput { kind: "ps", containers: rows };
            println!("{}", serde_json::to_string_pretty(&out).expect("json serialisation"));
        }
        Format::Text => {
            if rows.is_empty() {
                println!("No containers running.");
                return;
            }
            // Simple aligned text table without an external dep.
            let w_svc  = rows.iter().map(|r| r.service.len()).max().unwrap_or(7).max(7);
            let w_id   = rows.iter().map(|r| r.container_id.len().min(12)).max().unwrap_or(12).max(12);
            let w_img  = rows.iter().map(|r| r.image.len()).max().unwrap_or(5).max(5);
            let w_stat = rows.iter().map(|r| r.status.len()).max().unwrap_or(6).max(6);

            println!(
                "{:<w_svc$}  {:<w_id$}  {:<w_img$}  {:<w_stat$}  PORTS",
                "SERVICE", "CONTAINER ID", "IMAGE", "STATUS",
                w_svc = w_svc, w_id = w_id, w_img = w_img, w_stat = w_stat,
            );
            println!(
                "{:-<w_svc$}  {:-<w_id$}  {:-<w_img$}  {:-<w_stat$}  -----",
                "", "", "", "",
                w_svc = w_svc, w_id = w_id, w_img = w_img, w_stat = w_stat,
            );
            for row in rows {
                println!(
                    "{:<w_svc$}  {:<w_id$}  {:<w_img$}  {:<w_stat$}  {}",
                    row.service,
                    &row.container_id[..row.container_id.len().min(12)],
                    row.image,
                    row.status,
                    row.ports,
                    w_svc = w_svc, w_id = w_id, w_img = w_img, w_stat = w_stat,
                );
            }
        }
    }
}

// ---------------------------------------------------------------------------
// up summary formatter
// ---------------------------------------------------------------------------

/// Print a post-`up` summary table (service, container id, status, ports).
///
/// Reuses the same column layout as [`print_ps`].
pub fn print_summary(rows: &[ContainerRow], format: Format) {
    print_ps(rows, format);
}

// ---------------------------------------------------------------------------
// version formatter
// ---------------------------------------------------------------------------

/// Print version information.
pub fn print_version(selur_compose_ver: &str, podman_ver: &str, format: Format) {
    match format {
        Format::Json => {
            #[derive(Serialize)]
            struct VersionOutput<'a> {
                #[serde(rename = "type")]
                kind:          &'static str,
                selur_compose: &'a str,
                podman:        &'a str,
            }
            let out = VersionOutput {
                kind:          "version",
                selur_compose: selur_compose_ver,
                podman:        podman_ver,
            };
            println!("{}", serde_json::to_string_pretty(&out).expect("json serialisation"));
        }
        Format::Text => {
            println!("selur-compose {selur_compose_ver}");
            println!("podman        {podman_ver}");
        }
    }
}

// ---------------------------------------------------------------------------
// error formatter
// ---------------------------------------------------------------------------

/// Print an `anyhow` error chain to stderr, respecting `--format json`.
pub fn print_error(err: &anyhow::Error, format: Format) {
    match format {
        Format::Json => {
            #[derive(Serialize)]
            struct ErrOutput {
                #[serde(rename = "type")]
                kind:  &'static str,
                error: String,
                chain: Vec<String>,
            }
            let chain = err.chain().skip(1).map(|e| e.to_string()).collect();
            let out = ErrOutput { kind: "error", error: err.to_string(), chain };
            eprintln!("{}", serde_json::to_string_pretty(&out).expect("json serialisation"));
        }
        Format::Text => {
            eprintln!("error: {err:#}");
        }
    }
}
