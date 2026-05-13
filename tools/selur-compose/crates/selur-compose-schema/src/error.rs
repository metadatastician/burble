//! Parse-time error types for `selur-compose-schema`.

use std::path::PathBuf;
use thiserror::Error;

/// Errors returned by [`crate::parse_str`].
#[derive(Error, Debug)]
pub enum ParseError {
    /// The TOML was syntactically or structurally invalid.
    #[error("invalid TOML in {file}: {source}")]
    Toml {
        file:   PathBuf,
        #[source]
        source: toml::de::Error,
    },

    /// A field name that is not recognised was present in a section that uses
    /// `#[serde(deny_unknown_fields)]`.  Includes a `did_you_mean` suggestion
    /// when a close match exists among the valid field names.
    #[error("unknown field `{field}` in [{section}] (did you mean `{suggestion}`?)")]
    UnknownField {
        section:    String,
        field:      String,
        suggestion: String,
    },

    /// A `[services.<name>]` entry has neither `image` nor `build`.
    #[error("[services.{service}] requires either `image` or `build`")]
    MissingImageOrBuild { service: String },
}
