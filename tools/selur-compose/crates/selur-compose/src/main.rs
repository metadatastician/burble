//! `selur-compose` — TOML-native compose CLI for Podman.
//!
//! Entry point.  Parses global flags, initialises tracing, dispatches to the
//! relevant subcommand, and converts `anyhow::Error` to an appropriate exit
//! code with a human- or machine-readable error message.

mod cli;
mod cmd;
mod load;
mod output;

use clap::Parser;
use tracing_subscriber::{fmt, prelude::*, EnvFilter};

use cli::{Cli, Command};
use output::print_error;

#[tokio::main]
async fn main() {
    let cli = Cli::parse();

    // -----------------------------------------------------------------------
    // Tracing / logging setup (task 5.13)
    //
    //   default  → WARN
    //   -v       → INFO
    //   -vv      → DEBUG
    //   -q       → ERROR
    // -----------------------------------------------------------------------
    let default_level = if cli.quiet {
        "error"
    } else {
        match cli.verbose {
            0 => "warn",
            1 => "info",
            _ => "debug",
        }
    };

    let filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new(default_level));

    tracing_subscriber::registry()
        .with(fmt::layer().with_writer(std::io::stderr))
        .with(filter)
        .init();

    // -----------------------------------------------------------------------
    // Dispatch
    // -----------------------------------------------------------------------
    let format = cli.format;
    let result = dispatch(&cli).await;

    if let Err(err) = result {
        print_error(&err, format);
        std::process::exit(1);
    }
}

async fn dispatch(cli: &Cli) -> anyhow::Result<()> {
    let file_ref  = cli.file.as_deref();
    let env_files = &cli.env_file;
    let profiles  = &cli.profile;
    let proj      = cli.project_name.as_deref();
    let format    = cli.format;
    let dry_run   = cli.dry_run;

    match &cli.command {
        Command::Up(args) => {
            cmd::up::run(args, file_ref, env_files, profiles, proj, format, dry_run).await
        }
        Command::Down(args) => {
            cmd::down::run(args, file_ref, env_files, profiles, proj, format, dry_run).await
        }
        Command::Build(args) => {
            cmd::build::run(args, file_ref, env_files, profiles, proj, format, dry_run).await
        }
        Command::Pull(args) => {
            cmd::pull::run(args, file_ref, env_files, profiles, proj, format, dry_run).await
        }
        Command::Ps(args) => {
            cmd::ps::run(args, file_ref, env_files, profiles, proj, format).await
        }
        Command::Logs(args) => {
            cmd::logs::run(args, file_ref, env_files, profiles, proj, format).await
        }
        Command::Config(args) => {
            cmd::config::run(args, file_ref, env_files, profiles, proj, format)
        }
        Command::Version => {
            cmd::version::run(format)
        }
    }
}
