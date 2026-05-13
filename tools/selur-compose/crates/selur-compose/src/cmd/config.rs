//! `selur-compose config` — print the parsed + interpolated compose.
//!
//! This is the "trust anchor" command: no Driver dependency, fully functional
//! in Phase 5.  Running `selur-compose config` against a compose file lets
//! users verify that variable interpolation did what they expected before
//! invoking `up`.
//!
//! Output format:
//! - `--format toml` (default): pretty-printed TOML via `toml::to_string_pretty`.
//! - `--format json` (or global `--format json`): compact JSON via `serde_json`.
//! - Per-command `--format` overrides the global flag.

use anyhow::{Context, Result};

use crate::{
    cli::{ConfigArgs, ConfigFormat, Format},
    load,
};

pub fn run(
    args:         &ConfigArgs,
    file:         Option<&std::path::Path>,
    env_files:    &[std::path::PathBuf],
    profiles:     &[String],
    project_name: Option<&str>,
    global_fmt:   Format,
) -> Result<()> {
    let loaded = load::load(file, env_files, profiles, project_name, &[])?;

    // Per-command --output wins; otherwise fall back to global --format.
    let use_json = match args.output {
        Some(ConfigFormat::Json)                          => true,
        Some(ConfigFormat::Toml)                          => false,
        None if global_fmt == Format::Json                => true,
        None                                              => false,
    };

    if use_json {
        let json = serde_json::to_string_pretty(&loaded.compose)
            .context("failed to serialize compose to JSON")?;
        println!("{json}");
    } else {
        // Remove extension keys from the serialised output so the result is a
        // clean, re-parseable TOML file.  The `extensions` BTreeMap is
        // serialised by serde flatten, so we need a custom serialisation path
        // here: serialize to a toml::Value table, then remove keys starting
        // with "x-" before pretty-printing.
        let mut val = toml::Value::try_from(&loaded.compose)
            .context("failed to convert compose to TOML value")?;

        if let Some(table) = val.as_table_mut() {
            // Remove the flattened extension entries from the top-level table
            // so the emitted TOML doesn't duplicate them.  They are preserved
            // in the Compose struct's `extensions` field but we don't want them
            // emitted twice.
            table.retain(|k, _| !k.starts_with("x-"));
        }

        let toml_str = toml::to_string_pretty(&val)
            .context("failed to serialize compose to TOML")?;
        print!("{toml_str}");
    }

    Ok(())
}
