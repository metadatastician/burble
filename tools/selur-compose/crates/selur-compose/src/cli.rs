//! Clap-derive CLI definition for `selur-compose`.
//!
//! Global flags and all eight v0.1.0 subcommands are defined here.
//! Driver-dependent subcommands (`up`, `down`, `build`, `pull`, `ps`, `logs`)
//! have their arguments fully defined but their implementations are stubbed
//! with `unimplemented!()` pending Phase 4 handoff.

use std::path::PathBuf;

use clap::{Parser, Subcommand, ValueEnum};

// ---------------------------------------------------------------------------
// Top-level CLI
// ---------------------------------------------------------------------------

/// TOML-native compose CLI for Podman.
///
/// Reads `selur-compose.toml` (fallback: `compose.toml`) and drives Podman 5.4+
/// rootless to bring up, tear down, build, and observe a container stack.
#[derive(Debug, Parser)]
#[command(
    name = "selur-compose",
    version,
    about = "TOML-native compose CLI for Podman",
    long_about = None,
    disable_help_subcommand = false,
)]
pub struct Cli {
    /// Compose file path.  Defaults to `selur-compose.toml`, then `compose.toml`.
    #[arg(short = 'f', long = "file", global = true, value_name = "PATH")]
    pub file: Option<PathBuf>,

    /// Override project name (default: value of `[project].name` in the compose file).
    #[arg(short = 'p', long = "project-name", global = true, value_name = "NAME")]
    pub project_name: Option<String>,

    /// Additional env files to load (may be specified multiple times).
    #[arg(long = "env-file", global = true, value_name = "PATH", action = clap::ArgAction::Append)]
    pub env_file: Vec<PathBuf>,

    /// Enable a compose profile (may be specified multiple times).
    #[arg(long = "profile", global = true, value_name = "NAME", action = clap::ArgAction::Append)]
    pub profile: Vec<String>,

    /// Verbose output.  Pass twice (`-vv`) for debug-level output.
    #[arg(short = 'v', long = "verbose", global = true, action = clap::ArgAction::Count)]
    pub verbose: u8,

    /// Suppress non-error output.
    #[arg(short = 'q', long = "quiet", global = true)]
    pub quiet: bool,

    /// Output format.
    #[arg(long = "format", global = true, value_name = "FORMAT", default_value = "text")]
    pub format: Format,

    /// Simulate execution without making any changes (deferred: requires Driver impl).
    #[arg(long = "dry-run", global = true)]
    pub dry_run: bool,

    #[command(subcommand)]
    pub command: Command,
}

// ---------------------------------------------------------------------------
// Output format
// ---------------------------------------------------------------------------

/// Output format for commands that produce structured data.
#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum Format {
    /// Human-readable text tables.
    Text,
    /// Machine-readable JSON.
    Json,
}

// ---------------------------------------------------------------------------
// Subcommands
// ---------------------------------------------------------------------------

#[derive(Debug, Subcommand)]
pub enum Command {
    /// Bring the stack up (requires Driver — stub).
    Up(UpArgs),
    /// Tear the stack down (requires Driver — stub).
    Down(DownArgs),
    /// Build service images (requires Driver — stub).
    Build(BuildArgs),
    /// Pull service images (requires Driver — stub).
    Pull(PullArgs),
    /// List running containers (requires Driver — stub).
    Ps(PsArgs),
    /// Tail service logs (requires Driver — stub).
    Logs(LogsArgs),
    /// Print the parsed + interpolated compose config.
    Config(ConfigArgs),
    /// Print selur-compose and Podman version information.
    Version,
}

// ---------------------------------------------------------------------------
// `up` args
// ---------------------------------------------------------------------------

/// Arguments for the `up` subcommand.
#[derive(Debug, Parser)]
pub struct UpArgs {
    /// Run containers in the background (detached mode).
    #[arg(short = 'd', long = "detach")]
    pub detach: bool,

    /// Build images before starting containers.
    #[arg(long = "build")]
    pub build: bool,

    /// Do not build images even if they are missing.
    #[arg(long = "no-build")]
    pub no_build: bool,

    /// Do not pull images before starting.
    #[arg(long = "no-pull")]
    pub no_pull: bool,

    /// Recreate containers even if their config has not changed.
    #[arg(long = "force-recreate")]
    pub force_recreate: bool,

    /// Stop and remove containers for services not defined in the compose file.
    #[arg(long = "remove-orphans")]
    pub remove_orphans: bool,

    /// Limit to specific services.
    #[arg(value_name = "SERVICE")]
    pub services: Vec<String>,
}

// ---------------------------------------------------------------------------
// `down` args
// ---------------------------------------------------------------------------

/// Arguments for the `down` subcommand.
#[derive(Debug, Parser)]
pub struct DownArgs {
    /// Remove named volumes declared in the compose file.
    #[arg(long = "volumes")]
    pub volumes: bool,

    /// Remove images.  `local` removes only images built by compose; `all` removes all.
    #[arg(long = "rmi", value_name = "SCOPE")]
    pub rmi: Option<String>,

    /// Also stop and remove containers for services not in the compose file.
    #[arg(long = "remove-orphans")]
    pub remove_orphans: bool,

    /// Timeout in seconds to wait for containers to stop (default: 10).
    #[arg(long = "timeout", value_name = "SECONDS", default_value = "10")]
    pub timeout: u32,
}

// ---------------------------------------------------------------------------
// `build` args
// ---------------------------------------------------------------------------

/// Arguments for the `build` subcommand.
#[derive(Debug, Parser)]
pub struct BuildArgs {
    /// Do not use the image cache.
    #[arg(long = "no-cache")]
    pub no_cache: bool,

    /// Always attempt to pull a newer version of the base image.
    #[arg(long = "pull")]
    pub pull: bool,

    /// Limit to specific services.
    #[arg(value_name = "SERVICE")]
    pub services: Vec<String>,
}

// ---------------------------------------------------------------------------
// `pull` args
// ---------------------------------------------------------------------------

/// Arguments for the `pull` subcommand.
#[derive(Debug, Parser)]
pub struct PullArgs {
    /// Limit to specific services.
    #[arg(value_name = "SERVICE")]
    pub services: Vec<String>,
}

// ---------------------------------------------------------------------------
// `ps` args
// ---------------------------------------------------------------------------

/// Arguments for the `ps` subcommand.
#[derive(Debug, Parser)]
pub struct PsArgs {
    /// Show all containers, including stopped ones.
    #[arg(short = 'a', long = "all")]
    pub all: bool,

    /// Only show container IDs.
    #[arg(short = 'q', long = "quiet")]
    pub quiet: bool,
}

// ---------------------------------------------------------------------------
// `logs` args
// ---------------------------------------------------------------------------

/// Arguments for the `logs` subcommand.
#[derive(Debug, Parser)]
pub struct LogsArgs {
    /// Follow log output.
    #[arg(short = 'f', long = "follow")]
    pub follow: bool,

    /// Number of lines to show from the end of the log.
    #[arg(long = "tail", value_name = "N")]
    pub tail: Option<u64>,

    /// Limit to specific services.
    #[arg(value_name = "SERVICE")]
    pub services: Vec<String>,
}

// ---------------------------------------------------------------------------
// `config` args
// ---------------------------------------------------------------------------

/// Arguments for the `config` subcommand.
#[derive(Debug, Parser)]
pub struct ConfigArgs {
    /// Config-specific output format: `toml` (default) or `json`.
    /// Overrides the global `--format` flag for the `config` subcommand.
    #[arg(long = "output", value_name = "FORMAT")]
    pub output: Option<ConfigFormat>,
}

/// Format for `config` output.
#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum ConfigFormat {
    /// Emit pretty TOML (default).
    Toml,
    /// Emit JSON.
    Json,
}
